import Foundation
import GRDB
import os

// MARK: - Embedding record

/// One embedded chunk (TASK-045 / migration v49). `vector` is 768×Float32
/// little-endian from nomic-embed-text. sourceId is a meetingId for
/// transcript/summary chunks and a filePath for KB docs; contentHash lets
/// the KB indexer skip re-embedding unchanged chunks.
struct EmbeddingRecord: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "embedding"

    var id: Int64?
    var sourceType: String       // "transcriptChunk" | "summary" | "kbDoc"
    var sourceId: String
    var meetingId: String?
    var chunkIndex: Int
    var contentHash: String
    var text: String
    var vector: Data
    var model: String
    var createdAt: Date

    enum Columns {
        static let sourceType = Column(CodingKeys.sourceType)
        static let sourceId = Column(CodingKeys.sourceId)
        static let meetingId = Column(CodingKeys.meetingId)
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Repository

final class EmbeddingRepository {
    private let database: AppDatabase
    init(database: AppDatabase) { self.database = database }

    func saveBatch(_ records: [EmbeddingRecord]) async throws {
        try await database.writer.write { db in
            for var r in records { try r.save(db) }
        }
    }

    /// Regen hygiene (review M9): a re-index of a source replaces its rows.
    func deleteForSource(sourceType: String, sourceId: String) async throws {
        _ = try await database.writer.write { db in
            try EmbeddingRecord
                .filter(EmbeddingRecord.Columns.sourceType == sourceType
                        && EmbeddingRecord.Columns.sourceId == sourceId)
                .deleteAll(db)
        }
    }

    func deleteForMeeting(_ meetingId: String) async throws {
        _ = try await database.writer.write { db in
            try EmbeddingRecord
                .filter(EmbeddingRecord.Columns.meetingId == meetingId)
                .deleteAll(db)
        }
    }

    func hasEmbeddings(meetingId: String) async throws -> Bool {
        try await database.writer.read { db in
            try EmbeddingRecord
                .filter(EmbeddingRecord.Columns.meetingId == meetingId)
                .fetchCount(db) > 0
        }
    }

    func existingHashes(sourceType: String, sourceId: String) async throws -> Set<String> {
        try await database.writer.read { db in
            let rows = try Row.fetchAll(db, sql:
                "SELECT contentHash FROM embedding WHERE sourceType = ? AND sourceId = ?",
                arguments: [sourceType, sourceId])
            return Set(rows.map { $0["contentHash"] as String })
        }
    }

    /// Everything needed for a similarity scan. ~3 KB per row; at the
    /// 10–20K-chunk scale this app reaches, a full load + brute-force
    /// cosine is a few milliseconds — deliberately no vector-DB dependency.
    func allForScan(sourceTypes: [String]) async throws -> [EmbeddingRecord] {
        try await database.writer.read { db in
            try EmbeddingRecord
                .filter(sourceTypes.contains(EmbeddingRecord.Columns.sourceType))
                .fetchAll(db)
        }
    }
}

// MARK: - Service

/// Local semantic retrieval (TASK-045). Embeds text through Ollama's
/// /api/embed with nomic-embed-text (~274 MB, pulled in the background by
/// OllamaInstaller); every caller degrades to FTS when the model or server
/// is unavailable. The cosine scan runs detached — never on the main actor
/// (review M3).
@MainActor
final class EmbeddingService {
    static let embedModel = "nomic-embed-text"
    static let dimensions = 768

    private let logger = Logger(subsystem: "com.meetingmanager.app", category: "Embedding")
    private let repository: EmbeddingRepository
    private let ollama: OllamaService

    init(database: AppDatabase, ollama: OllamaService) {
        self.repository = EmbeddingRepository(database: database)
        self.ollama = ollama
    }

    var isAvailable: Bool {
        ollama.isReachable && ollama.availableModels.contains(where: { $0.hasPrefix(Self.embedModel) })
    }

    // MARK: Embedding calls

    private struct EmbedRequest: Encodable { let model: String; let input: [String] }
    private struct EmbedResponse: Decodable { let embeddings: [[Float]] }

    func embed(texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        ollama.beginWork(label: "Indexing for search")
        defer { ollama.endWork() }
        var request = URLRequest(url: OllamaService.baseURL.appendingPathComponent("api/embed"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        request.httpBody = try JSONEncoder().encode(EmbedRequest(model: Self.embedModel, input: texts))
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw OllamaServiceError.httpError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try JSONDecoder().decode(EmbedResponse.self, from: data).embeddings
    }

    // MARK: Indexing

    /// Embed one meeting's transcript chunks + summary. Replace-mode
    /// (delete first) so re-transcription/regeneration can't duplicate.
    func indexMeeting(_ meetingId: String,
                      transcripts: [Transcript],
                      summaryText: String?) async throws {
        guard isAvailable else { return }
        let chunks = Self.chunkTranscript(transcripts)
        var texts = chunks
        if let summaryText, !summaryText.isEmpty { texts.append(summaryText) }
        guard !texts.isEmpty else { return }

        let vectors = try await embed(texts: texts)
        guard vectors.count == texts.count else { return }

        try await repository.deleteForMeeting(meetingId)
        var records: [EmbeddingRecord] = []
        for (i, chunk) in chunks.enumerated() {
            records.append(EmbeddingRecord(
                id: nil, sourceType: "transcriptChunk", sourceId: meetingId,
                meetingId: meetingId, chunkIndex: i,
                contentHash: Self.hash(chunk), text: chunk,
                vector: Self.pack(vectors[i]), model: Self.embedModel, createdAt: Date()
            ))
        }
        if let summaryText, !summaryText.isEmpty {
            records.append(EmbeddingRecord(
                id: nil, sourceType: "summary", sourceId: meetingId,
                meetingId: meetingId, chunkIndex: 0,
                contentHash: Self.hash(summaryText), text: String(summaryText.prefix(4000)),
                vector: Self.pack(vectors[texts.count - 1]), model: Self.embedModel, createdAt: Date()
            ))
        }
        try await repository.saveBatch(records)
        logger.info("Embedded \(records.count) chunk(s) for meeting \(meetingId)")
    }

    /// Re-embed one KB file's chunks (TASK-050). Skips chunks whose
    /// content hash is already stored — a one-heading edit re-embeds one
    /// chunk, not the file.
    func indexKBFile(filePath: String, chunkTexts: [String]) async throws {
        guard isAvailable, !chunkTexts.isEmpty else { return }
        let existing = (try? await repository.existingHashes(sourceType: "kbDoc", sourceId: filePath)) ?? []
        let hashes = chunkTexts.map { Self.hash($0) }
        guard Set(hashes) != existing else { return }   // identical content set

        let vectors = try await embed(texts: chunkTexts)
        guard vectors.count == chunkTexts.count else { return }
        try await repository.deleteForSource(sourceType: "kbDoc", sourceId: filePath)
        var records: [EmbeddingRecord] = []
        for (i, text) in chunkTexts.enumerated() {
            records.append(EmbeddingRecord(
                id: nil, sourceType: "kbDoc", sourceId: filePath,
                meetingId: nil, chunkIndex: i, contentHash: hashes[i],
                text: String(text.prefix(2000)), vector: Self.pack(vectors[i]),
                model: Self.embedModel, createdAt: Date()
            ))
        }
        try await repository.saveBatch(records)
        logger.info("Embedded \(records.count) KB chunk(s) for \(filePath)")
    }

    // MARK: Retrieval

    struct Hit: Sendable {
        let sourceType: String
        let sourceId: String
        let meetingId: String?
        let text: String
        let score: Float
    }

    /// Top-k cosine matches. BLOB decode + dot products run detached so a
    /// scan during a live recording can't jank the UI (review M3).
    func topK(query: String, k: Int = 8,
              sourceTypes: [String] = ["transcriptChunk", "summary", "kbDoc"]) async throws -> [Hit] {
        guard isAvailable else { return [] }
        guard let queryVector = try await embed(texts: [query]).first else { return [] }
        let rows = try await repository.allForScan(sourceTypes: sourceTypes)
        guard !rows.isEmpty else { return [] }

        let scan: [(Int, Float)] = await Task.detached(priority: .userInitiated) {
            let q = queryVector
            let qNorm = sqrt(q.reduce(0) { $0 + $1 * $1 })
            guard qNorm > 0 else { return [] }
            var scored: [(Int, Float)] = []
            scored.reserveCapacity(rows.count)
            for (idx, row) in rows.enumerated() {
                let v = Self.unpack(row.vector)
                guard v.count == q.count else { continue }
                var dot: Float = 0, norm: Float = 0
                for i in 0..<v.count { dot += v[i] * q[i]; norm += v[i] * v[i] }
                guard norm > 0 else { continue }
                scored.append((idx, dot / (qNorm * sqrt(norm))))
            }
            return scored.sorted { $0.1 > $1.1 }
        }.value

        return scan.prefix(k).map { idx, score in
            let r = rows[idx]
            return Hit(sourceType: r.sourceType, sourceId: r.sourceId,
                       meetingId: r.meetingId, text: r.text, score: score)
        }
    }

    // MARK: Pure helpers (unit-tested)

    /// Speaker-prefixed sliding chunks: ~1500 chars with 200 overlap, so a
    /// claim that straddles a boundary still lands whole in one chunk.
    nonisolated static func chunkTranscript(_ rows: [Transcript], maxChars: Int = 1500, overlap: Int = 200) -> [String] {
        let lines = rows.compactMap { row -> String? in
            let text = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return "\(row.speakerLabel ?? "Speaker"): \(text)"
        }
        guard !lines.isEmpty else { return [] }
        var chunks: [String] = []
        var current = ""
        for line in lines {
            if current.count + line.count + 1 > maxChars, !current.isEmpty {
                chunks.append(current)
                current = String(current.suffix(overlap))
            }
            current += (current.isEmpty ? "" : "\n") + line
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    nonisolated static func pack(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    nonisolated static func unpack(_ data: Data) -> [Float] {
        data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self))
        }
    }

    nonisolated static func hash(_ text: String) -> String {
        // FNV-1a — stable, fast, no CryptoKit import needed for a dedup key.
        var h: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            h ^= UInt64(byte)
            h = h &* 0x100000001b3
        }
        return String(h, radix: 16)
    }
}

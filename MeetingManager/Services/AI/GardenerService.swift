import Foundation
import GRDB
import os

// MARK: - FactLink (TASK-056, migration v50)

/// A detected relation between two facts from DIFFERENT meetings.
/// `fromFact` is always the NEWER fact: "from supersedes to". Links are
/// derived data with FK CASCADE both sides — a summary regeneration
/// deletes the meeting's facts and takes its links along (review M7:
/// accepted documented loss, recomputed next nightly run).
struct FactLink: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "factLink"

    var id: Int64?
    var fromFactId: Int64
    var toFactId: Int64
    var relation: String       // duplicate | supersedes | contradicts
    var detectedAt: Date

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// A link joined to both facts' display fields — what renderers consume.
/// Keyed by (meetingId, text) rather than fact id so person/company
/// fan-out rows of the same fact match the link made on the series row.
struct FactLinkDescriptor: Sendable {
    let relation: String
    let detectedAt: Date
    let fromText: String
    let fromMeetingId: String
    let toText: String
    let toMeetingId: String
}

final class FactLinkRepository {
    private let database: AppDatabase
    init(database: AppDatabase) { self.database = database }

    func save(_ link: FactLink) async throws {
        var copy = link
        _ = try await database.writer.write { db in try copy.save(db) }
    }

    /// "fromId-toId" keys for every existing link, both directions —
    /// the nightly run skips pairs it has already classified.
    func existingPairKeys() async throws -> Set<String> {
        try await database.writer.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT fromFactId, toFactId FROM factLink")
            var keys = Set<String>()
            for row in rows {
                let f = row["fromFactId"] as Int64, t = row["toFactId"] as Int64
                keys.insert("\(f)-\(t)")
                keys.insert("\(t)-\(f)")
            }
            return keys
        }
    }

    /// All links with their facts' display fields, newest first.
    /// Volume is bounded by the nightly classification cap, so a full
    /// load is fine.
    func allDescriptors(limit: Int = 500) async throws -> [FactLinkDescriptor] {
        try await database.writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT l.relation, l.detectedAt,
                       f.text AS fromText, f.meetingId AS fromMeetingId,
                       t.text AS toText, t.meetingId AS toMeetingId
                FROM factLink l
                JOIN entityFact f ON f.id = l.fromFactId
                JOIN entityFact t ON t.id = l.toFactId
                WHERE l.relation != 'unrelated'
                ORDER BY l.detectedAt DESC
                LIMIT ?
                """, arguments: [limit])
            return rows.map {
                FactLinkDescriptor(
                    relation: $0["relation"], detectedAt: $0["detectedAt"],
                    fromText: $0["fromText"], fromMeetingId: $0["fromMeetingId"],
                    toText: $0["toText"], toMeetingId: $0["toMeetingId"])
            }
        }
    }

    /// Supersedes/contradicts links detected inside a window — the weekly
    /// digest's "Reversals & conflicts" source.
    func conflictDescriptors(from start: Date, to end: Date) async throws -> [FactLinkDescriptor] {
        try await allDescriptors().filter {
            ($0.relation == "supersedes" || $0.relation == "contradicts")
            && $0.detectedAt >= start && $0.detectedAt < end
        }
    }
}

// MARK: - Gardener (TASK-056)

/// Nightly background pass that keeps dossiers truthful: pairs similar
/// facts from different meetings (transient embeddings — fact ids churn
/// on regeneration, so vectors are never stored; review B4), classifies
/// each pair with ONE array-schema local call, then links and soft-hides.
/// Everything is reversible — links and `hiddenAt`, never deletes.
enum GardenerService {

    /// Hard nightly caps (review M8): one classification call of at most
    /// `pairCap` pairs; at most `factCap` recent facts walked.
    static let pairCap = 20
    static let factCap = 300
    static let similarityThreshold: Float = 0.85

    struct CandidatePair {
        let older: EntityFact
        let newer: EntityFact
        let similarity: Float
    }

    /// Pure pair selection over the walked facts: same entityKey + kind,
    /// different meetings, neither hidden, not already linked, cosine ≥
    /// threshold; most-similar first, capped. `vectors` is keyed by fact
    /// text (texts are the dedup unit across fan-out rows).
    static func candidatePairs(
        facts: [EntityFact],
        vectors: [String: [Float]],
        excludedPairKeys: Set<String> = [],
        threshold: Float = similarityThreshold,
        cap: Int = pairCap
    ) -> [CandidatePair] {
        var out: [CandidatePair] = []
        let groups = Dictionary(grouping: facts.filter { $0.hiddenAt == nil }) {
            "\($0.entityKey)|\($0.kind)"
        }
        for (_, group) in groups {
            let sorted = group.sorted { $0.extractedAt < $1.extractedAt }
            for i in 0..<sorted.count {
                for j in (i + 1)..<sorted.count {
                    let a = sorted[i], b = sorted[j]
                    guard a.meetingId != b.meetingId,
                          let aid = a.id, let bid = b.id,
                          !excludedPairKeys.contains("\(aid)-\(bid)"),
                          let va = vectors[a.text], let vb = vectors[b.text] else { continue }
                    let sim = cosine(va, vb)
                    if sim >= threshold {
                        out.append(CandidatePair(older: a, newer: b, similarity: sim))
                    }
                }
            }
        }
        return Array(out.sorted { $0.similarity > $1.similarity }.prefix(cap))
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (sqrt(na) * sqrt(nb))
    }

    // MARK: Classification

    static let classifySchemaJSON = """
    {"type":"object","properties":{"pairs":{"type":"array","items":{"type":"object","properties":{"index":{"type":"integer"},"relation":{"type":"string","enum":["duplicate","supersedes","contradicts","unrelated"]}},"required":["index","relation"]}}},"required":["pairs"]}
    """

    static let classifySystemPrompt = """
    You compare pairs of facts extracted from different meetings of the \
    same group. For each numbered pair, classify the NEWER fact against \
    the OLDER one: "duplicate" — same fact restated, nothing new; \
    "supersedes" — the newer fact updates or replaces the older one \
    (a changed date, a revised decision, a question now answered); \
    "contradicts" — they cannot both hold and neither explicitly \
    replaces the other; "unrelated" — similar wording but different \
    facts. Return ONLY JSON matching the requested shape, one entry per \
    pair index. When unsure, answer "unrelated" — a wrong link is worse \
    than a missed one.
    """

    static func classifyUserPrompt(pairs: [CandidatePair]) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return pairs.enumerated().map { i, p in
            """
            Pair \(i):
            OLDER (\(df.string(from: p.older.extractedAt)), \(p.older.kind)): \(p.older.text)
            NEWER (\(df.string(from: p.newer.extractedAt)), \(p.newer.kind)): \(p.newer.text)
            """
        }.joined(separator: "\n\n")
    }

    struct ClassifyPayload: Decodable {
        struct Entry: Decodable { let index: Int; let relation: String }
        let pairs: [Entry]
    }

    static func parseClassification(_ response: String) -> ClassifyPayload? {
        guard let start = response.firstIndex(of: "{"),
              let end = response.lastIndex(of: "}") else { return nil }
        return try? JSONDecoder().decode(ClassifyPayload.self,
                                         from: Data(String(response[start...end]).utf8))
    }

    // MARK: Nightly run

    /// One gardening pass. `textGenerator` is the schema-constrained local
    /// call; `embed` produces transient vectors for the candidate texts.
    @MainActor
    static func run(
        database: AppDatabase,
        embed: ([String]) async throws -> [[Float]],
        textGenerator: (String, String) async throws -> String,
        log: (String) -> Void
    ) async throws {
        let factRepo = EntityFactRepository(database: database)
        let linkRepo = FactLinkRepository(database: database)

        // Series rows are the canonical one-row-per-fact representation;
        // hides propagate to person/company siblings by (meeting, kind, text).
        let facts = try await factRepo.visibleSeriesFacts(limit: factCap)
        guard facts.count >= 2 else {
            log("Gardener: \(facts.count) visible fact(s) — nothing to compare")
            return
        }

        let uniqueTexts = Array(Set(facts.map(\.text)))
        let vectorList = try await embed(uniqueTexts)
        guard vectorList.count == uniqueTexts.count else {
            log("Gardener: embed count mismatch — aborting run")
            return
        }
        let vectors = Dictionary(uniqueKeysWithValues: zip(uniqueTexts, vectorList))

        let excluded = (try? await linkRepo.existingPairKeys()) ?? []
        let pairs = candidatePairs(facts: facts, vectors: vectors, excludedPairKeys: excluded)
        guard !pairs.isEmpty else {
            log("Gardener: no candidate pairs ≥\(similarityThreshold) tonight")
            return
        }

        let response = try await textGenerator(classifySystemPrompt, classifyUserPrompt(pairs: pairs))
        guard let payload = parseClassification(response) else {
            log("Gardener: unparseable classification — aborting run")
            return
        }

        var linked = 0, hidden = 0
        for entry in payload.pairs where entry.index >= 0 && entry.index < pairs.count {
            let pair = pairs[entry.index]
            guard let olderId = pair.older.id, let newerId = pair.newer.id else { continue }
            switch entry.relation {
            case "duplicate":
                try await linkRepo.save(FactLink(
                    id: nil, fromFactId: newerId, toFactId: olderId,
                    relation: "duplicate", detectedAt: Date()))
                try await factRepo.hideFacts(
                    meetingId: pair.older.meetingId,
                    kind: pair.older.kind,
                    text: pair.older.text)
                linked += 1
                hidden += 1
            case "supersedes", "contradicts":
                try await linkRepo.save(FactLink(
                    id: nil, fromFactId: newerId, toFactId: olderId,
                    relation: entry.relation, detectedAt: Date()))
                linked += 1
            default:
                // "unrelated" is stored too — it excludes the pair from
                // every future night's cap. Renderers never see it
                // (allDescriptors filters); a regen deletes it with the
                // facts, so genuinely-changed facts can re-pair.
                try await linkRepo.save(FactLink(
                    id: nil, fromFactId: newerId, toFactId: olderId,
                    relation: "unrelated", detectedAt: Date()))
            }
        }
        log("Gardener: \(pairs.count) pair(s) classified, \(linked) linked, \(hidden) hidden")
    }
}

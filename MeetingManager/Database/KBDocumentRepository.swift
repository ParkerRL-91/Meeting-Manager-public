import Foundation
import GRDB

/// Persistence + retrieval for the Knowledge Base index.
final class KBDocumentRepository {
    private let database: AppDatabase

    init(database: AppDatabase = .shared) {
        self.database = database
    }

    // MARK: - Counts

    func documentCount() async throws -> Int {
        try await database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT filePath) FROM kbDocument") ?? 0
        }
    }

    func chunkCount() async throws -> Int {
        try await database.writer.read { db in
            try KBDocument.fetchCount(db)
        }
    }

    func lastIndexedAt() async throws -> Date? {
        try await database.writer.read { db in
            try Date.fetchOne(db, sql: "SELECT MAX(indexedAt) FROM kbDocument")
        }
    }

    // MARK: - Writes

    /// Replace all chunks for a single file in one transaction. Used when a
    /// file is added, modified, or moved — keeps the FTS index consistent.
    func replaceChunks(filePath: String, with chunks: [KBDocument]) async throws {
        try await database.writer.write { db in
            try KBDocument
                .filter(KBDocument.Columns.filePath == filePath)
                .deleteAll(db)
            for var chunk in chunks {
                try chunk.insert(db)
            }
        }
    }

    /// Drop every chunk whose source file no longer exists / no longer lives
    /// inside the KB root. Called after a full re-index sweep.
    func deleteChunksNotIn(filePaths: Set<String>) async throws {
        try await database.writer.write { db in
            let allPaths = try String.fetchAll(db, sql: "SELECT DISTINCT filePath FROM kbDocument")
            let stale = allPaths.filter { !filePaths.contains($0) }
            guard !stale.isEmpty else { return }
            for path in stale {
                try KBDocument
                    .filter(KBDocument.Columns.filePath == path)
                    .deleteAll(db)
            }
        }
    }

    /// Wipe the entire KB index — used when the user changes the root folder
    /// or hits "Clear" in Settings.
    func wipe() async throws {
        try await database.writer.write { db in
            try KBDocument.deleteAll(db)
        }
    }

    // MARK: - Retrieval

    /// Top-k FTS5 search across body + heading. Returns chunks ordered by BM25
    /// rank. The caller is expected to format these into prompt context.
    func search(query: String, limit: Int = 6) async throws -> [KBDocument] {
        try await database.writer.read { db in
            let pattern = FTS5Pattern(matchingAnyTokenIn: query)?.rawPattern
                ?? query.replacingOccurrences(of: "\"", with: "")
            let sql = """
                SELECT kbDocument.* FROM kbDocument
                JOIN kbDocument_fts ON kbDocument.rowid = kbDocument_fts.rowid
                WHERE kbDocument_fts MATCH ?
                ORDER BY rank
                LIMIT ?
                """
            return try KBDocument.fetchAll(db, sql: sql, arguments: [pattern, limit])
        }
    }
}

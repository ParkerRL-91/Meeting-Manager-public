import Foundation
import GRDB

/// Persistence for the per-meeting detailed-outline blob. Mirror of
/// `CleanedTranscriptRepository` — keyed 1:1 by meetingId, replace-on-write.
final class DetailedOutlineRepository {
    private let database: AppDatabase

    init(database: AppDatabase = AppDatabase.shared) {
        self.database = database
    }

    /// Fetch the outline for a meeting, if one has been generated.
    func outline(meetingId: String) async throws -> DetailedOutline? {
        try await database.writer.read { db in
            try DetailedOutline
                .filter(DetailedOutline.Columns.meetingId == meetingId)
                .fetchOne(db)
        }
    }

    /// Upsert the outline. Replace-on-write semantics — the model holds at
    /// most one outline per meeting. Subsequent regenerations replace.
    func save(_ outline: DetailedOutline) async throws {
        try await database.writer.write { db in
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO detailedOutline
                        (meetingId, text, generatedAt, method, modelUsed)
                    VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [
                    outline.meetingId,
                    outline.text,
                    outline.generatedAt,
                    outline.method,
                    outline.modelUsed
                ]
            )
        }
    }

    /// Drop the outline for a meeting. Used when the underlying transcript
    /// is rewritten (e.g. user manually fixed speaker labels) and the user
    /// wants the outline regenerated against the new transcript.
    func delete(meetingId: String) async throws {
        try await database.writer.write { db in
            _ = try DetailedOutline
                .filter(DetailedOutline.Columns.meetingId == meetingId)
                .deleteAll(db)
        }
    }
}

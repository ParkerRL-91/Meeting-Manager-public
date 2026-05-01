import Foundation
import GRDB

/// Persistence for the per-meeting cleaned transcript blob. Mirror of the
/// `transcript` table except keyed by meetingId (1:1) instead of segment.
final class CleanedTranscriptRepository {
    private let database: AppDatabase

    init(database: AppDatabase = AppDatabase.shared) {
        self.database = database
    }

    /// Fetch the cleaned transcript for a meeting, if one has been generated.
    func cleanedTranscript(meetingId: String) async throws -> CleanedTranscript? {
        try await database.writer.read { db in
            try CleanedTranscript
                .filter(CleanedTranscript.Columns.meetingId == meetingId)
                .fetchOne(db)
        }
    }

    /// Upsert the cleaned transcript for a meeting. Replace-on-write — the
    /// model holds at most one cleaned version per meeting.
    func save(_ cleaned: CleanedTranscript) async throws {
        try await database.writer.write { db in
            // Manual upsert. GRDB's MutablePersistableRecord doesn't natively
            // support REPLACE on a non-rowid primary key without a fetch first.
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO cleanedTranscript (meetingId, text, generatedAt, method)
                    VALUES (?, ?, ?, ?)
                """,
                arguments: [
                    cleaned.meetingId,
                    cleaned.text,
                    cleaned.generatedAt,
                    cleaned.method
                ]
            )
        }
    }

    /// Drop the cleaned transcript for a meeting. Used when the user edits
    /// the raw transcript and wants the cleaned version regenerated.
    func delete(meetingId: String) async throws {
        try await database.writer.write { db in
            _ = try CleanedTranscript
                .filter(CleanedTranscript.Columns.meetingId == meetingId)
                .deleteAll(db)
        }
    }
}

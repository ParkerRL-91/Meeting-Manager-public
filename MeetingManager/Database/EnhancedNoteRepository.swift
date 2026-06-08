import Foundation
import GRDB

/// Persistence for the per-meeting enhanced-note blob. Mirror of
/// `DetailedOutlineRepository` — keyed 1:1 by meetingId, replace-on-write.
final class EnhancedNoteRepository {
    private let database: AppDatabase

    init(database: AppDatabase = AppDatabase.shared) {
        self.database = database
    }

    /// Fetch the enhanced note for a meeting, if one has been generated.
    func enhancedNote(meetingId: String) async throws -> EnhancedNote? {
        try await database.writer.read { db in
            try EnhancedNote
                .filter(EnhancedNote.Columns.meetingId == meetingId)
                .fetchOne(db)
        }
    }

    /// Upsert the enhanced note. Replace-on-write semantics — the model holds
    /// at most one per meeting. A re-enhancement (e.g. after the user edits
    /// their notes) replaces the prior row.
    func save(_ note: EnhancedNote) async throws {
        try await database.writer.write { db in
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO enhancedNote
                        (meetingId, content, modelUsed, generatedAt, sourceNotesHash, sourceNotesLength)
                    VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    note.meetingId,
                    note.content,
                    note.modelUsed,
                    note.generatedAt,
                    note.sourceNotesHash,
                    note.sourceNotesLength
                ]
            )
        }
    }

    /// Drop the enhanced note for a meeting.
    func delete(meetingId: String) async throws {
        try await database.writer.write { db in
            _ = try EnhancedNote
                .filter(EnhancedNote.Columns.meetingId == meetingId)
                .deleteAll(db)
        }
    }
}

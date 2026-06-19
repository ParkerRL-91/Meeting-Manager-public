import Foundation
import GRDB

final class SummaryRepository {
    private let database: AppDatabase

    init(database: AppDatabase) {
        self.database = database
    }

    func save(_ summary: inout MeetingSummary) async throws {
        // Return the saved record so the auto-assigned rowid propagates back
        // (see TaskRepository.save).
        let input = summary
        summary = try await database.writer.write { db in
            var copy = input
            try copy.save(db)
            return copy
        }
    }

    func latestSummary(meetingId: String) async throws -> MeetingSummary? {
        try await database.writer.read { db in
            try MeetingSummary
                .filter(MeetingSummary.Columns.meetingId == meetingId)
                .order(MeetingSummary.Columns.generatedAt.desc)
                .fetchOne(db)
        }
    }

    func allSummaries(meetingId: String, limit: Int = 50) async throws -> [MeetingSummary] {
        try await database.writer.read { db in
            try MeetingSummary
                .filter(MeetingSummary.Columns.meetingId == meetingId)
                .order(MeetingSummary.Columns.generatedAt.desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// TASK-070: the most recent (AI original → user-edited) pairs across
    /// all meetings, used as style few-shots in new summary prompts.
    /// Excludes the meeting being summarized so a regeneration never sees
    /// its own previous draft as an "example".
    func recentEditedExamples(excluding meetingId: String, limit: Int = 2) async throws -> [MeetingSummary] {
        try await database.writer.read { db in
            try MeetingSummary
                .filter(MeetingSummary.Columns.isEdited == true)
                .filter(MeetingSummary.Columns.originalText != nil)
                .filter(MeetingSummary.Columns.meetingId != meetingId)
                .order(MeetingSummary.Columns.generatedAt.desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    func update(_ summary: MeetingSummary) async throws {
        try await database.writer.write { db in
            try summary.update(db)
        }
    }

    func delete(_ summary: MeetingSummary) async throws {
        try await database.writer.write { db in
            _ = try summary.delete(db)
        }
    }
}

import Foundation
import GRDB

final class SummaryRepository {
    private let database: AppDatabase

    init(database: AppDatabase) {
        self.database = database
    }

    func save(_ summary: inout MeetingSummary) async throws {
        var copy = summary
        try await database.writer.write { db in
            try copy.save(db)
        }
        summary = copy
    }

    func latestSummary(meetingId: String) async throws -> MeetingSummary? {
        try await database.writer.read { db in
            try MeetingSummary
                .filter(MeetingSummary.Columns.meetingId == meetingId)
                .order(MeetingSummary.Columns.generatedAt.desc)
                .fetchOne(db)
        }
    }

    func allSummaries(meetingId: String) async throws -> [MeetingSummary] {
        try await database.writer.read { db in
            try MeetingSummary
                .filter(MeetingSummary.Columns.meetingId == meetingId)
                .order(MeetingSummary.Columns.generatedAt.desc)
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

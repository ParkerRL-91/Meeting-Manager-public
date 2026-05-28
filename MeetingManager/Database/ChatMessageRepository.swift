import Foundation
import GRDB

final class ChatMessageRepository {
    private let database: AppDatabase

    init(database: AppDatabase = .shared) {
        self.database = database
    }

    func save(_ message: inout ChatMessage) async throws {
        // Return the saved record so the auto-assigned rowid propagates back;
        // mutating a captured var inside GRDB's @Sendable async write does not
        // (see ActionItemRepository.save).
        let input = message
        message = try await database.writer.write { db in
            var copy = input
            try copy.save(db)
            return copy
        }
    }

    func messagesForMeeting(_ meetingId: String, limit: Int = 200) async throws -> [ChatMessage] {
        try await database.writer.read { db in
            try ChatMessage
                .filter(ChatMessage.Columns.meetingId == meetingId)
                .order(ChatMessage.Columns.createdAt.asc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    func clearForMeeting(_ meetingId: String) async throws {
        try await database.writer.write { db in
            _ = try ChatMessage
                .filter(ChatMessage.Columns.meetingId == meetingId)
                .deleteAll(db)
        }
    }
}

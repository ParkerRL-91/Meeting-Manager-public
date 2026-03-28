import Foundation
import GRDB

final class ChatMessageRepository {
    private let database: AppDatabase

    init(database: AppDatabase = .shared) {
        self.database = database
    }

    func save(_ message: inout ChatMessage) async throws {
        var copy = message
        try await database.writer.write { db in
            try copy.save(db)
        }
        message = copy
    }

    func messagesForMeeting(_ meetingId: String) async throws -> [ChatMessage] {
        try await database.writer.read { db in
            try ChatMessage
                .filter(ChatMessage.Columns.meetingId == meetingId)
                .order(ChatMessage.Columns.createdAt.asc)
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

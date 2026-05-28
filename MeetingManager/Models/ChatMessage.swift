import Foundation
import GRDB

struct ChatMessage: Identifiable, Codable, Equatable {
    var id: Int64?
    var meetingId: String
    var role: String  // "user" or "assistant"
    var content: String
    var createdAt: Date

    init(
        id: Int64? = nil,
        meetingId: String,
        role: String,
        content: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.meetingId = meetingId
        self.role = role
        self.content = content
        self.createdAt = createdAt
    }

    var isUser: Bool { role == "user" }
    var isAssistant: Bool { role == "assistant" }
}

// MARK: - GRDB

extension ChatMessage: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "chatMessage"

    enum Columns: String, ColumnExpression {
        case id, meetingId, role, content, createdAt
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

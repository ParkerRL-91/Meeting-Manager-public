import Foundation
import GRDB

struct ChatMessage: Identifiable, Codable, Equatable {
    var id: Int64?
    var meetingId: String
    var role: String  // "user" or "assistant"
    var content: String
    var createdAt: Date
    /// PRJ-014: JSON-encoded `[KBSourceRef]` — the KB chunks fed to the model as
    /// background for this message. Mirrors `TaskItem.tagsJSON` (synthesized
    /// Codable; NO explicit CodingKeys). nil = no KB context used.
    var kbSourcesJSON: String? = nil

    init(
        id: Int64? = nil,
        meetingId: String,
        role: String,
        content: String,
        createdAt: Date = Date(),
        kbSourcesJSON: String? = nil
    ) {
        self.id = id
        self.meetingId = meetingId
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.kbSourcesJSON = kbSourcesJSON
    }

    var isUser: Bool { role == "user" }
    var isAssistant: Bool { role == "assistant" }

    /// Convenience accessor over `kbSourcesJSON`. Not a stored column.
    var kbSources: [KBSourceRef] {
        get {
            guard let kbSourcesJSON, let data = kbSourcesJSON.data(using: .utf8) else { return [] }
            return (try? JSONDecoder().decode([KBSourceRef].self, from: data)) ?? []
        }
        set {
            kbSourcesJSON = newValue.isEmpty
                ? nil
                : (try? JSONEncoder().encode(newValue)).flatMap { String(data: $0, encoding: .utf8) }
        }
    }
}

// MARK: - GRDB

extension ChatMessage: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "chatMessage"

    enum Columns: String, ColumnExpression {
        case id, meetingId, role, content, createdAt, kbSourcesJSON
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

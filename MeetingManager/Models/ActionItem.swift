import Foundation
import GRDB

struct ActionItem: Identifiable, Codable, Equatable {
    var id: Int64?
    var meetingId: String
    var title: String
    var assignee: String?
    var dueDate: Date?
    var isCompleted: Bool
    var extractedAt: Date

    init(
        id: Int64? = nil,
        meetingId: String,
        title: String,
        assignee: String? = nil,
        dueDate: Date? = nil,
        isCompleted: Bool = false,
        extractedAt: Date = Date()
    ) {
        self.id = id
        self.meetingId = meetingId
        self.title = title
        self.assignee = assignee
        self.dueDate = dueDate
        self.isCompleted = isCompleted
        self.extractedAt = extractedAt
    }
}

// MARK: - GRDB

extension ActionItem: FetchableRecord, PersistableRecord {
    static let databaseTableName = "actionItem"

    enum Columns: String, ColumnExpression {
        case id, meetingId, title, assignee, dueDate, isCompleted, extractedAt
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

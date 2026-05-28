import Foundation
import GRDB

struct MeetingNote: Identifiable, Codable, Equatable {
    var id: Int64?
    var meetingId: String
    var content: String
    var createdAt: Date

    init(
        id: Int64? = nil,
        meetingId: String,
        content: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.meetingId = meetingId
        self.content = content
        self.createdAt = createdAt
    }
}

// MARK: - GRDB

extension MeetingNote: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "meetingNote"

    enum Columns: String, ColumnExpression {
        case id, meetingId, content, createdAt
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

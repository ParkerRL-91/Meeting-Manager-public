import Foundation
import GRDB

struct MeetingSummary: Identifiable, Codable, Equatable {
    var id: Int64?
    var meetingId: String
    var promptUsed: String
    var summaryText: String
    var modelUsed: String?
    var generatedAt: Date
    var isEdited: Bool

    init(
        id: Int64? = nil,
        meetingId: String,
        promptUsed: String,
        summaryText: String,
        modelUsed: String? = nil,
        generatedAt: Date = Date(),
        isEdited: Bool = false
    ) {
        self.id = id
        self.meetingId = meetingId
        self.promptUsed = promptUsed
        self.summaryText = summaryText
        self.modelUsed = modelUsed
        self.generatedAt = generatedAt
        self.isEdited = isEdited
    }
}

// MARK: - GRDB

extension MeetingSummary: FetchableRecord, PersistableRecord {
    static let databaseTableName = "meetingSummary"

    enum Columns: String, ColumnExpression {
        case id, meetingId, promptUsed, summaryText, modelUsed, generatedAt, isEdited
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

import Foundation
import GRDB

struct MeetingTemplate: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var noteTemplate: String
    var recipeId: String?
    var createdAt: Date

    init(
        id: String = UUID().uuidString,
        name: String,
        noteTemplate: String = "",
        recipeId: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.noteTemplate = noteTemplate
        self.recipeId = recipeId
        self.createdAt = createdAt
    }
}

// MARK: - GRDB

extension MeetingTemplate: FetchableRecord, PersistableRecord {
    static let databaseTableName = "meetingTemplate"

    enum Columns: String, ColumnExpression {
        case id, name, noteTemplate, recipeId, createdAt
    }
}

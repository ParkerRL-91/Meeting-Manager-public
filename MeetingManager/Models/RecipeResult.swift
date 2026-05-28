import Foundation
import GRDB

struct RecipeResult: Identifiable, Codable, Equatable {
    var id: Int64?
    var meetingId: String
    var recipeId: String
    var outputText: String
    var generatedAt: Date

    init(
        id: Int64? = nil,
        meetingId: String,
        recipeId: String,
        outputText: String,
        generatedAt: Date = Date()
    ) {
        self.id = id
        self.meetingId = meetingId
        self.recipeId = recipeId
        self.outputText = outputText
        self.generatedAt = generatedAt
    }
}

// MARK: - GRDB

extension RecipeResult: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "recipeResult"

    enum Columns: String, ColumnExpression {
        case id, meetingId, recipeId, outputText, generatedAt
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

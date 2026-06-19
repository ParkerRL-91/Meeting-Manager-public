import Foundation
import GRDB

/// A configurable Kanban column. Tasks (`TaskItem.stageId`) reference a stage.
/// Invariants (enforced in `TaskStageRepository`): exactly one `isDefault` (where
/// newly-accepted tasks land) and at least one `isTerminal` (completing a task
/// moves it here).
struct TaskStage: Identifiable, Codable, Equatable, Hashable {
    var id: Int64?
    var name: String
    /// Column order, left → right. Fractional to allow cheap reordering.
    var sortOrder: Double
    var colorHex: String?
    var isTerminal: Bool
    /// Optional soft WIP limit (warn when exceeded; never blocks).
    var wipLimit: Int?
    var isDefault: Bool
    var createdAt: Date
    var updatedAt: Date

    init(
        id: Int64? = nil,
        name: String,
        sortOrder: Double = 0,
        colorHex: String? = nil,
        isTerminal: Bool = false,
        wipLimit: Int? = nil,
        isDefault: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
        self.colorHex = colorHex
        self.isTerminal = isTerminal
        self.wipLimit = wipLimit
        self.isDefault = isDefault
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - GRDB

extension TaskStage: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "taskStage"

    enum Columns: String, ColumnExpression {
        case id, name, sortOrder, colorHex, isTerminal, wipLimit, isDefault, createdAt, updatedAt
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

import Foundation
import GRDB

/// A project groups tasks (`TaskItem.projectId`). Created in v62 (PRJ-013
/// Phase 7). Deleting a project clears `projectId` on its tasks in app code — the
/// ALTER-added column carries no DB cascade.
struct TaskProject: Identifiable, Codable, Equatable, Hashable {
    var id: Int64?
    var name: String
    var colorHex: String?
    /// Display order, fractional to allow cheap reordering.
    var sortOrder: Double
    var createdAt: Date
    /// Soft archive — hidden from the active project list but its tasks keep the link.
    var archivedAt: Date?

    init(
        id: Int64? = nil,
        name: String,
        colorHex: String? = nil,
        sortOrder: Double = 0,
        createdAt: Date = Date(),
        archivedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.archivedAt = archivedAt
    }
}

// MARK: - GRDB

extension TaskProject: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "taskProject"

    enum Columns: String, ColumnExpression {
        case id, name, colorHex, sortOrder, createdAt, archivedAt
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

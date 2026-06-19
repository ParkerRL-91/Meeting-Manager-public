import Foundation
import GRDB

/// A blocked-by edge: the task `taskId` depends on `dependsOnTaskId`. A task is
/// "blocked" while any task it depends on is incomplete. Created in v62 (PRJ-013
/// Phase 7). UNIQUE(taskId, dependsOnTaskId); cycle-prevention enforced on add in
/// `TaskDependencyRepository`. Both columns cascade-delete with their tasks.
struct TaskDependency: Identifiable, Codable, Equatable, Hashable {
    var id: Int64?
    var taskId: Int64
    var dependsOnTaskId: Int64
    var createdAt: Date

    init(
        id: Int64? = nil,
        taskId: Int64,
        dependsOnTaskId: Int64,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.taskId = taskId
        self.dependsOnTaskId = dependsOnTaskId
        self.createdAt = createdAt
    }
}

// MARK: - GRDB

extension TaskDependency: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "taskDependency"

    enum Columns: String, ColumnExpression {
        case id, taskId, dependsOnTaskId, createdAt
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

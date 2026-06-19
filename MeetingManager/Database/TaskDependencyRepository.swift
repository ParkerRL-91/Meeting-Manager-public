import Foundation
import GRDB

/// Repository for task dependencies (blocked-by edges; PRJ-013 Phase 7). A task is
/// blocked while any task it depends on is incomplete. `add` refuses an edge that
/// would create a cycle (direct or transitive) and is idempotent against the
/// UNIQUE(taskId, dependsOnTaskId) constraint.
final class TaskDependencyRepository {
    private let database: AppDatabase

    init(database: AppDatabase = .shared) {
        self.database = database
    }

    enum DependencyError: LocalizedError {
        case cycle
        case selfDependency

        var errorDescription: String? {
            switch self {
            case .cycle: return "That dependency would create a cycle."
            case .selfDependency: return "A task cannot depend on itself."
            }
        }
    }

    /// The tasks `taskId` depends on (its blockers).
    func dependencies(of taskId: Int64) async throws -> [TaskDependency] {
        try await database.writer.read { db in
            try TaskDependency
                .filter(TaskDependency.Columns.taskId == taskId)
                .order(TaskDependency.Columns.createdAt.asc)
                .fetchAll(db)
        }
    }

    /// The blocker `TaskItem`s for a task, in dependency order.
    func blockers(of taskId: Int64) async throws -> [TaskItem] {
        try await database.writer.read { db in
            let ids = try TaskDependency
                .filter(TaskDependency.Columns.taskId == taskId)
                .order(TaskDependency.Columns.createdAt.asc)
                .fetchAll(db)
                .map(\.dependsOnTaskId)
            guard !ids.isEmpty else { return [] }
            let rows = try TaskItem
                .filter(ids.contains(TaskItem.Columns.id))
                .filter(TaskItem.Columns.deletedAt == nil)
                .fetchAll(db)
            // Preserve dependency-edge order.
            let byId = Dictionary(uniqueKeysWithValues: rows.compactMap { item in item.id.map { ($0, item) } })
            return ids.compactMap { byId[$0] }
        }
    }

    /// True if any of the task's (non-deleted) blockers is incomplete. Used to
    /// surface the Blocked badge.
    func isBlocked(taskId: Int64) async throws -> Bool {
        try await database.writer.read { db in
            try Self.isBlockedSync(taskId: taskId, db: db)
        }
    }

    /// Computes blocked-state for many tasks in one read. Returns the set of task
    /// ids that are blocked (have at least one incomplete blocker).
    func blockedTaskIds(in taskIds: [Int64]) async throws -> Set<Int64> {
        guard !taskIds.isEmpty else { return [] }
        return try await database.writer.read { db in
            var blocked: Set<Int64> = []
            for id in taskIds where try Self.isBlockedSync(taskId: id, db: db) {
                blocked.insert(id)
            }
            return blocked
        }
    }

    private static func isBlockedSync(taskId: Int64, db: Database) throws -> Bool {
        let blockerIds = try TaskDependency
            .filter(TaskDependency.Columns.taskId == taskId)
            .fetchAll(db)
            .map(\.dependsOnTaskId)
        guard !blockerIds.isEmpty else { return false }
        let incomplete = try TaskItem
            .filter(blockerIds.contains(TaskItem.Columns.id))
            .filter(TaskItem.Columns.deletedAt == nil)
            .filter(TaskItem.Columns.isCompleted == false)
            .fetchCount(db)
        return incomplete > 0
    }

    /// Records that `taskId` depends on `dependsOnTaskId`. Rejects self-edges and
    /// any edge that would introduce a cycle (if `dependsOnTaskId` already depends,
    /// transitively, on `taskId`). Idempotent: a duplicate edge is a no-op.
    func add(taskId: Int64, dependsOnTaskId: Int64) async throws {
        guard taskId != dependsOnTaskId else { throw DependencyError.selfDependency }
        try await database.writer.write { db in
            // Cycle guard: walk the dependency graph from dependsOnTaskId; if it
            // reaches taskId, adding this edge would close a cycle.
            if try Self.reaches(from: dependsOnTaskId, to: taskId, db: db) {
                throw DependencyError.cycle
            }
            let exists = try TaskDependency
                .filter(TaskDependency.Columns.taskId == taskId)
                .filter(TaskDependency.Columns.dependsOnTaskId == dependsOnTaskId)
                .fetchCount(db) > 0
            guard !exists else { return }
            var edge = TaskDependency(taskId: taskId, dependsOnTaskId: dependsOnTaskId)
            try edge.insert(db)
        }
    }

    func remove(taskId: Int64, dependsOnTaskId: Int64) async throws {
        try await database.writer.write { db in
            _ = try TaskDependency
                .filter(TaskDependency.Columns.taskId == taskId)
                .filter(TaskDependency.Columns.dependsOnTaskId == dependsOnTaskId)
                .deleteAll(db)
        }
    }

    /// Depth-first reachability over the depends-on edges. Returns true if `target`
    /// is reachable from `start` (i.e. start depends, transitively, on target).
    private static func reaches(from start: Int64, to target: Int64, db: Database) throws -> Bool {
        var visited: Set<Int64> = []
        var stack: [Int64] = [start]
        while let current = stack.popLast() {
            if current == target { return true }
            guard visited.insert(current).inserted else { continue }
            let next = try TaskDependency
                .filter(TaskDependency.Columns.taskId == current)
                .fetchAll(db)
                .map(\.dependsOnTaskId)
            stack.append(contentsOf: next)
        }
        return false
    }
}

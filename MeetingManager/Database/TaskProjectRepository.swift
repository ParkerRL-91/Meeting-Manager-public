import Foundation
import GRDB

/// Repository for task projects (PRJ-013 Phase 7). CRUD + reorder. Deleting a
/// project clears `projectId` on every task that referenced it in the same
/// transaction — the ALTER-added `actionItem.projectId` column has no DB cascade,
/// so the cleanup is explicit here.
final class TaskProjectRepository {
    private let database: AppDatabase

    init(database: AppDatabase = .shared) {
        self.database = database
    }

    /// Active (non-archived) projects in display order.
    func allProjects(includeArchived: Bool = false) async throws -> [TaskProject] {
        try await database.writer.read { db in
            var request = TaskProject.all()
            if !includeArchived {
                request = request.filter(TaskProject.Columns.archivedAt == nil)
            }
            return try request.order(TaskProject.Columns.sortOrder.asc).fetchAll(db)
        }
    }

    func save(_ project: inout TaskProject) async throws {
        var input = project
        project = try await database.writer.write { db in
            var copy = input
            try copy.save(db)
            return copy
        }
        _ = input
    }

    /// Appends a new project at the end of the order.
    @discardableResult
    func create(name: String, colorHex: String? = nil) async throws -> TaskProject {
        var project = TaskProject(name: name, colorHex: colorHex)
        try await database.writer.write { db in
            let maxOrder = try Double.fetchOne(
                db, sql: "SELECT COALESCE(MAX(sortOrder), -1) FROM taskProject"
            ) ?? -1
            project.sortOrder = maxOrder + 1
            try project.insert(db)
        }
        return project
    }

    func setArchived(id: Int64, _ archived: Bool) async throws {
        try await database.writer.write { db in
            guard var project = try TaskProject.fetchOne(db, key: id) else { return }
            project.archivedAt = archived ? Date() : nil
            try project.update(db)
        }
    }

    /// Deletes a project and clears the link on its tasks (the column has no DB
    /// cascade). Tasks are not deleted — they fall back to "no project".
    func delete(id: Int64) async throws {
        try await database.writer.write { db in
            try db.execute(
                sql: "UPDATE actionItem SET projectId = NULL, updatedAt = ? WHERE projectId = ?",
                arguments: [Date(), id]
            )
            _ = try TaskProject.deleteOne(db, key: id)
        }
    }

    /// Persists a new order from the given project ids.
    func reorder(_ orderedIds: [Int64]) async throws {
        try await database.writer.write { db in
            for (index, pid) in orderedIds.enumerated() {
                try db.execute(
                    sql: "UPDATE taskProject SET sortOrder = ? WHERE id = ?",
                    arguments: [Double(index), pid]
                )
            }
        }
    }

    /// Assigns (or clears) a task's project. Routes through the task table so the
    /// change broadcast and `updatedAt` bump stay consistent.
    func assign(taskId: Int64, to projectId: Int64?) async throws {
        try await database.writer.write { db in
            try db.execute(
                sql: "UPDATE actionItem SET projectId = ?, updatedAt = ? WHERE id = ?",
                arguments: [projectId, Date(), taskId]
            )
        }
    }
}

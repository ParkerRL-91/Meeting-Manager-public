import Foundation
import GRDB

/// Repository for configurable Kanban stages. Enforces the stage invariants and
/// guarantees a stage deletion never silently orphans tasks (their `stageId` is
/// reassigned, not nulled, unless the caller asks otherwise).
final class TaskStageRepository {
    private let database: AppDatabase

    init(database: AppDatabase = .shared) {
        self.database = database
    }

    func allStages() async throws -> [TaskStage] {
        try await database.writer.read { db in
            try TaskStage.order(TaskStage.Columns.sortOrder.asc).fetchAll(db)
        }
    }

    func save(_ stage: inout TaskStage) async throws {
        var input = stage
        input.updatedAt = Date()
        stage = try await database.writer.write { db in
            var copy = input
            try copy.save(db)
            return copy
        }
    }

    /// Deletes a stage after moving its tasks to `reassignTo` (or, if nil, the
    /// default stage, or any other stage). Refuses to delete the last stage.
    func delete(id: Int64, reassignTo: Int64? = nil) async throws {
        try await database.writer.write { db in
            let remaining = try TaskStage.filter(TaskStage.Columns.id != id)
                .order(TaskStage.Columns.sortOrder.asc).fetchAll(db)
            guard !remaining.isEmpty else { return } // never delete the last stage
            let fallback = reassignTo
                ?? remaining.first(where: { $0.isDefault })?.id
                ?? remaining.first?.id
            try db.execute(
                sql: "UPDATE actionItem SET stageId = ?, updatedAt = ? WHERE stageId = ?",
                arguments: [fallback, Date(), id]
            )
            _ = try TaskStage.deleteOne(db, key: id)
        }
    }

    /// Persists a new left→right order from the given stage ids.
    func reorder(_ orderedIds: [Int64]) async throws {
        try await database.writer.write { db in
            for (index, sid) in orderedIds.enumerated() {
                try db.execute(
                    sql: "UPDATE taskStage SET sortOrder = ?, updatedAt = ? WHERE id = ?",
                    arguments: [Double(index), Date(), sid]
                )
            }
        }
    }

    /// Makes exactly one stage the default.
    func setDefault(id: Int64) async throws {
        try await database.writer.write { db in
            try db.execute(
                sql: "UPDATE taskStage SET isDefault = (id = ?), updatedAt = ?",
                arguments: [id, Date()]
            )
        }
    }
}

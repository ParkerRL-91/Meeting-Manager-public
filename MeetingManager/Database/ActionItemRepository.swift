import Foundation
import GRDB

/// Repository for tasks (the `actionItem` table — the unified task model; see
/// PRJ-013). Owns the single completion path (`setCompleted`), triage
/// transitions, the Kanban/board reads, smart lists, and soft-delete.
///
/// Naming note: the type keeps the `ActionItemRepository` name for now; the
/// `TaskRepository` rename is a deferred, isolated cleanup (PRJ-013 Phase 8).
final class ActionItemRepository {
    private let database: AppDatabase

    init(database: AppDatabase = .shared) {
        self.database = database
    }

    // MARK: - Writes

    func save(_ item: inout ActionItem) async throws {
        // Flow the saved record (with its auto-assigned rowid) back via the write
        // closure's RETURN VALUE — mutating a captured `var` inside GRDB's
        // @Sendable async write does NOT propagate to the caller.
        var input = item
        input.updatedAt = Date()
        item = try await database.writer.write { db in
            var copy = input
            try copy.save(db)
            return copy
        }
    }

    func saveBatch(_ items: [ActionItem]) async throws {
        try await database.writer.write { db in
            for var item in items {
                try item.save(db)
            }
        }
    }

    // MARK: - Per-meeting reads

    /// ALL rows for a meeting, regardless of triage state. Backs per-meeting
    /// display views AND the re-extraction dedupe guard — must stay UNFILTERED so
    /// re-extraction stays idempotent across inbox + accepted rows.
    func itemsForMeeting(_ meetingId: String) async throws -> [ActionItem] {
        try await database.writer.read { db in
            try ActionItem
                .filter(ActionItem.Columns.meetingId == meetingId)
                .order(ActionItem.Columns.extractedAt.asc)
                .fetchAll(db)
        }
    }

    /// Only ACCEPTED, non-deleted items for a meeting — the "real tasks" view used
    /// by cross-meeting rollups / series carry-forward so inbox suggestions don't
    /// leak into prompts.
    func acceptedItemsForMeeting(_ meetingId: String) async throws -> [ActionItem] {
        try await database.writer.read { db in
            try ActionItem
                .filter(ActionItem.Columns.meetingId == meetingId)
                .filter(ActionItem.Columns.triageState == TaskTriageState.accepted.rawValue)
                .filter(ActionItem.Columns.deletedAt == nil)
                .order(ActionItem.Columns.extractedAt.asc)
                .fetchAll(db)
        }
    }

    // MARK: - Global "real task" reads (gated to accepted + not-deleted)

    func allOpenItems(limit: Int = 100) async throws -> [ActionItem] {
        try await database.writer.read { db in
            try ActionItem
                .filter(ActionItem.Columns.triageState == TaskTriageState.accepted.rawValue)
                .filter(ActionItem.Columns.deletedAt == nil)
                .filter(ActionItem.Columns.isCompleted == false)
                .order(ActionItem.Columns.extractedAt.asc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// Returns open action items where the assignee fuzzy-matches any name in the
    /// participant list. Builds on `allOpenItems`, so the accepted/not-deleted gate
    /// is inherited.
    func openItemsForParticipants(_ participants: [String]) async throws -> [ActionItem] {
        guard !participants.isEmpty else { return [] }

        let allOpen = try await allOpenItems(limit: 500)

        let fullNames = Set(participants.map { $0.lowercased().trimmingCharacters(in: .whitespaces) })
        let firstNames = Set(participants.compactMap { name -> String? in
            let first = name.components(separatedBy: .whitespaces).first?.lowercased()
            guard let first, first.count >= 2 else { return nil }
            return first
        })

        return allOpen.filter { item in
            guard let assignee = item.assignee?.lowercased().trimmingCharacters(in: .whitespaces),
                  !assignee.isEmpty else { return false }
            if fullNames.contains(assignee) { return true }
            if firstNames.contains(assignee) { return true }
            if fullNames.contains(where: { $0.hasPrefix(assignee) }) { return true }
            let assigneeFirst = assignee.components(separatedBy: .whitespaces).first ?? assignee
            if assigneeFirst.count >= 2 && firstNames.contains(assigneeFirst) { return true }
            return false
        }
    }

    // MARK: - Board / triage / subtask reads

    /// Accepted, non-deleted, non-archived top-level tasks for the Kanban board,
    /// ordered for stacking within a column.
    func boardTasks() async throws -> [ActionItem] {
        try await database.writer.read { db in
            try ActionItem
                .filter(ActionItem.Columns.triageState == TaskTriageState.accepted.rawValue)
                .filter(ActionItem.Columns.deletedAt == nil)
                .filter(ActionItem.Columns.archivedAt == nil)
                .filter(ActionItem.Columns.parentTaskId == nil)
                .order(ActionItem.Columns.sortOrder.asc, ActionItem.Columns.createdAt.asc)
                .fetchAll(db)
        }
    }

    /// The review queue: AI-identified items awaiting accept/dismiss.
    func inboxItems() async throws -> [ActionItem] {
        try await fetchByTriage(.inbox)
    }

    func dismissedItems() async throws -> [ActionItem] {
        try await fetchByTriage(.dismissed)
    }

    private func fetchByTriage(_ state: TaskTriageState) async throws -> [ActionItem] {
        try await database.writer.read { db in
            try ActionItem
                .filter(ActionItem.Columns.triageState == state.rawValue)
                .filter(ActionItem.Columns.deletedAt == nil)
                .order(ActionItem.Columns.createdAt.desc)
                .fetchAll(db)
        }
    }

    func subtasks(of parentId: Int64) async throws -> [ActionItem] {
        try await database.writer.read { db in
            try ActionItem
                .filter(ActionItem.Columns.parentTaskId == parentId)
                .filter(ActionItem.Columns.deletedAt == nil)
                .order(ActionItem.Columns.sortOrder.asc, ActionItem.Columns.createdAt.asc)
                .fetchAll(db)
        }
    }

    func find(id: Int64) async throws -> ActionItem? {
        try await database.writer.read { db in try ActionItem.fetchOne(db, key: id) }
    }

    // MARK: - Smart lists (accepted, live, incomplete)

    /// Overdue: due before the start of today and not completed.
    func overdueItems() async throws -> [ActionItem] {
        let startOfToday = Calendar.current.startOfDay(for: Date())
        return try await liveIncomplete { query in
            query.filter(ActionItem.Columns.dueDate != nil)
                 .filter(ActionItem.Columns.dueDate < startOfToday)
        }
    }

    /// Due today.
    func dueTodayItems() async throws -> [ActionItem] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? start
        return try await liveIncomplete { query in
            query.filter(ActionItem.Columns.dueDate >= start)
                 .filter(ActionItem.Columns.dueDate < end)
        }
    }

    /// Due after today.
    func upcomingItems() async throws -> [ActionItem] {
        let cal = Calendar.current
        let end = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date())) ?? Date()
        return try await liveIncomplete { query in
            query.filter(ActionItem.Columns.dueDate >= end)
        }
    }

    /// Live, incomplete tasks with no due date (Someday).
    func noDateItems() async throws -> [ActionItem] {
        try await liveIncomplete { query in
            query.filter(ActionItem.Columns.dueDate == nil)
        }
    }

    private func liveIncomplete(
        _ refine: @escaping @Sendable (QueryInterfaceRequest<ActionItem>) -> QueryInterfaceRequest<ActionItem>
    ) async throws -> [ActionItem] {
        try await database.writer.read { db in
            let base = ActionItem
                .filter(ActionItem.Columns.triageState == TaskTriageState.accepted.rawValue)
                .filter(ActionItem.Columns.deletedAt == nil)
                .filter(ActionItem.Columns.archivedAt == nil)
                .filter(ActionItem.Columns.isCompleted == false)
            return try refine(base)
                .order(ActionItem.Columns.dueDate.asc, ActionItem.Columns.priority.desc)
                .fetchAll(db)
        }
    }

    // MARK: - Completion (single source of truth)

    /// THE only writer of `isCompleted` + `completedAt`. Also moves the task to a
    /// terminal stage on completion and off it (→ default) on un-completion, so
    /// the isCompleted⇄terminal-stage invariant can never diverge.
    func setCompleted(id: Int64, _ completed: Bool) async throws {
        try await database.writer.write { db in
            guard var item = try ActionItem.fetchOne(db, key: id) else { return }
            try Self.applyCompletion(&item, completed: completed, db: db)
            item.updatedAt = Date()
            try item.update(db)
        }
    }

    /// Shared completion/stage logic — used by `setCompleted` and by the one-time
    /// importer (PRJ-013 Phase 2) so both paths converge on one rule rather than a
    /// raw `isCompleted` write.
    static func applyCompletion(_ item: inout ActionItem, completed: Bool, db: Database) throws {
        if completed {
            item.isCompleted = true
            if item.completedAt == nil { item.completedAt = Date() }
            if let terminal = try terminalStageId(db) { item.stageId = terminal }
        } else {
            item.isCompleted = false
            item.completedAt = nil
            if let terminal = try terminalStageId(db), item.stageId == terminal {
                item.stageId = try defaultStageId(db)
            }
        }
    }

    /// Back-compat shim — routes the old toggle through the single completion owner.
    func toggleComplete(id: Int64) async throws {
        let current = (try await find(id: id))?.isCompleted ?? false
        try await setCompleted(id: id, !current)
    }

    // MARK: - Stage moves / ordering

    func moveToStage(id: Int64, stageId: Int64?, sortOrder: Double? = nil) async throws {
        try await database.writer.write { db in
            guard var item = try ActionItem.fetchOne(db, key: id) else { return }
            item.stageId = stageId
            if let sortOrder { item.sortOrder = sortOrder }
            if let stageId, let stage = try TaskStage.fetchOne(db, key: stageId) {
                if stage.isTerminal {
                    item.isCompleted = true
                    if item.completedAt == nil { item.completedAt = Date() }
                } else if item.isCompleted {
                    item.isCompleted = false
                    item.completedAt = nil
                }
            }
            item.updatedAt = Date()
            try item.update(db)
        }
    }

    func reorder(id: Int64, sortOrder: Double) async throws {
        try await database.writer.write { db in
            guard var item = try ActionItem.fetchOne(db, key: id) else { return }
            item.sortOrder = sortOrder
            item.updatedAt = Date()
            try item.update(db)
        }
    }

    // MARK: - Triage transitions

    func accept(id: Int64, stageId: Int64? = nil) async throws {
        try await database.writer.write { db in
            guard var item = try ActionItem.fetchOne(db, key: id) else { return }
            item.triageState = .accepted
            item.stageId = try stageId ?? Self.defaultStageId(db)
            item.updatedAt = Date()
            try item.update(db)
        }
    }

    func dismiss(id: Int64) async throws { try await setTriage(id: id, .dismissed) }
    func restoreToInbox(id: Int64) async throws { try await setTriage(id: id, .inbox) }

    private func setTriage(id: Int64, _ state: TaskTriageState) async throws {
        try await database.writer.write { db in
            guard var item = try ActionItem.fetchOne(db, key: id) else { return }
            item.triageState = state
            item.updatedAt = Date()
            try item.update(db)
        }
    }

    // MARK: - Archive / soft-delete

    func setArchived(id: Int64, _ archived: Bool) async throws {
        try await database.writer.write { db in
            guard var item = try ActionItem.fetchOne(db, key: id) else { return }
            item.archivedAt = archived ? Date() : nil
            item.updatedAt = Date()
            try item.update(db)
        }
    }

    /// Soft delete: marks `deletedAt` (and cascades to subtasks in app code, since
    /// the parent self-reference has no DB FK). On-disk attachment files survive
    /// until `purgeDeleted` so an Undo can fully restore.
    func softDelete(id: Int64) async throws {
        try await database.writer.write { db in
            let now = Date()
            for var item in try ActionItem.filter(ActionItem.Columns.parentTaskId == id).fetchAll(db) {
                item.deletedAt = now
                item.updatedAt = now
                try item.update(db)
            }
            guard var item = try ActionItem.fetchOne(db, key: id) else { return }
            item.deletedAt = now
            item.updatedAt = now
            try item.update(db)
        }
    }

    func undoDelete(id: Int64) async throws {
        try await database.writer.write { db in
            for var item in try ActionItem.filter(ActionItem.Columns.parentTaskId == id).fetchAll(db) {
                item.deletedAt = nil
                try item.update(db)
            }
            guard var item = try ActionItem.fetchOne(db, key: id) else { return }
            item.deletedAt = nil
            try item.update(db)
        }
    }

    /// Hard-deletes tasks soft-deleted before `cutoff` and returns the relative
    /// paths of their attachments so the caller can remove the on-disk files
    /// (the DB cascade only removes attachment rows). PRJ-013 Phase 4 wires the
    /// file cleanup; until then this safely no-ops on files.
    @discardableResult
    func purgeDeleted(olderThan cutoff: Date) async throws -> [String] {
        try await database.writer.write { db in
            let doomed = try ActionItem
                .filter(ActionItem.Columns.deletedAt != nil)
                .filter(ActionItem.Columns.deletedAt < cutoff)
                .fetchAll(db)
            guard !doomed.isEmpty else { return [] }
            let ids = doomed.compactMap(\.id)
            let paths = try TaskAttachment
                .filter(ids.contains(TaskAttachment.Columns.taskId))
                .fetchAll(db)
                .map(\.relativePath)
            _ = try ActionItem.filter(keys: ids).deleteAll(db)
            return paths
        }
    }

    func delete(_ item: ActionItem) async throws {
        try await database.writer.write { db in
            _ = try item.delete(db)
        }
    }

    // MARK: - Stage helpers

    private static func defaultStageId(_ db: Database) throws -> Int64? {
        try TaskStage.filter(TaskStage.Columns.isDefault == true).fetchOne(db)?.id
    }

    private static func terminalStageId(_ db: Database) throws -> Int64? {
        try TaskStage
            .filter(TaskStage.Columns.isTerminal == true)
            .order(TaskStage.Columns.sortOrder.asc)
            .fetchOne(db)?.id
    }
}

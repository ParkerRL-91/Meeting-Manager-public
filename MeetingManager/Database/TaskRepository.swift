import Foundation
import GRDB

/// Repository for tasks (the `actionItem` table — the unified task model; see
/// PRJ-013). Owns the single completion path (`setCompleted`), triage
/// transitions, the Kanban/board reads, smart lists, and soft-delete.
///
/// Naming note: the type keeps the `TaskRepository` name for now; the
/// `TaskRepository` rename is a deferred, isolated cleanup (PRJ-013 Phase 8).
final class TaskRepository {
    private let database: AppDatabase

    init(database: AppDatabase = .shared) {
        self.database = database
    }

    // MARK: - Writes

    func save(_ item: inout TaskItem) async throws {
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
        announceChange()
    }

    func saveBatch(_ items: [TaskItem]) async throws {
        try await database.writer.write { db in
            for var item in items {
                try item.save(db)
            }
        }
        announceChange()
    }

    /// Inserts imported tasks (PRJ-013 Phase 2). Each pair carries the source
    /// reminder's completion flag; completion + stage are applied through the
    /// shared `applyCompletion` helper so incomplete items land in the default
    /// stage and completed items land in the terminal stage with `completedAt` —
    /// never a raw `isCompleted` write. Items default to the default stage first
    /// so an incomplete import gets a board home immediately.
    func insertImported(_ items: [(item: TaskItem, completed: Bool)]) async throws {
        guard !items.isEmpty else { return }
        try await database.writer.write { db in
            let defaultStage = try Self.defaultStageId(db)
            for (var item, completed) in items {
                item.stageId = defaultStage
                try Self.applyCompletion(&item, completed: completed, db: db)
                try item.insert(db)
            }
        }
        announceChange()
    }

    // MARK: - Per-meeting reads

    /// ALL rows for a meeting, regardless of triage state. Backs per-meeting
    /// display views AND the re-extraction dedupe guard — must stay UNFILTERED so
    /// re-extraction stays idempotent across inbox + accepted rows.
    func itemsForMeeting(_ meetingId: String) async throws -> [TaskItem] {
        try await database.writer.read { db in
            try TaskItem
                .filter(TaskItem.Columns.meetingId == meetingId)
                .order(TaskItem.Columns.extractedAt.asc)
                .fetchAll(db)
        }
    }

    /// Only ACCEPTED, non-deleted items for a meeting — the "real tasks" view used
    /// by cross-meeting rollups / series carry-forward so inbox suggestions don't
    /// leak into prompts.
    func acceptedItemsForMeeting(_ meetingId: String) async throws -> [TaskItem] {
        try await database.writer.read { db in
            try TaskItem
                .filter(TaskItem.Columns.meetingId == meetingId)
                .filter(TaskItem.Columns.triageState == TaskTriageState.accepted.rawValue)
                .filter(TaskItem.Columns.deletedAt == nil)
                .order(TaskItem.Columns.extractedAt.asc)
                .fetchAll(db)
        }
    }

    // MARK: - Global "real task" reads (gated to accepted + not-deleted)

    func allOpenItems(limit: Int = 100) async throws -> [TaskItem] {
        try await database.writer.read { db in
            try TaskItem
                .filter(TaskItem.Columns.triageState == TaskTriageState.accepted.rawValue)
                .filter(TaskItem.Columns.deletedAt == nil)
                .filter(TaskItem.Columns.isCompleted == false)
                .order(TaskItem.Columns.extractedAt.asc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// Returns open action items where the assignee fuzzy-matches any name in the
    /// participant list. Builds on `allOpenItems`, so the accepted/not-deleted gate
    /// is inherited.
    func openItemsForParticipants(_ participants: [String]) async throws -> [TaskItem] {
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
    func boardTasks() async throws -> [TaskItem] {
        try await database.writer.read { db in
            try TaskItem
                .filter(TaskItem.Columns.triageState == TaskTriageState.accepted.rawValue)
                .filter(TaskItem.Columns.deletedAt == nil)
                .filter(TaskItem.Columns.archivedAt == nil)
                .filter(TaskItem.Columns.parentTaskId == nil)
                .order(TaskItem.Columns.sortOrder.asc, TaskItem.Columns.createdAt.asc)
                .fetchAll(db)
        }
    }

    /// The review queue: AI-identified items awaiting accept/dismiss.
    func inboxItems() async throws -> [TaskItem] {
        try await fetchByTriage(.inbox)
    }

    func dismissedItems() async throws -> [TaskItem] {
        try await fetchByTriage(.dismissed)
    }

    private func fetchByTriage(_ state: TaskTriageState) async throws -> [TaskItem] {
        try await database.writer.read { db in
            try TaskItem
                .filter(TaskItem.Columns.triageState == state.rawValue)
                .filter(TaskItem.Columns.deletedAt == nil)
                .order(TaskItem.Columns.createdAt.desc)
                .fetchAll(db)
        }
    }

    func subtasks(of parentId: Int64) async throws -> [TaskItem] {
        try await database.writer.read { db in
            try TaskItem
                .filter(TaskItem.Columns.parentTaskId == parentId)
                .filter(TaskItem.Columns.deletedAt == nil)
                .order(TaskItem.Columns.sortOrder.asc, TaskItem.Columns.createdAt.asc)
                .fetchAll(db)
        }
    }

    func find(id: Int64) async throws -> TaskItem? {
        try await database.writer.read { db in try TaskItem.fetchOne(db, key: id) }
    }

    /// All non-deleted items from a given origin (e.g. "import"). Backs the
    /// one-time importer's de-dupe so a re-run stays idempotent.
    func itemsBySource(_ source: String) async throws -> [TaskItem] {
        try await database.writer.read { db in
            try TaskItem
                .filter(TaskItem.Columns.source == source)
                .filter(TaskItem.Columns.deletedAt == nil)
                .fetchAll(db)
        }
    }

    // MARK: - Smart lists (accepted, live, incomplete)

    /// Overdue: due before the start of today and not completed.
    func overdueItems() async throws -> [TaskItem] {
        let startOfToday = Calendar.current.startOfDay(for: Date())
        return try await liveIncomplete { query in
            query.filter(TaskItem.Columns.dueDate != nil)
                 .filter(TaskItem.Columns.dueDate < startOfToday)
        }
    }

    /// Due today.
    func dueTodayItems() async throws -> [TaskItem] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? start
        return try await liveIncomplete { query in
            query.filter(TaskItem.Columns.dueDate >= start)
                 .filter(TaskItem.Columns.dueDate < end)
        }
    }

    /// Due after today.
    func upcomingItems() async throws -> [TaskItem] {
        let cal = Calendar.current
        let end = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date())) ?? Date()
        return try await liveIncomplete { query in
            query.filter(TaskItem.Columns.dueDate >= end)
        }
    }

    /// Live, incomplete tasks with no due date (Someday).
    func noDateItems() async throws -> [TaskItem] {
        try await liveIncomplete { query in
            query.filter(TaskItem.Columns.dueDate == nil)
        }
    }

    // MARK: - History (PRJ-013 Phase 6)

    /// Which closed-out set the All view's history filter is showing.
    enum HistoryScope { case completed, archived, dismissed, trash }

    /// Read-only history lists for the All view's history filter. `completed`
    /// returns accepted, completed, live (not deleted/archived) tasks; `archived`
    /// returns archived (not deleted) tasks; `dismissed` returns dismissed (not
    /// deleted) suggestions; `trash` returns soft-deleted rows awaiting purge.
    func historyItems(_ scope: HistoryScope) async throws -> [TaskItem] {
        try await database.writer.read { db in
            let request: QueryInterfaceRequest<TaskItem>
            switch scope {
            case .completed:
                request = TaskItem
                    .filter(TaskItem.Columns.triageState == TaskTriageState.accepted.rawValue)
                    .filter(TaskItem.Columns.deletedAt == nil)
                    .filter(TaskItem.Columns.archivedAt == nil)
                    .filter(TaskItem.Columns.isCompleted == true)
                    .order(TaskItem.Columns.completedAt.desc)
            case .archived:
                request = TaskItem
                    .filter(TaskItem.Columns.archivedAt != nil)
                    .filter(TaskItem.Columns.deletedAt == nil)
                    .order(TaskItem.Columns.archivedAt.desc)
            case .dismissed:
                request = TaskItem
                    .filter(TaskItem.Columns.triageState == TaskTriageState.dismissed.rawValue)
                    .filter(TaskItem.Columns.deletedAt == nil)
                    .order(TaskItem.Columns.updatedAt.desc)
            case .trash:
                request = TaskItem
                    .filter(TaskItem.Columns.deletedAt != nil)
                    .order(TaskItem.Columns.deletedAt.desc)
            }
            return try request.fetchAll(db)
        }
    }

    /// Sets a task's due date (and clears any explicit reminder so the per-task
    /// alert recomputes from the new due date). Backs the Today view's in-app
    /// snooze/defer — repositioning a task in the smart lists without opening the
    /// editor. Announces a change so the notification reconcile reschedules.
    func setDueDate(id: Int64, _ date: Date?) async throws {
        try await database.writer.write { db in
            guard var item = try TaskItem.fetchOne(db, key: id) else { return }
            item.dueDate = date
            item.reminderAt = nil
            item.updatedAt = Date()
            try item.update(db)
        }
        announceChange()
    }

    // MARK: - Notification candidates (PRJ-013 Phase 5)

    /// Live (accepted, incomplete, not deleted, not archived) tasks that carry a
    /// `reminderAt` OR a `dueDate` — the exact set eligible for a per-task due
    /// alert. No-date tasks are excluded by design (they never fire). Backs the
    /// `NotificationService` reconcile.
    func notificationCandidates() async throws -> [TaskItem] {
        try await liveIncomplete { query in
            query.filter(TaskItem.Columns.reminderAt != nil || TaskItem.Columns.dueDate != nil)
        }
    }

    /// Counts for the merged morning brief: overdue (due before today) and
    /// due-today live incomplete tasks.
    func overdueAndDueTodayCounts() async throws -> (overdue: Int, dueToday: Int) {
        let overdue = try await overdueItems().count
        let dueToday = try await dueTodayItems().count
        return (overdue, dueToday)
    }

    /// Push a task's reminder forward by `days` (notification Snooze). Sets
    /// `reminderAt` relative to its current reminder/due time, or `now` if it had
    /// neither. Returns the updated task so the caller can reschedule its alert.
    @discardableResult
    func snoozeReminder(id: Int64, byDays days: Int) async throws -> TaskItem? {
        let updated = try await database.writer.write { db -> TaskItem? in
            guard var item = try TaskItem.fetchOne(db, key: id) else { return nil }
            let base = item.reminderAt ?? item.dueDate ?? Date()
            item.reminderAt = Calendar.current.date(byAdding: .day, value: days, to: base) ?? base
            item.updatedAt = Date()
            try item.update(db)
            return item
        }
        announceChange()
        return updated
    }

    private func liveIncomplete(
        _ refine: @escaping @Sendable (QueryInterfaceRequest<TaskItem>) -> QueryInterfaceRequest<TaskItem>
    ) async throws -> [TaskItem] {
        try await database.writer.read { db in
            let base = TaskItem
                .filter(TaskItem.Columns.triageState == TaskTriageState.accepted.rawValue)
                .filter(TaskItem.Columns.deletedAt == nil)
                .filter(TaskItem.Columns.archivedAt == nil)
                .filter(TaskItem.Columns.isCompleted == false)
            return try refine(base)
                .order(TaskItem.Columns.dueDate.asc, TaskItem.Columns.priority.desc)
                .fetchAll(db)
        }
    }

    // MARK: - Completion (single source of truth)

    /// THE only writer of `isCompleted` + `completedAt`. Also moves the task to a
    /// terminal stage on completion and off it (→ default) on un-completion, so
    /// the isCompleted⇄terminal-stage invariant can never diverge.
    func setCompleted(id: Int64, _ completed: Bool) async throws {
        try await database.writer.write { db in
            guard var item = try TaskItem.fetchOne(db, key: id) else { return }
            try Self.applyCompletion(&item, completed: completed, db: db)
            item.updatedAt = Date()
            try item.update(db)
        }
        announceChange()
    }

    /// Shared completion/stage logic — used by `setCompleted`, `moveToStage` (when
    /// landing on a terminal stage), and the one-time importer (PRJ-013 Phase 2) so
    /// every completion converges on one rule rather than a raw `isCompleted` write.
    /// On the incomplete → complete transition it spawns the next occurrence of a
    /// recurring task exactly once (PRJ-013 Phase 7) — inside this same transaction.
    static func applyCompletion(_ item: inout TaskItem, completed: Bool, db: Database) throws {
        let wasCompleted = item.isCompleted
        if completed {
            item.isCompleted = true
            if item.completedAt == nil { item.completedAt = Date() }
            if let terminal = try terminalStageId(db) { item.stageId = terminal }
            try TaskRecurrenceService.spawnNextIfNeeded(for: item, wasCompleted: wasCompleted, db: db)
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
            guard var item = try TaskItem.fetchOne(db, key: id) else { return }
            if let sortOrder { item.sortOrder = sortOrder }
            if let stageId, let stage = try TaskStage.fetchOne(db, key: stageId) {
                // Terminal/non-terminal completion converges through applyCompletion
                // so drag-to-Done spawns a recurring task's next occurrence exactly
                // once, identically to the checkbox path. applyCompletion also sets
                // stageId to the terminal stage on completion.
                if stage.isTerminal {
                    try Self.applyCompletion(&item, completed: true, db: db)
                } else {
                    if item.isCompleted {
                        try Self.applyCompletion(&item, completed: false, db: db)
                    }
                    item.stageId = stageId
                }
            } else {
                item.stageId = stageId
            }
            item.updatedAt = Date()
            try item.update(db)
        }
        announceChange()
    }

    /// Assigns (or clears) a task's project (PRJ-013 Phase 7).
    func setProject(id: Int64, projectId: Int64?) async throws {
        try await database.writer.write { db in
            guard var item = try TaskItem.fetchOne(db, key: id) else { return }
            item.projectId = projectId
            item.updatedAt = Date()
            try item.update(db)
        }
        announceChange()
    }

    func reorder(id: Int64, sortOrder: Double) async throws {
        try await database.writer.write { db in
            guard var item = try TaskItem.fetchOne(db, key: id) else { return }
            item.sortOrder = sortOrder
            item.updatedAt = Date()
            try item.update(db)
        }
    }

    // MARK: - Triage transitions

    func accept(id: Int64, stageId: Int64? = nil) async throws {
        try await database.writer.write { db in
            guard var item = try TaskItem.fetchOne(db, key: id) else { return }
            item.triageState = .accepted
            item.stageId = try stageId ?? Self.defaultStageId(db)
            item.updatedAt = Date()
            try item.update(db)
        }
        announceChange()
    }

    func dismiss(id: Int64) async throws { try await setTriage(id: id, .dismissed) }
    func restoreToInbox(id: Int64) async throws { try await setTriage(id: id, .inbox) }

    private func setTriage(id: Int64, _ state: TaskTriageState) async throws {
        try await database.writer.write { db in
            guard var item = try TaskItem.fetchOne(db, key: id) else { return }
            item.triageState = state
            item.updatedAt = Date()
            try item.update(db)
        }
        announceChange()
    }

    // MARK: - Archive / soft-delete

    func setArchived(id: Int64, _ archived: Bool) async throws {
        try await database.writer.write { db in
            guard var item = try TaskItem.fetchOne(db, key: id) else { return }
            item.archivedAt = archived ? Date() : nil
            item.updatedAt = Date()
            try item.update(db)
        }
        announceChange()
    }

    /// Soft delete: marks `deletedAt` (and cascades to subtasks in app code, since
    /// the parent self-reference has no DB FK). On-disk attachment files survive
    /// until `purgeDeleted` so an Undo can fully restore.
    func softDelete(id: Int64) async throws {
        try await database.writer.write { db in
            let now = Date()
            for var item in try TaskItem.filter(TaskItem.Columns.parentTaskId == id).fetchAll(db) {
                item.deletedAt = now
                item.updatedAt = now
                try item.update(db)
            }
            guard var item = try TaskItem.fetchOne(db, key: id) else { return }
            item.deletedAt = now
            item.updatedAt = now
            try item.update(db)
        }
        announceChange()
    }

    func undoDelete(id: Int64) async throws {
        try await database.writer.write { db in
            for var item in try TaskItem.filter(TaskItem.Columns.parentTaskId == id).fetchAll(db) {
                item.deletedAt = nil
                try item.update(db)
            }
            guard var item = try TaskItem.fetchOne(db, key: id) else { return }
            item.deletedAt = nil
            try item.update(db)
        }
        announceChange()
    }

    /// Hard-deletes tasks soft-deleted before `cutoff` and returns the relative
    /// paths of their attachments so the caller can remove the on-disk files
    /// (the DB cascade only removes attachment rows). `TaskAttachmentService
    /// .purgeDeletedTasks(olderThan:)` is the single caller that pairs this with
    /// the on-disk file removal.
    @discardableResult
    func purgeDeleted(olderThan cutoff: Date) async throws -> [String] {
        try await database.writer.write { db in
            let doomed = try TaskItem
                .filter(TaskItem.Columns.deletedAt != nil)
                .filter(TaskItem.Columns.deletedAt < cutoff)
                .fetchAll(db)
            guard !doomed.isEmpty else { return [] }
            let ids = doomed.compactMap(\.id)
            let paths = try TaskAttachment
                .filter(ids.contains(TaskAttachment.Columns.taskId))
                .fetchAll(db)
                .map(\.relativePath)
            _ = try TaskItem.filter(keys: ids).deleteAll(db)
            return paths
        }
    }

    func delete(_ item: TaskItem) async throws {
        try await database.writer.write { db in
            _ = try item.delete(db)
        }
        announceChange()
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

    // MARK: - Change broadcast (PRJ-013 Phase 5)

    /// Announce that task data changed so observers (AppState → the per-task
    /// notification reconcile) can react. Posted after every mutation that can
    /// affect due-alert eligibility. Decoupled via NotificationCenter so the
    /// repository stays UI-agnostic; the single observer debounces.
    private func announceChange() {
        NotificationCenter.default.post(name: .taskDataDidChange, object: nil)
    }
}

extension Notification.Name {
    /// Posted by `TaskRepository` after any task mutation. AppState observes
    /// it to reconcile per-task due notifications (PRJ-013 Phase 5).
    static let taskDataDidChange = Notification.Name("taskDataDidChange")
}

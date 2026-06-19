import UserNotifications
import os

/// Per-task due/overdue local notifications (PRJ-013 Phase 5).
///
/// Mirrors the meeting-reminder reliability model in `NotificationService`:
/// a diff-based reconcile (`rescheduleAllTaskNotificationsAsync`) reads the
/// currently pending `task-due-*` requests, computes the desired set from the
/// live dated tasks, and only adds/updates what changed — cancelling alerts for
/// tasks that became complete / dismissed / deleted / archived or lost their
/// date. A single notification per task fires at `reminderAt` (preferred) or
/// `dueDate`. No-date tasks never schedule an alert.
extension NotificationService {

    private var taskCenter: UNUserNotificationCenter { UNUserNotificationCenter.current() }

    static func taskNotificationIdentifier(for taskId: Int64) -> String {
        "task-due-\(taskId)"
    }

    /// The moment a task should ping: explicit `reminderAt` wins over `dueDate`.
    static func fireDate(for task: TaskItem) -> Date? {
        task.reminderAt ?? task.dueDate
    }

    // MARK: - Schedule one

    /// Schedule (or replace) the single due alert for one task. No-ops when the
    /// task has no fire date or the fire date is in the past.
    @discardableResult
    func scheduleTaskDueNotification(for task: TaskItem) async -> Bool {
        guard let id = task.id else { return false }
        guard let fire = Self.fireDate(for: task) else { return false }

        let secondsUntilFire = fire.timeIntervalSinceNow
        let identifier = Self.taskNotificationIdentifier(for: id)

        // Past or too-close fire dates don't schedule. We still clear any stale
        // pending request so an edit that moves a date into the past cancels.
        guard secondsUntilFire >= 1 else {
            taskCenter.removePendingNotificationRequests(withIdentifiers: [identifier])
            return false
        }

        let content = UNMutableNotificationContent()
        content.title = "Task due"
        content.body = Self.taskBody(for: task)
        content.sound = .default
        content.categoryIdentifier = NotificationActions.overdueTaskCategory
        content.userInfo = ["taskId": String(id)]

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: secondsUntilFire, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)

        return await withCheckedContinuation { continuation in
            taskCenter.add(request) { error in
                if let error {
                    Logger.notifications.error("[TaskNotif] failed to schedule task \(id): \(error.localizedDescription)")
                    continuation.resume(returning: false)
                } else {
                    Logger.notifications.info("[TaskNotif] scheduled task \(id) to fire in \(Int(secondsUntilFire))s")
                    continuation.resume(returning: true)
                }
            }
        }
    }

    /// Cancel the pending due alert for one task.
    func cancelTaskNotification(taskId: Int64) {
        taskCenter.removePendingNotificationRequests(
            withIdentifiers: [Self.taskNotificationIdentifier(for: taskId)]
        )
        Logger.notifications.debug("[TaskNotif] cancelled task \(taskId)")
    }

    /// Cancel every pending per-task alert. Used when the user turns the feature
    /// off in Settings.
    func cancelAllTaskNotifications() async {
        let pending = await pendingTaskNotifications()
        let ids = Array(pending.keys)
        if !ids.isEmpty {
            taskCenter.removePendingNotificationRequests(withIdentifiers: ids)
            Logger.notifications.info("[TaskNotif] cancelled \(ids.count) pending task alert(s)")
        }
    }

    // MARK: - Reconcile (diff)

    /// Diff the desired due-alert set against what's pending and apply the delta.
    /// `tasks` is the live dated-and-incomplete candidate set. When `enabled` is
    /// false every per-task alert is cancelled (the Settings toggle is off).
    @discardableResult
    func rescheduleAllTaskNotificationsAsync(tasks: [TaskItem], enabled: Bool) async -> (added: Int, kept: Int, removed: Int) {
        guard enabled else {
            await cancelAllTaskNotifications()
            return (0, 0, 0)
        }

        let pending = await pendingTaskNotifications()

        // Desired set keyed by identifier.
        var desired: [String: Date] = [:]
        var taskByIdentifier: [String: TaskItem] = [:]
        for task in tasks {
            guard let id = task.id, let fire = Self.fireDate(for: task) else { continue }
            guard fire.timeIntervalSinceNow >= 1 else { continue }
            let identifier = Self.taskNotificationIdentifier(for: id)
            desired[identifier] = fire
            taskByIdentifier[identifier] = task
        }

        // Cancel pending alerts no longer wanted.
        let stale = pending.keys.filter { desired[$0] == nil }
        if !stale.isEmpty {
            taskCenter.removePendingNotificationRequests(withIdentifiers: Array(stale))
        }

        var added = 0
        var kept = 0
        for (identifier, fire) in desired {
            if let existing = pending[identifier], abs(existing.timeIntervalSince(fire)) < 1 {
                kept += 1
                continue
            }
            if pending[identifier] != nil {
                taskCenter.removePendingNotificationRequests(withIdentifiers: [identifier])
            }
            if let task = taskByIdentifier[identifier] {
                if await scheduleTaskDueNotification(for: task) { added += 1 }
            }
        }

        Logger.notifications.info("[TaskNotif] reconcile complete: added=\(added) kept=\(kept) removed=\(stale.count)")
        return (added, kept, stale.count)
    }

    // MARK: - Helpers

    /// Read pending `task-due-*` requests and their fire dates.
    private func pendingTaskNotifications() async -> [String: Date] {
        await withCheckedContinuation { continuation in
            taskCenter.getPendingNotificationRequests { requests in
                var result: [String: Date] = [:]
                for req in requests where req.identifier.hasPrefix("task-due-") {
                    guard let fire = (req.trigger as? UNTimeIntervalNotificationTrigger)?.nextTriggerDate()
                        ?? (req.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate() else { continue }
                    result[req.identifier] = fire
                }
                continuation.resume(returning: result)
            }
        }
    }

    private static func taskBody(for task: TaskItem) -> String {
        if let assignee = task.assignee, !assignee.isEmpty {
            return "\(task.title) — \(assignee)"
        }
        return task.title
    }
}

import SwiftUI

/// Fires `action` when a background task whose `type` is in `types` and whose
/// `meetingId` matches transitions **into** `.completed`.
///
/// Meeting-detail tabs load their data once on appear, so the result of a
/// post-meeting task (transcription, summary, outline, …) only showed up after
/// navigating away and back, which re-mounted the tab. Watching the persistent
/// task queue for a completion edge lets the visible tab refresh in place.
///
/// The old→new diff matters: completed tasks linger in `allTasks`, so a plain
/// "contains a completed task" predicate would re-fire on every later array
/// change. Requiring the matching task to have been non-completed in the
/// previous snapshot makes this fire once per completion.
struct TaskCompletionRefreshModifier: ViewModifier {
    let meetingId: String
    let types: Set<TaskQueueItem.TaskType>
    /// Terminal statuses that trigger the refresh. Defaults to completion
    /// only; a consumer that must also react to FINAL failure (e.g. the
    /// transcript tab returning to the no-speech state after a failed Retry,
    /// TASK-123) opts into `.failed` explicitly — existing call sites keep
    /// their behavior.
    let statuses: Set<TaskQueueItem.TaskStatus>
    let tasks: [TaskQueueItem]
    let action: () -> Void

    func body(content: Content) -> some View {
        content.onChange(of: tasks) { oldTasks, newTasks in
            let justTransitioned = newTasks.contains { task in
                guard task.meetingId == meetingId,
                      types.contains(task.type),
                      statuses.contains(task.status) else { return false }
                // Fire only on the transition edge: the task was absent or not
                // yet in a triggering status in the previous snapshot.
                guard let previous = oldTasks.first(where: { $0.id == task.id }) else { return true }
                return !statuses.contains(previous.status)
            }
            if justTransitioned { action() }
        }
    }
}

extension View {
    /// Refresh this tab when a relevant background task for `meetingId`
    /// reaches a triggering terminal status (completion by default).
    func refreshOnTaskCompletion(
        meetingId: String,
        types: Set<TaskQueueItem.TaskType>,
        statuses: Set<TaskQueueItem.TaskStatus> = [.completed],
        tasks: [TaskQueueItem],
        perform action: @escaping () -> Void
    ) -> some View {
        modifier(TaskCompletionRefreshModifier(
            meetingId: meetingId, types: types, statuses: statuses, tasks: tasks, action: action
        ))
    }
}

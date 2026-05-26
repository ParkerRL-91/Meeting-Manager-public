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
    let tasks: [TaskQueueItem]
    let action: () -> Void

    func body(content: Content) -> some View {
        content.onChange(of: tasks) { oldTasks, newTasks in
            let justCompleted = newTasks.contains { task in
                guard task.meetingId == meetingId,
                      types.contains(task.type),
                      task.status == .completed else { return false }
                // Fire only on the transition edge: the task was absent or not
                // yet completed in the previous snapshot.
                guard let previous = oldTasks.first(where: { $0.id == task.id }) else { return true }
                return previous.status != .completed
            }
            if justCompleted { action() }
        }
    }
}

extension View {
    /// Refresh this tab when a relevant background task for `meetingId` completes.
    func refreshOnTaskCompletion(
        meetingId: String,
        types: Set<TaskQueueItem.TaskType>,
        tasks: [TaskQueueItem],
        perform action: @escaping () -> Void
    ) -> some View {
        modifier(TaskCompletionRefreshModifier(
            meetingId: meetingId, types: types, tasks: tasks, action: action
        ))
    }
}

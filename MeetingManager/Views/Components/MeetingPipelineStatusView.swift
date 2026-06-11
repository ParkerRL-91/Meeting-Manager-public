import SwiftUI

/// Live pipeline status for a meeting's empty tab states (TASK-041).
/// Instead of a generic placeholder, the tab tells the truth about the
/// queue: a failed task shows its humanized error with a Retry button, a
/// running task shows its current stage, and a queued task shows how many
/// tasks sit ahead of it. Only when the queue holds nothing relevant does
/// the caller's plain empty state render — optionally with a call-to-action
/// (e.g. "Transcribe Now" when audio exists but nothing was ever queued).
struct MeetingPipelineStatusView: View {
    @Environment(AppState.self) private var appState

    let meetingId: String
    let taskTypes: Set<TaskQueueItem.TaskType>
    let fallbackIcon: String
    let fallbackTitle: String
    let fallbackSubtitle: String
    var fallbackActionLabel: String? = nil
    var fallbackAction: (() async -> Void)? = nil

    private var relevantTasks: [TaskQueueItem] {
        appState.taskQueueManager.allTasks.filter {
            $0.meetingId == meetingId && taskTypes.contains($0.type)
        }
    }

    var body: some View {
        if let running = relevantTasks.first(where: { $0.status == .running }) {
            VStack(spacing: 10) {
                ProgressView()
                Text(stageText(for: running))
                    .font(.subheadline)
                    .foregroundStyle(Color.appTextSecondary)
            }
        } else if let pending = relevantTasks.first(where: { $0.status == .pending }) {
            let ahead = tasksAhead(of: pending)
            VStack(spacing: 8) {
                Image(systemName: "clock")
                    .font(.title2)
                    .foregroundStyle(Color.appTextTertiary)
                Text(ahead == 0
                     ? "\(pending.displayName) is queued — starting shortly."
                     : "\(pending.displayName) is queued behind \(ahead) other task\(ahead == 1 ? "" : "s").")
                    .font(.subheadline)
                    .foregroundStyle(Color.appTextSecondary)
            }
        } else if let failed = relevantTasks.last(where: { $0.status == .failed }) {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title2)
                    .foregroundStyle(.orange)
                Text(failed.error ?? "\(failed.displayName) failed.")
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color.appTextSecondary)
                    .frame(maxWidth: 420)
                Button("Try Again") {
                    Task {
                        await appState.taskQueueManager.retry(taskId: failed.id)
                        await appState.taskQueueManager.refreshTaskList()
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        } else {
            VStack(spacing: 12) {
                EmptyStateView(
                    icon: fallbackIcon,
                    title: fallbackTitle,
                    subtitle: fallbackSubtitle
                )
                if let label = fallbackActionLabel, let action = fallbackAction {
                    Button(label) { Task { await action() } }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                }
            }
        }
    }

    private func stageText(for task: TaskQueueItem) -> String {
        if appState.taskQueueManager.currentTask?.id == task.id,
           let stage = appState.taskQueueManager.currentProgress?.stage, !stage.isEmpty {
            return stage
        }
        return "\(task.displayName)…"
    }

    /// How many queued/running tasks the serial queue will run before this
    /// one (lower priority number pops first, then older creation).
    private func tasksAhead(of task: TaskQueueItem) -> Int {
        appState.taskQueueManager.allTasks.filter {
            ($0.status == .pending || $0.status == .running)
            && $0.id != task.id
            && ($0.priority < task.priority
                || ($0.priority == task.priority && $0.createdAt < task.createdAt))
        }.count
    }
}

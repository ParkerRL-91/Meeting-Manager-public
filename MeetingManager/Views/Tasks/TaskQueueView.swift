import SwiftUI

/// Full-page view of the background task queue — transcription, summarization, enrichment jobs.
struct TaskQueueView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let qm = appState.taskQueueManager
        let running = qm.allTasks.filter { $0.status == .running }
        let pending = qm.allTasks.filter { $0.status == .pending }
        let failed  = qm.allTasks.filter { $0.status == .failed }
        let done    = qm.allTasks.filter { $0.status == .completed }

        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                // MARK: - Header
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Tasks")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(Color.appTextPrimary)
                        Text("\(pending.count) pending \u{00B7} \(running.count) running \u{00B7} \(done.count) done")
                            .font(.subheadline)
                            .foregroundStyle(Color.appTextSecondary)
                    }
                    Spacer()
                    if !done.isEmpty || !failed.isEmpty {
                        Button("Clear Finished") {
                            Task { await qm.clearCompleted() }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 28)
                .padding(.bottom, 20)

                // MARK: - Running
                if !running.isEmpty {
                    sectionHeader("Running")
                    ForEach(running) { task in
                        TaskRow(task: task, meetingTitle: meetingTitle(for: task.meetingId))
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
                }

                // MARK: - Pending
                if !pending.isEmpty {
                    sectionHeader("Pending")
                    ForEach(pending) { task in
                        TaskRow(task: task, meetingTitle: meetingTitle(for: task.meetingId))
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
                }

                // MARK: - Failed
                if !failed.isEmpty {
                    sectionHeader("Failed")
                    ForEach(failed) { task in
                        TaskRow(
                            task: task,
                            meetingTitle: meetingTitle(for: task.meetingId),
                            onRetry: { Task { await qm.retry(taskId: task.id) } },
                            onClear: { Task { await qm.cancel(taskId: task.id) } }
                        )
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
                }

                // MARK: - Completed
                if !done.isEmpty {
                    sectionHeader("Completed")
                    ForEach(done.prefix(20)) { task in
                        TaskRow(task: task, meetingTitle: meetingTitle(for: task.meetingId))
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
                }

                // MARK: - Empty State
                if qm.allTasks.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.circle")
                            .font(.largeTitle)
                            .foregroundStyle(Color.appTextTertiary)
                        Text("No tasks in the queue")
                            .font(.headline)
                            .foregroundStyle(Color.appTextSecondary)
                        Text("Transcription and summary tasks appear here automatically after meetings end.")
                            .font(.subheadline)
                            .foregroundStyle(Color.appTextTertiary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                }

                Spacer(minLength: 32)
            }
        }
        .background(Color.appBackground)
        .task {
            await appState.taskQueueManager.refreshTaskList()
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Color.appTextTertiary)
            .textCase(.uppercase)
            .tracking(0.8)
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
    }

    private func meetingTitle(for meetingId: String) -> String {
        let all = appState.upcomingMeetings + appState.pastMeetings
        return all.first(where: { $0.id == meetingId })?.title ?? "Unknown Meeting"
    }
}

// MARK: - Task Row

private struct TaskRow: View {
    let task: TaskQueueItem
    let meetingTitle: String
    var onRetry: (() -> Void)? = nil
    var onClear: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            // Status icon
            statusIcon
                .frame(width: 28, height: 28)

            // Info
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(task.displayName)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.appTextPrimary)
                    Text("\u{00B7}")
                        .foregroundStyle(Color.appTextTertiary)
                    Text(meetingTitle)
                        .font(.subheadline)
                        .foregroundStyle(Color.appTextSecondary)
                        .lineLimit(1)
                }

                HStack(spacing: 8) {
                    if task.status == .running {
                        ProgressView()
                            .controlSize(.mini)
                        Text("Processing...")
                            .font(.caption)
                            .foregroundStyle(Color.appTextTertiary)
                    } else if task.status == .failed, let error = task.error {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    } else if task.status == .completed, let completed = task.completedAt {
                        Text("Completed \(completed, style: .relative) ago")
                            .font(.caption)
                            .foregroundStyle(Color.appTextTertiary)
                    } else if task.status == .pending {
                        Text("Priority \(task.priority) \u{00B7} Attempt \(task.retryCount + 1)/\(task.maxRetries)")
                            .font(.caption)
                            .foregroundStyle(Color.appTextTertiary)
                    }
                }
            }

            Spacer()

            // Actions
            if task.status == .failed {
                VStack(spacing: 4) {
                    if let onRetry {
                        Button("Retry") { onRetry() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.mini)
                    }
                    if let onClear {
                        Button("Clear") { onClear() }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch task.status {
        case .running:
            Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                .font(.body)
                .foregroundStyle(Color.appAccent)
        case .pending:
            Image(systemName: "clock")
                .font(.body)
                .foregroundStyle(Color.appTextTertiary)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.body)
                .foregroundStyle(.red)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.body)
                .foregroundStyle(Color.appSuccess)
        }
    }
}

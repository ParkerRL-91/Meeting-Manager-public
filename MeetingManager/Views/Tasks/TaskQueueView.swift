import SwiftUI

/// Full-page activity view — failed jobs are collapsible-by-default; completed jobs are a flat list.
struct TaskQueueView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let qm = appState.taskQueueManager
        let running = qm.allTasks.filter { $0.status == .running }
        let pending  = qm.allTasks.filter { $0.status == .pending }
        let failed   = qm.allTasks.filter { $0.status == .failed }
        let done     = qm.allTasks.filter { $0.status == .completed }

        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                // MARK: Header
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Activity")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(Color.appTextPrimary)

                        HStack(spacing: 4) {
                            activityCount(value: pending.count, label: "pending")
                            Text("·").foregroundStyle(Color.appTextMuted)
                            activityCount(value: running.count, label: "running")
                            Text("·").foregroundStyle(Color.appTextMuted)
                            activityCount(value: done.count, label: "done", highlight: false)
                            if !failed.isEmpty {
                                Text("·").foregroundStyle(Color.appTextMuted)
                                Text("\(failed.count) failed")
                                    .foregroundStyle(Color.appRecording)
                            }
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(Color.appTextTertiary)
                    }

                    Spacer()

                    if !done.isEmpty || !failed.isEmpty {
                        Button("Clear finished") {
                            Task { await qm.clearCompleted() }
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.appTextSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Color.appSurfaceSecondary)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color.appBorderStrong, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 28)
                .padding(.bottom, 20)

                // MARK: Running / Pending
                if !running.isEmpty || !pending.isEmpty {
                    activitySectionLabel("In Progress", color: Color.appAccentLight)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 8)

                    VStack(spacing: 4) {
                        ForEach(running) { task in
                            CompletedTaskRow(
                                task: task,
                                meetingTitle: meetingTitle(for: task.meetingId),
                                liveProgress: qm.currentTask?.id == task.id ? qm.currentProgress : nil
                            )
                        }
                        ForEach(pending) { task in
                            CompletedTaskRow(
                                task: task,
                                meetingTitle: meetingTitle(for: task.meetingId),
                                liveProgress: nil
                            )
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 20)
                }

                // MARK: Failed (collapsible)
                if !failed.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.appRecording)
                        Text("Failed · \(failed.count)")
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundStyle(Color.appRecording)
                            .textCase(.uppercase)
                            .tracking(0.6)
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)

                    VStack(spacing: 6) {
                        ForEach(failed) { task in
                            FailedTaskRow(
                                task: task,
                                meetingTitle: meetingTitle(for: task.meetingId),
                                onRetry: { Task { await qm.retry(taskId: task.id) } },
                                onClear: { Task { await qm.cancel(taskId: task.id) } }
                            )
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 20)
                }

                // MARK: Completed
                if !done.isEmpty {
                    activitySectionLabel("Completed · \(done.count)", color: Color.appTextMuted)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 8)

                    VStack(spacing: 4) {
                        ForEach(done.prefix(20)) { task in
                            CompletedTaskRow(
                                task: task,
                                meetingTitle: meetingTitle(for: task.meetingId),
                                liveProgress: nil
                            )
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
                }

                // MARK: Empty
                if qm.allTasks.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.circle")
                            .font(.largeTitle)
                            .foregroundStyle(Color.appTextMuted)
                        Text("No activity yet")
                            .font(.headline)
                            .foregroundStyle(Color.appTextTertiary)
                        Text("Transcription and summary tasks appear here automatically after meetings end.")
                            .font(.subheadline)
                            .foregroundStyle(Color.appTextMuted)
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

    private func activityCount(value: Int, label: String, highlight: Bool = false) -> some View {
        Text("\(value) \(label)")
            .foregroundStyle(highlight && value > 0 ? Color.appAccentLight : Color.appTextTertiary)
    }

    private func activitySectionLabel(_ text: String, color: Color) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .bold))
            .foregroundStyle(color)
            .tracking(0.6)
    }

    private func meetingTitle(for meetingId: String) -> String {
        let all = appState.upcomingMeetings + appState.pastMeetings
        return all.first(where: { $0.id == meetingId })?.title ?? "Unknown Meeting"
    }
}

// MARK: - Failed Task Row (collapsible)

private struct FailedTaskRow: View {
    let task: TaskQueueItem
    let meetingTitle: String
    let onRetry: () -> Void
    let onClear: () -> Void

    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            // Header row
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.appRecordingSubtle)
                        .frame(width: 16, height: 16)
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(Color.appRecording)
                }

                Text(task.displayName)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.appTextPrimary)

                Text("·")
                    .foregroundStyle(Color.appTextMuted)

                Text(meetingTitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.appTextTertiary)
                    .lineLimit(1)

                Spacer()

                Button("Details") {
                    withAnimation(.easeInOut(duration: 0.16)) { isExpanded.toggle() }
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.appTextTertiary)
                .buttonStyle(.plain)

                Button("Retry") { onRetry() }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.appTextSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.appSurfaceSecondary)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .buttonStyle(.plain)

                Button("Clear") { onClear() }
                    .font(.system(size: 11))
                    .foregroundStyle(Color.appTextMuted)
                    .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.16)) { isExpanded.toggle() }
            }

            // Expanded error
            if isExpanded, let error = task.error {
                Rectangle()
                    .fill(Color.appSeparator)
                    .frame(height: 1)

                Text(error)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.appRecording)
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 40)
                    .padding(.trailing, 14)
                    .padding(.vertical, 10)
                    .background(Color.appRecording.opacity(0.04))
            }
        }
        .background(Color.appSurface)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.appRecordingSubtle, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Completed / Running / Pending Task Row

private struct CompletedTaskRow: View {
    let task: TaskQueueItem
    let meetingTitle: String
    /// Live stage + (optional) fraction reported by the currently-running
    /// handler. nil when this row isn't the active task or no progress has
    /// been reported yet.
    let liveProgress: TaskQueueManager.TaskProgress?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                statusIcon

                Text(task.displayName)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.appTextPrimary)

                Text("·")
                    .foregroundStyle(Color.appTextMuted)

                Text(meetingTitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.appTextTertiary)
                    .lineLimit(1)

                Spacer()

                if task.status == .running {
                    ProgressView().controlSize(.mini)
                } else if task.status == .pending {
                    Text("Priority \(task.priority)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.appTextMuted)
                } else if let completed = task.completedAt {
                    RelativeTimestampLabel(date: completed)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.appTextMuted)
                }
            }

            // Live stage + progress strip — only visible while running and
            // when the handler has actually reported a stage. Stage text is
            // honest; the fraction bar appears only when the handler chose
            // to surface a real measurable fraction.
            if task.status == .running, let progress = liveProgress {
                HStack(spacing: 8) {
                    Text(progress.stage)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.appTextSecondary)
                    if let fraction = progress.fraction {
                        ProgressView(value: fraction)
                            .progressViewStyle(.linear)
                            .controlSize(.mini)
                            .frame(maxWidth: 120)
                        Text("\(Int(fraction * 100))%")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color.appTextMuted)
                    }
                    Spacer()
                }
                .padding(.leading, 28)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.appSurface)
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Color.appSeparator, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    @ViewBuilder
    private var statusIcon: some View {
        ZStack {
            Circle()
                .fill(iconBg)
                .frame(width: 16, height: 16)
            Image(systemName: iconName)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(iconColor)
        }
    }

    private var iconName: String {
        switch task.status {
        case .running:   return "arrow.trianglehead.2.clockwise.rotate.90"
        case .pending:   return "clock"
        case .completed: return "checkmark"
        default:         return "circle"
        }
    }

    private var iconColor: Color {
        switch task.status {
        case .running:   return Color.appAccentLight
        case .pending:   return Color.appTextMuted
        case .completed: return Color.appSuccess
        default:         return Color.appTextMuted
        }
    }

    private var iconBg: Color {
        switch task.status {
        case .running:   return Color.appAccentSubtle
        case .pending:   return Color.appSurfaceSecondary
        case .completed: return Color.appSuccessSubtle
        default:         return Color.appSurfaceSecondary
        }
    }
}

import SwiftUI

/// Compact single-row header: title · date/time/duration · status pill · action buttons
/// Matches Design B spec: 10px vertical, 16px horizontal, bottom border.
struct MeetingMetadataHeader: View {
    let meeting: Meeting
    var onEdit: (() -> Void)?
    @Environment(AppState.self) private var appState

    @State private var isEditingTitle = false
    @State private var titleDraft: String = ""
    @State private var titleSaveTask: Task<Void, Never>?
    @State private var showTitleSavedFlash = false
    @FocusState private var titleFieldFocused: Bool

    /// True when the meeting has at least one captured audio file —
    /// indicates an earlier recording was started and stopped.
    private var hasExistingRecording: Bool {
        guard let path = meeting.audioFilePath, !path.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    /// True when the user is opening this meeting BEFORE its scheduled start.
    /// Before-start = "Start Early"; at-or-after = "Start" (or "Continue
    /// Recording" if there's already an audio file).
    private var isBeforeScheduledStart: Bool {
        guard let start = meeting.scheduledStartDate else { return false }
        return Date() < start
    }

    private var startButtonLabel: String {
        if hasExistingRecording { return "Continue Recording" }
        return isBeforeScheduledStart ? "Start Early" : "Start"
    }

    private var startButtonIcon: String {
        hasExistingRecording ? "record.circle.fill" : "play.fill"
    }

    private var startButtonHelp: String {
        if hasExistingRecording {
            return "Resume recording this meeting — appends to the existing audio file"
        }
        return isBeforeScheduledStart
            ? "Start recording before the scheduled time"
            : "Start recording this meeting now"
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {

            // Title (inline-editable)
            if isEditingTitle {
                TextField("Meeting title", text: $titleDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.appTextPrimary)
                    .focused($titleFieldFocused)
                    .onSubmit { commitTitle() }
                    .onChange(of: titleDraft) { _, _ in scheduleTitleSave() }
                    .onChange(of: titleFieldFocused) { _, focused in
                        if !focused { commitTitle() }
                    }
            } else {
                Text(meeting.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.appTextPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .onTapGesture(count: 2) { beginEditingTitle() }
                    .help("Double-click to rename")
            }

            // Inline meta: · Today 12:59 · 58 min
            HStack(spacing: 4) {
                Text("·")
                Text(DateFormatting.relativeDate(from: meeting.effectiveDate))
                Text(DateFormatting.timeOnly(from: meeting.effectiveDate))
                if meeting.duration != nil {
                    Text("·")
                    Text(meeting.formattedDuration)
                }
            }
            .font(.system(size: 11.5))
            .foregroundStyle(Color.appTextMuted)
            .layoutPriority(-1)

            // Status pill
            CompactStatusPill(status: meeting.status)

            Spacer(minLength: 4)

            // Start / Start Early / Continue Recording
            if meeting.status == .scheduled || meeting.status == .notified {
                Button {
                    appState.startRecording(for: meeting)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: startButtonIcon)
                            .font(.system(size: 10))
                        Text(startButtonLabel)
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.appAccent)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(startButtonHelp)
            }

            // Saved flash
            if showTitleSavedFlash {
                Label("Saved", systemImage: "checkmark")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.appSuccess)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.appBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.appSeparator)
                .frame(height: 1)
        }
        .onDisappear {
            titleSaveTask?.cancel()
            if isEditingTitle { commitTitle() }
        }
    }

    // MARK: - Title editing

    private func beginEditingTitle() {
        titleDraft = meeting.title
        isEditingTitle = true
        DispatchQueue.main.async { titleFieldFocused = true }
    }

    private func scheduleTitleSave() {
        titleSaveTask?.cancel()
        titleSaveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await persistTitle()
        }
    }

    private func commitTitle() {
        titleSaveTask?.cancel()
        Task { await persistTitle(forceCommit: true) }
    }

    @MainActor
    private func persistTitle(forceCommit: Bool = false) async {
        let trimmed = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            if forceCommit {
                titleDraft = meeting.title
                isEditingTitle = false
            }
            return
        }
        guard trimmed != meeting.title else {
            if forceCommit { isEditingTitle = false }
            return
        }
        var updated = meeting
        updated.title = trimmed
        do {
            try await appState.meetingRepository.update(updated)
            appState.loadMeetings()
            withAnimation(.easeInOut(duration: 0.2)) { showTitleSavedFlash = true }
            if forceCommit { isEditingTitle = false }
            try? await Task.sleep(for: .milliseconds(800))
            withAnimation(.easeInOut(duration: 0.3)) { showTitleSavedFlash = false }
        } catch {}
    }
}

// MARK: - Compact Status Pill

private struct CompactStatusPill: View {
    let status: MeetingStatus

    var body: some View {
        HStack(spacing: 5) {
            if status == .complete || status == .transcribing {
                Circle()
                    .fill(dotColor)
                    .frame(width: 6, height: 6)
            }
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(textColor)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(bgColor)
        .clipShape(Capsule())
    }

    private var label: String {
        switch status {
        case .complete:     return "Complete"
        case .recording:    return "Recording"
        case .transcribing: return "Transcribing"
        case .summarizing:  return "Summarizing"
        case .scheduled:    return "Scheduled"
        case .notified:     return "Up next"
        case .cancelled:    return "Cancelled"
        case .archived:     return "Archived"
        default:            return status.rawValue.capitalized
        }
    }

    private var dotColor: Color {
        switch status {
        case .complete: return Color.appSuccess
        default:        return Color.appAccent
        }
    }

    private var textColor: Color {
        switch status {
        case .complete:     return Color.appSuccess
        case .recording:    return Color.appRecording
        case .transcribing, .summarizing: return Color.appAccentLight
        case .scheduled, .notified: return Color.appAccentLight
        default:            return Color.appTextMuted
        }
    }

    private var bgColor: Color {
        switch status {
        case .complete:     return Color.appSuccessSubtle
        case .recording:    return Color.appRecordingSubtle
        case .transcribing, .summarizing: return Color.appAccentSubtle
        case .scheduled, .notified: return Color.appAccentSubtle
        default:            return Color.appSurfaceSecondary
        }
    }
}

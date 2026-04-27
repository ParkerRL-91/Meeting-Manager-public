import SwiftUI

struct MeetingMetadataHeader: View {
    let meeting: Meeting
    var onEdit: (() -> Void)?
    @Environment(AppState.self) private var appState

    // Click-to-edit title state (exec ask). Mirrors NotepadPaneView's debounce
    // pattern: 1s debounce while editing, immediate flush on commit/blur.
    @State private var isEditingTitle = false
    @State private var titleDraft: String = ""
    @State private var titleSaveTask: Task<Void, Never>?
    @State private var showTitleSavedFlash = false
    @FocusState private var titleFieldFocused: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if isEditingTitle {
                        TextField("Meeting title", text: $titleDraft)
                            .textFieldStyle(.plain)
                            .font(.title2)
                            .fontWeight(.semibold)
                            .foregroundStyle(Color.appTextPrimary)
                            .focused($titleFieldFocused)
                            .onSubmit { commitTitle() }
                            .onChange(of: titleDraft) { _, _ in scheduleTitleSave() }
                            .onChange(of: titleFieldFocused) { _, focused in
                                if !focused { commitTitle() }
                            }
                    } else {
                        Text(meeting.title)
                            .font(.title2)
                            .fontWeight(.semibold)
                            .foregroundStyle(Color.appTextPrimary)
                            .lineLimit(2)
                            .onTapGesture(count: 2) { beginEditingTitle() }
                            .help("Double-click to rename")
                    }

                    if !isEditingTitle {
                        Button {
                            beginEditingTitle()
                        } label: {
                            Image(systemName: "pencil")
                                .font(.caption)
                                .foregroundStyle(Color.appTextSecondary)
                        }
                        .buttonStyle(.plain)
                        .help("Rename meeting")
                    }

                    if showTitleSavedFlash {
                        Label("Saved", systemImage: "checkmark")
                            .labelStyle(.titleAndIcon)
                            .font(.caption)
                            .foregroundStyle(Color.appSuccess)
                            .transition(.opacity)
                    }

                    if !isEditingTitle, let onEdit {
                        Button {
                            onEdit()
                        } label: {
                            Image(systemName: "calendar.badge.clock")
                                .font(.caption)
                                .foregroundStyle(Color.appTextSecondary)
                        }
                        .buttonStyle(.plain)
                        .help("Edit meeting time and details")
                    }
                }

                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                        .imageScale(.small)
                    Text(DateFormatting.relativeDate(from: meeting.effectiveDate))

                    Text("at")
                        .foregroundStyle(Color.appTextTertiary)

                    Image(systemName: "clock")
                        .imageScale(.small)
                    Text(DateFormatting.timeOnly(from: meeting.effectiveDate))
                }
                .font(.subheadline)
                .foregroundStyle(Color.appTextSecondary)
            }

            Spacer()

            StatusBadge(status: meeting.status)

            // "Start Early" button — shown next to the Scheduled badge
            if meeting.status == .scheduled || meeting.status == .notified {
                Button {
                    appState.startRecording(for: meeting)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "play.fill")
                            .font(.caption2)
                        Text("Start Early")
                            .font(.caption)
                            .fontWeight(.semibold)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.appAccent)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Start recording this meeting now")
            }

            if meeting.duration != nil {
                Text(meeting.formattedDuration)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(Color.appTextSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.appSurfaceSecondary)
                    .clipShape(Capsule())
            }
        }
        .padding(16)
        .background(Color.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .onDisappear {
            titleSaveTask?.cancel()
            // Best-effort flush on disappear.
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
        // Reject empty rename — keep the field open with the original value.
        guard !trimmed.isEmpty else {
            if forceCommit {
                titleDraft = meeting.title
                isEditingTitle = false
            }
            return
        }

        // No-op if unchanged.
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
        } catch {
            // On failure, surface via the broader meeting view's error path
            // by leaving the draft visible; the parent will reload meeting data
            // on next refresh.
        }
    }
}

// MARK: - Previews

// #Preview("Completed Meeting") {
//     MeetingMetadataHeader(meeting: Meeting(
//         title: "Weekly Design Sync",
//         startDate: Date().addingTimeInterval(-7200),
//         endDate: Date().addingTimeInterval(-3600),
//         scheduledStartDate: Date().addingTimeInterval(-7200),
//         status: .complete
//     ))
//     .padding()
//     .background(Color.appBackground)
// }

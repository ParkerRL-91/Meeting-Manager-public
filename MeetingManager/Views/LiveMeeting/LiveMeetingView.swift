import AppKit
import GRDB
import SwiftUI
import os

/// Live meeting view: notes + Ask Anything chat side-by-side.
/// Layout: Recording bar (with participants + stop) → Notes left + Ask Anything right.
/// We don't live-transcribe in this view — the transcript is generated post-recording.
struct LiveMeetingView: View {
    let meetingId: String
    @Environment(AppState.self) private var appState
    @State private var meeting: Meeting?
    /// Ask Anything chat is shown by default during a meeting — that's the
    /// primary "in the moment" tool. User can collapse with Cmd+J if they
    /// want a wider notes area, but the default is open.
    @State private var showChat = true
    @State private var showAttendeePopover = false

    @State private var showContextBrief = true
    @State private var carriedItems: [ActionItem] = []
    @State private var showOpenItems = true
    @State private var notepadInitialText: String = ""
    @State private var capturedItemCount = 0
    @State private var showQuickCapture = false

    // Notepad height is now a flex layout — it claims all remaining vertical
    // space below the top sections and above the transcript pane. Removed
    // the previous `liveMeeting.notepadHeight` @AppStorage since the notepad
    // no longer has a user-draggable height (it auto-sizes with the window).
    // Transcript pane keeps its own height storage inside `LiveTranscriptPane`.
    @State private var editableTitle: String = ""
    @FocusState private var isTitleFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // MARK: - Top recording strip (minimal)
            RecordingStrip(meetingId: meetingId)

            // MARK: - Main content (scrollable)
            if showChat {
                // HSplitView is natively draggable on macOS — explicit min/ideal/max
                // ensures the divider has clear travel room. The chosen
                // ideal=340 matches a typical chat-pane width.
                HSplitView {
                    mainContent
                        .frame(minWidth: 400, idealWidth: 720)
                    MeetingChatView(meetingId: meetingId)
                        .frame(minWidth: 260, idealWidth: 340, maxWidth: 600)
                }
            } else {
                mainContent
            }

            // MARK: - Bottom bar: audio levels + stop + ask anything
            BottomBar(meetingId: meetingId, showChat: $showChat, capturedItemCount: capturedItemCount, showQuickCapture: $showQuickCapture)
        }
        .background(Color.appBackground)
        .frame(minWidth: showChat ? 800 : 540, minHeight: 500)
        .toggleOnKeyboardShortcut("j", modifiers: .command, binding: $showChat)
        .background(
            // T-026: Cmd+Shift+A shortcut to show quick capture popover
            Button("") {
                showQuickCapture.toggle()
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .hidden()
        )
        .popover(isPresented: $showQuickCapture, arrowEdge: .bottom) {
            QuickCapturePopoverView(meetingId: meetingId) {
                capturedItemCount += 1
                showQuickCapture = false
            } onCancel: {
                showQuickCapture = false
            }
        }
        .task {
            if let active = appState.activeMeeting {
                meeting = active
            } else {
                meeting = try? await appState.meetingRepository.find(id: meetingId)
            }
            editableTitle = meeting?.title ?? ""
            loadContext()
            await loadOpenItems()
            await loadCapturedItemCount()
            await focusTitleForRenameIfNeeded()
        }
        .onChange(of: appState.activeMeeting?.id) { _, _ in
            if let active = appState.activeMeeting {
                meeting = active
                editableTitle = active.title
            }
        }
        .onChange(of: appState.focusTitleForRename) { _, shouldFocus in
            if shouldFocus {
                Task { await focusTitleForRenameIfNeeded() }
            }
        }
        // Re-check context when enrichment completes in the background so the
        // brief appears mid-meeting if it wasn't ready at start time. We
        // re-fetch the meeting so its contextJSON updates and the
        // RelatedMeetingsSection re-renders with the freshly synthesized brief.
        .onChange(of: appState.taskQueueManager.allTasks) { _, tasks in
            let justFinished = tasks.contains {
                $0.type == .contextEnrichment && $0.meetingId == meetingId && $0.status == .completed
            }
            if justFinished {
                Task {
                    let updated = try? await appState.meetingRepository.find(id: meetingId)
                    if let updated {
                        meeting = updated
                        showContextBrief = true
                    }
                }
            }
        }
    }

    // MARK: - Main Content

    private var mainContent: some View {
        // Two-tier layout: top sections (title, badges, context brief, open
        // items) live inside an inner ScrollView with a capped height so
        // they compress when the window shrinks. The notepad sits below
        // with `maxHeight: .infinity` and `layoutPriority: 1`, claiming
        // every remaining pixel — when the window is short, you see fewer
        // notepad lines (with internal scroll inside the notepad), while
        // every other section stays visible.
        //
        // Previous design wrapped *everything* in one outer ScrollView,
        // which meant pre-meeting context and action items would scroll
        // off-screen as soon as the user typed past the visible notepad
        // area. The user reported this — the layout below is the fix.
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Big title (inline editable)
                    TextField("Meeting title", text: $editableTitle)
                        .font(.title.weight(.bold))
                        .foregroundStyle(Color.appTextPrimary)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 28)
                        .padding(.top, 20)
                        .padding(.bottom, 10)
                        .onSubmit { saveTitleIfChanged() }
                        .focused($isTitleFocused)
                        .onChange(of: isTitleFocused) { _, focused in if !focused { saveTitleIfChanged() } }

                    // Pill badges row
                    HStack(spacing: 8) {
                        PillBadge(icon: "calendar", label: "Today")

                        if let meeting, !meeting.participantList.isEmpty {
                            Button {
                                showAttendeePopover.toggle()
                            } label: {
                                PillBadge(icon: "person.2", label: "\(meeting.participantList.count) attendees")
                            }
                            .buttonStyle(.plain)
                            .popover(isPresented: $showAttendeePopover, arrowEdge: .bottom) {
                                AttendeePopover(participants: meeting.participantList)
                            }
                        }

                        Spacer()
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 16)

                    // Context brief — same RelatedMeetingsSection used on the
                    // post-meeting detail view, now rendered with the same
                    // .display heading style and 14pt base font as SummaryView
                    // so it reads as a proper "summary" (not a sidebar widget).
                    if let json = meeting?.contextJSON, !json.isEmpty, showContextBrief {
                        RelatedMeetingsSection(
                            contextJSON: json,
                            onSelectMeeting: { id in
                                appState.selectedMeetingId = id
                                appState.sidebarDestination = .meetings
                            }
                        )
                        .padding(.horizontal, 24)
                        .padding(.bottom, 12)
                    }

                    // Open Items panel (T-022)
                    if !carriedItems.isEmpty {
                        OpenItemsPanel(
                            items: $carriedItems,
                            isExpanded: $showOpenItems
                        )
                        .padding(.horizontal, 24)
                        .padding(.bottom, 12)
                    }
                }
            }
            // Cap the top section's height so a long context brief or many
            // open items can't push the notepad off-screen. Inner ScrollView
            // handles overflow.
            .frame(maxHeight: 360)

            // Notes area — flexible. Takes all remaining vertical space.
            // `layoutPriority(1)` ensures the notepad wins over the top
            // section when the layout system has to choose who shrinks.
            // Internal scroll is provided by NotepadPaneView itself, so
            // typing past the visible area scrolls within the notepad.
            NotepadPaneView(meetingId: meetingId, initialText: notepadInitialText) {
                capturedItemCount += 1
            }
            .frame(minHeight: 180, maxHeight: .infinity)
            .layoutPriority(1)

            // Live transcript pane removed — we don't actually live-transcribe
            // during the recording (transcription runs post-stop via the
            // batch pipeline). Showing an empty / lagging transcript pane
            // was misleading. Real transcript view lives on the post-meeting
            // detail page under the Transcript tab.
        }
    }

    // MARK: - Context Loading

    /// If the meeting was started ad-hoc (no pre-meeting enrichment ran)
    /// we kick enrichment now so the brief still appears mid-meeting once
    /// the LLM finishes synthesizing. The .onChange task-queue watcher
    /// re-fetches the meeting when enrichment completes.
    private func loadContext() {
        guard let meeting else { return }
        if (meeting.contextJSON ?? "").isEmpty && !meeting.participantList.isEmpty {
            Task {
                let service = RelevantMeetingService(database: AppDatabase.shared)
                try? await service.enrichContext(meetingId: meetingId)
                let updated = try? await appState.meetingRepository.find(id: meetingId)
                if let updated { self.meeting = updated }
            }
        }
    }

    private func saveTitleIfChanged() {
        let trimmed = editableTitle.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            editableTitle = meeting?.title ?? ""
            return
        }
        guard trimmed != meeting?.title, var updated = meeting else { return }
        updated.title = trimmed
        meeting = updated
        Task {
            try? await appState.meetingRepository.update(updated)
        }
    }

    /// When AppState signals that a newly-created ad-hoc meeting needs its title renamed,
    /// focus the title TextField and select all of its text so the user can type straight
    /// over "New Meeting" without having to click or drag-select first.
    @MainActor
    private func focusTitleForRenameIfNeeded() async {
        guard appState.focusTitleForRename else { return }
        // Wait for the TextField to be mounted and hosted by AppKit before selecting.
        try? await Task.sleep(nanoseconds: 150_000_000)
        isTitleFocused = true
        // SwiftUI focus doesn't select the contents of a macOS TextField by default;
        // fire selectAll on the newly-focused first responder so typing replaces the
        // default placeholder text.
        try? await Task.sleep(nanoseconds: 30_000_000)
        NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
        appState.focusTitleForRename = false
    }

    // MARK: - Open Items Loading (T-021 / T-022)

    private func loadOpenItems() async {
        guard let meeting else { return }
        let participants = meeting.participantList
        guard !participants.isEmpty else { return }

        do {
            let items = try await ActionItemRepository().openItemsForParticipants(participants)
            await MainActor.run {
                carriedItems = items
                showOpenItems = !items.isEmpty
                if !items.isEmpty {
                    notepadInitialText = buildNotepadPrelude(from: items)
                }
            }
        } catch {
            Logger.database.error("Failed to load open items for carry-forward: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func loadCapturedItemCount() async {
        let items = (try? await ActionItemRepository().itemsForMeeting(meetingId)) ?? []
        await MainActor.run {
            capturedItemCount = items.count
        }
    }

    /// Builds the pre-population text for the notepad from carried-forward action items.
    private func buildNotepadPrelude(from items: [ActionItem]) -> String {
        var lines = ["Follow-ups from previous meetings:"]
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        for item in items {
            var line = "- [ ] "
            if let assignee = item.assignee, !assignee.isEmpty {
                line += "\(assignee): "
            }
            line += item.title
            if let due = item.dueDate {
                line += " (due \(formatter.string(from: due)))"
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Open Items Panel (T-022)

private struct OpenItemsPanel: View {
    @Binding var items: [ActionItem]
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.footnote)
                        .foregroundStyle(Color.appWarning)
                    Text("Open Items (\(items.count))")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.appTextPrimary)
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.appTextSecondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()
                    .padding(.horizontal, 0)

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        OpenItemRow(item: item) { updatedItem in
                            items[index] = updatedItem
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .background(Color.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.appWarning.opacity(0.3), lineWidth: 1)
        )
    }
}

private struct OpenItemRow: View {
    let item: ActionItem
    var onToggle: (ActionItem) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button {
                guard let id = item.id else { return }
                Task {
                    try? await ActionItemRepository().toggleComplete(id: id)
                    var updated = item
                    updated.isCompleted.toggle()
                    onToggle(updated)
                }
            } label: {
                Image(systemName: item.isCompleted ? "checkmark.square.fill" : "square")
                    .font(.callout)
                    .foregroundStyle(item.isCompleted ? Color.appAccent : Color.appTextSecondary)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if let assignee = item.assignee, !assignee.isEmpty {
                        Text("\(assignee):")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Color.appTextPrimary)
                    }
                    Text(item.title)
                        .font(.subheadline)
                        .foregroundStyle(item.isCompleted ? Color.appTextSecondary : Color.appTextPrimary)
                        .strikethrough(item.isCompleted)
                }

                if let due = item.dueDate {
                    Text("Due \(due.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption)
                        .foregroundStyle(Color.appWarning)
                }
            }

            Spacer()
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Recording Strip (minimal top bar)

private struct RecordingStrip: View {
    let meetingId: String
    @Environment(AppState.self) private var appState
    @State private var elapsedSeconds: Int = 0
    @State private var pulse = false
    @State private var meeting: Meeting?

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color.appRecording)
                .frame(width: 8, height: 8)
                .opacity(pulse ? 0.3 : 1.0)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
                .onAppear { pulse = true }

            Text("Recording")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.appRecording)

            Text(formatted)
                .font(.subheadline.monospaced())
                .foregroundStyle(Color.appTextSecondary)

            // Inline participant chips — small initial avatars + first names.
            // First three then "+N" overflow so the strip doesn't blow up
            // for big meetings.
            if let participants = meeting?.participantList, !participants.isEmpty {
                Divider()
                    .frame(height: 14)
                    .padding(.horizontal, 4)
                participantChips(participants)
            }

            Spacer()

            // The single in-window Stop button. The previous duplicate in
            // the BottomBar was removed — one stop is enough; the menu bar
            // dropdown has its own as well.
            Button {
                appState.stopRecording()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 9, weight: .bold))
                    Text("Stop")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.appRecording)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Stop Recording (⌘R)")
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 8)
        .background(Color.appSurface.opacity(0.5))
        .onAppear {
            startTimer()
            loadMeeting()
        }
        .onChange(of: appState.activeMeeting?.id) { _, _ in loadMeeting() }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }

    /// Compact chips: initial avatar circle + first name. Overflow rolls
    /// up to a "+N" pill so a 12-person meeting doesn't squeeze the title
    /// row off-screen.
    @ViewBuilder
    private func participantChips(_ participants: [String]) -> some View {
        let visibleCap = 3
        HStack(spacing: 6) {
            ForEach(participants.prefix(visibleCap), id: \.self) { name in
                HStack(spacing: 4) {
                    InitialsAvatar(name: name, size: 18)
                    Text(firstName(of: name))
                        .font(.caption)
                        .foregroundStyle(Color.appTextSecondary)
                        .lineLimit(1)
                }
                .padding(.trailing, 4)
            }
            if participants.count > visibleCap {
                Text("+\(participants.count - visibleCap)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.appTextTertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.appSurface)
                    .clipShape(Capsule())
            }
        }
    }

    private func firstName(of name: String) -> String {
        // Email: take the local part before "@" and split on common
        // separators. Display name: take the first whitespace-separated token.
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if let atIndex = trimmed.firstIndex(of: "@") {
            let local = String(trimmed[..<atIndex])
            let parts = local.components(separatedBy: CharacterSet(charactersIn: ".-_"))
            return parts.first?.capitalized ?? local
        }
        return trimmed.components(separatedBy: .whitespaces).first ?? trimmed
    }

    private func loadMeeting() {
        Task {
            let m = try? await appState.meetingRepository.find(id: meetingId)
            await MainActor.run { self.meeting = m }
        }
    }

    private var formatted: String {
        let h = elapsedSeconds / 3600
        let m = (elapsedSeconds % 3600) / 60
        let s = elapsedSeconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    @State private var timer: Timer?

    private func startTimer() {
        updateElapsed()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in updateElapsed() }
        }
    }

    private func updateElapsed() {
        guard let start = appState.activeMeeting?.startDate else { elapsedSeconds = 0; return }
        elapsedSeconds = max(0, Int(Date().timeIntervalSince(start)))
    }
}

// MARK: - Pill Badge

private struct PillBadge: View {
    let icon: String
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.caption)
            Text(label)
                .font(.footnote.weight(.medium))
        }
        .foregroundStyle(Color.appTextSecondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.appSurface)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.appSeparator, lineWidth: 0.5))
    }
}

// MARK: - Attendee Popover

private struct AttendeePopover: View {
    let participants: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Attendees")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.appTextSecondary)
                .padding(.bottom, 4)

            ForEach(participants, id: \.self) { name in
                HStack(spacing: 8) {
                    InitialsAvatar(name: name, size: 26)
                    Text(name)
                        .font(.subheadline)
                        .foregroundStyle(Color.appTextPrimary)
                }
                .padding(.vertical, 2)
            }
        }
        .padding(14)
        .frame(minWidth: 200)
    }
}

// MARK: - Bottom Bar

private struct BottomBar: View {
    let meetingId: String
    @Binding var showChat: Bool
    let capturedItemCount: Int
    @Binding var showQuickCapture: Bool
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 12) {
            // Audio level indicators
            AudioLevelIndicator(label: "🎤", level: appState.micLevel)
                .accessibilityLabel("Microphone level")
            AudioLevelIndicator(label: "🔊", level: appState.systemLevel, color: .appSuccess)
                .accessibilityLabel("Speaker level")

            // Stop button removed from the BottomBar — the canonical
            // in-window Stop lives in the RecordingStrip at the top, and
            // the menu bar dropdown has its own. One Stop in each surface
            // is enough; two in the same window was visual noise.
            // ⌘R is still registered at the app level (Toggle Recording menu).

            // T-025: Captured action items badge (visible when count > 0)
            if capturedItemCount > 0 {
                Button {
                    showQuickCapture.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "bolt.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.appAccent)
                        Text("\(capturedItemCount) item\(capturedItemCount == 1 ? "" : "s")")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(Color.appAccent)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.appAccent.opacity(0.12))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Captured action items — click to add more (Cmd+Shift+A)")
                .transition(.scale.combined(with: .opacity))
                .animation(.spring(response: 0.3), value: capturedItemCount)
            }

            // Ask anything bar
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showChat.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.caption)
                        .foregroundStyle(Color.appAccent)
                    Text("Ask anything")
                        .font(.subheadline)
                        .foregroundStyle(Color.appTextTertiary)
                    Spacer()
                    Text("Cmd+J")
                        .font(.caption2)
                        .foregroundStyle(Color.appTextTertiary.opacity(0.5))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.appSurface)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color.appSurface.opacity(0.3))
    }
}

// MARK: - Live Transcript Pane (P2-T02)

// LiveTranscriptPane was removed in favour of a chat-and-notes-only live
// view. Transcription happens post-stop via the batch pipeline; the
// transcript itself is reviewed on the meeting detail page under the
// Transcript tab. Showing a "live transcript" widget that wasn't actually
// live (segments only appeared after stop) was misleading.

// MARK: - Keyboard Shortcut Helper

private extension View {
    func toggleOnKeyboardShortcut(
        _ key: KeyEquivalent,
        modifiers: EventModifiers,
        binding: Binding<Bool>
    ) -> some View {
        self.background(
            Button("") {
                withAnimation(.easeInOut(duration: 0.2)) {
                    binding.wrappedValue.toggle()
                }
            }
            .keyboardShortcut(key, modifiers: modifiers)
            .hidden()
        )
    }
}

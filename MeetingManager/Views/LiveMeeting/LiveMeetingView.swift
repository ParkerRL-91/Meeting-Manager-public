import AppKit
import GRDB
import SwiftUI
import os

/// Live meeting view: notes-first, transcript secondary.
/// Layout: Recording bar at top → Big title + pill badges → Notes area → Context brief → Bottom chat/stop bar.
struct LiveMeetingView: View {
    let meetingId: String
    @Environment(AppState.self) private var appState
    @State private var meeting: Meeting?
    @State private var showChat = false
    @State private var showAttendeePopover = false

    @State private var contextMeetings: [RelevantMeeting] = []
    @State private var showContextBrief = true
    @State private var carriedItems: [ActionItem] = []
    @State private var showOpenItems = true
    @State private var notepadInitialText: String = ""
    @State private var capturedItemCount = 0
    @State private var showQuickCapture = false
    @State private var editableTitle: String = ""
    @FocusState private var isTitleFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // MARK: - Top recording strip (minimal)
            RecordingStrip(meetingId: meetingId)

            // MARK: - Main content (scrollable)
            if showChat {
                HSplitView {
                    mainContent
                        .frame(minWidth: 400)
                    MeetingChatView(meetingId: meetingId)
                        .frame(minWidth: 280, idealWidth: 340)
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
    }

    // MARK: - Main Content

    private var mainContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Big title (inline editable)
                TextField("Meeting title", text: $editableTitle)
                    .font(.title.weight(.bold))
                    .foregroundStyle(Color.appTextPrimary)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 28)
                    .padding(.top, 24)
                    .padding(.bottom, 10)
                    .onSubmit { saveTitleIfChanged() }
                    .focused($isTitleFocused)
                    .onChange(of: isTitleFocused) { _, focused in if !focused { saveTitleIfChanged() } }

                // Pill badges row
                HStack(spacing: 8) {
                    // Today badge
                    PillBadge(icon: "calendar", label: "Today")

                    // Attendees badge
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
                .padding(.bottom, 20)

                // Open Items panel (T-022)
                if !carriedItems.isEmpty {
                    OpenItemsPanel(
                        items: $carriedItems,
                        isExpanded: $showOpenItems
                    )
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
                }

                // Notes area (T-021: initialText pre-populates when notepad is empty)
                NotepadPaneView(meetingId: meetingId, initialText: notepadInitialText) {
                    capturedItemCount += 1
                }
                .frame(minHeight: 250)

                // P2-T02: Collapsible live transcript pane (collapsed by default —
                // notes are primary, transcript is secondary).
                LiveTranscriptPane(meetingId: meetingId)
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
                    .padding(.bottom, 12)

                // Context brief (related past meetings)
                if !contextMeetings.isEmpty && showContextBrief {
                    ContextBriefView(
                        meetings: contextMeetings,
                        participantCompany: extractCompany(),
                        onDismiss: { showContextBrief = false },
                        onSelectMeeting: { id in
                            appState.selectedMeetingId = id
                            appState.sidebarDestination = .meetings
                        }
                    )
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
                }
            }
        }
    }

    // MARK: - Context Loading

    private func loadContext() {
        guard let meeting else { return }
        contextMeetings = RelevantMeetingService.parseContext(from: meeting.contextJSON)
        if contextMeetings.isEmpty && !meeting.participantList.isEmpty {
            Task {
                let service = RelevantMeetingService(database: AppDatabase.shared)
                try? await service.enrichContext(meetingId: meetingId)
                let updated = try? await appState.meetingRepository.find(id: meetingId)
                contextMeetings = RelevantMeetingService.parseContext(from: updated?.contextJSON)
            }
        }
    }

    private func extractCompany() -> String? {
        // Use participant names for the context header rather than title heuristics,
        // which produce nonsensical results like "You last met with with recently".
        guard let meeting else { return nil }
        let participants = meeting.participantList
        if participants.count == 1 { return participants.first }
        if participants.count > 1 { return "\(participants[0]) and others" }
        return nil
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

            Spacer()
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 8)
        .background(Color.appSurface.opacity(0.5))
        .onAppear { startTimer() }
        .onDisappear {
            timer?.invalidate()
            timer = nil
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

// MARK: - Context Brief (related past meetings)

private struct ContextBriefView: View {
    let meetings: [RelevantMeeting]
    let participantCompany: String?
    var onDismiss: () -> Void
    var onSelectMeeting: (String) -> Void
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack {
                Text(headerText)
                    .font(.subheadline)
                    .foregroundStyle(Color.appTextTertiary)
                Spacer()
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption)
                        .foregroundStyle(Color.appTextTertiary)
                }
                .buttonStyle(.plain)
            }

            // Meeting excerpts
            ForEach(Array(displayedMeetings.enumerated()), id: \.element.meetingId) { _, related in
                Button {
                    onSelectMeeting(related.meetingId)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 4) {
                            Text("From")
                                .foregroundStyle(Color.appTextTertiary)
                            Text(related.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.appTextPrimary)
                            Text("(\(related.date.formatted(.relative(presentation: .named))))")
                                .foregroundStyle(Color.appTextTertiary)
                        }
                        .font(.subheadline)

                        Text(related.summaryExcerpt)
                            .font(.caption)
                            .foregroundStyle(Color.appTextSecondary)
                            .lineLimit(isExpanded ? nil : 2)
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            // Show more/less + sources
            HStack {
                if meetings.count > 2 || isExpanded {
                    Button(isExpanded ? "Show less" : "Show more") {
                        withAnimation { isExpanded.toggle() }
                    }
                    .font(.caption)
                    .foregroundStyle(Color.appTextTertiary)
                    .buttonStyle(.plain)
                }

                Spacer()

                Text("\(meetings.count) Sources")
                    .font(.caption)
                    .foregroundStyle(Color.appTextTertiary)
            }
        }
        .padding(16)
        .background(Color.appSurface.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var headerText: String {
        if let company = participantCompany {
            return "You last met with \(company) recently"
        }
        return "Related meetings"
    }

    private var displayedMeetings: [RelevantMeeting] {
        isExpanded ? meetings : Array(meetings.prefix(2))
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

            // Stop button
            Button {
                appState.stopRecording()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Color.appRecording)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("r", modifiers: .command)
            .help("Stop Recording (⌘R)")
            .accessibilityLabel("Stop recording")

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

/// Collapsible "Live transcript" section shown below the notepad during a live
/// meeting. Defaults to collapsed; user-pinned state persists across launches via
/// @AppStorage. The segment count is observed live via TranscriptRepository so
/// the header label keeps ticking even when the pane is collapsed.
private struct LiveTranscriptPane: View {
    let meetingId: String
    @Environment(AppState.self) private var appState
    @AppStorage("liveMeeting.transcriptExpanded") private var isExpanded = false
    @State private var segmentCount = 0
    @State private var observation: DatabaseCancellable?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.appTextSecondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Image(systemName: "waveform")
                        .font(.subheadline)
                        .foregroundStyle(Color.appAccent)
                    Text("Live transcript")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.appTextPrimary)
                    Text("(\(segmentCount) \(segmentCount == 1 ? "segment" : "segments"))")
                        .font(.caption)
                        .foregroundStyle(Color.appTextTertiary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Live transcript, \(segmentCount) segments")
            .accessibilityHint(isExpanded ? "Collapse transcript" : "Expand transcript")

            if isExpanded {
                Divider()
                TranscriptPaneView(meetingId: meetingId)
                    .frame(maxHeight: 200)
            }
        }
        .background(Color.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.appSeparator, lineWidth: 0.5)
        )
        .onAppear(perform: startObserving)
        .onDisappear(perform: stopObserving)
    }

    private func startObserving() {
        observation = appState.transcriptRepository.observeTranscripts(
            meetingId: meetingId
        ) { transcripts in
            Task { @MainActor in
                self.segmentCount = transcripts.count
            }
        }
    }

    private func stopObserving() {
        observation?.cancel()
        observation = nil
    }
}

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

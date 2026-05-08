import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

struct MeetingDetailView: View {
    let meetingId: String

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var meeting: Meeting?
    @State private var selectedTab: DetailTab = .summary
    @State private var showingEditor = false
    @State private var showingDeleteConfirmation = false
    @State private var showingRecipes = false
    @State private var errorMessage: String?
    @State private var showUpNext = true
    @State private var upNextBrief: MeetingPrepBrief?
    @State private var previousSessions: [Meeting] = []
    @State private var summaryModelInfo: String? = nil

    private let exportService = ExportService()

    enum DetailTab: String, CaseIterable {
        case summary, outline, notes, transcript, speakers

        var label: String {
            switch self {
            case .speakers: return "Speakers"
            case .outline:  return "Outline"
            default: return rawValue.capitalized
            }
        }

        var icon: String {
            switch self {
            case .summary: return "doc.text"
            case .outline: return "list.bullet.rectangle"
            case .transcript: return "text.quote"
            case .notes: return "note.text"
            case .speakers: return "person.wave.2"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let meeting {
                // MARK: - Up Next Banner (shown after recording stops)
                if showUpNext,
                   meeting.status == .transcribing || meeting.status == .complete,
                   let nextMeeting = appState.nextUpcomingMeeting {
                    UpNextBannerView(
                        meeting: nextMeeting,
                        prepBrief: upNextBrief,
                        onPrep: {
                            appState.selectedMeetingId = nextMeeting.id
                        },
                        onDismiss: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showUpNext = false
                            }
                        }
                    )
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 4)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                // Pinned header — always visible
                MeetingMetadataHeader(meeting: meeting, onEdit: {
                    showingEditor = true
                })

                // Scrollable metadata that compresses when the window
                // is short — participants, context, previous sessions.
                // Capped so the tab content always gets at least half
                // the available height.
                metadataSection(for: meeting)

                // Tab strip + content — gets layout priority so the
                // main content is always visible and scrollable.
                UnderlinedTabStrip(
                    tabs: DetailTab.allCases,
                    selected: $selectedTab,
                    modelInfo: summaryModelInfo
                )

                tabContent
                    .layoutPriority(1)
            } else {
                Spacer()
                ProgressView("Loading meeting...")
                    .foregroundStyle(Color.appTextSecondary)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appBackground)
        .errorAlert($errorMessage)
        // P4-T01: Keyboard shortcuts for meeting navigation.
        // Tab switching (⌘1/2/3) is handled by the app-level Navigate menu in
        // MeetingManagerApp.swift via NotificationCenter — registering the same
        // shortcuts here would create a duplicate registration whose target is
        // responder-chain-dependent (caught in v3.0.0 QA).
        .background(
            Group {
                Button("") { appState.selectAdjacentMeeting(direction: -1) }
                    .keyboardShortcut(KeyboardShortcuts.prevMeeting)
                Button("") { appState.selectAdjacentMeeting(direction: 1) }
                    .keyboardShortcut(KeyboardShortcuts.nextMeeting)
            }
            .hidden()
        )
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let meeting {
                    // Primary actions: Edit + Recipes (most used)
                    Button {
                        showingEditor = true
                    } label: {
                        Label("Edit", systemImage: "pencil.circle")
                    }
                    .help("Edit meeting")

                    Button {
                        showingRecipes = true
                    } label: {
                        Label("Recipes", systemImage: "text.book.closed")
                    }
                    .help("Run AI recipes on this meeting")

                    // Consolidated actions menu — share, export, archive, delete
                    Menu {
                        // Conditional meeting-state actions
                        if meeting.isReopenable {
                            Button {
                                appState.startRecording(for: meeting)
                            } label: {
                                Label("Resume Recording", systemImage: "record.circle")
                            }
                        }

                        if meeting.status == .scheduled {
                            Button {
                                cancelMeeting()
                            } label: {
                                Label("Cancel Meeting", systemImage: "xmark.circle")
                            }
                        }

                        if meeting.status == .archived {
                            Button {
                                unarchiveMeeting()
                            } label: {
                                Label("Unarchive", systemImage: "archivebox")
                            }
                        } else if !meeting.status.isActive {
                            Button {
                                archiveMeeting()
                            } label: {
                                Label("Archive", systemImage: "archivebox")
                            }
                        }

                        Divider()

                        // Share
                        Button("Share Summary") {
                            Task { await shareSummary() }
                        }
                        Button("Share Full Report") {
                            Task { await shareFullReport() }
                        }

                        Divider()

                        // Export
                        Button("Export Summary (Markdown)") { Task { await exportSummary() } }
                        Button("Export Transcript (Text)") { Task { await exportTranscript() } }
                        Button("Export Full Report (Markdown)") { Task { await exportFullReport() } }
                        Button("Copy Summary as Markdown") { copySummaryMarkdown() }

                        Divider()

                        Button(role: .destructive) {
                            showingDeleteConfirmation = true
                        } label: {
                            Label("Delete Meeting", systemImage: "trash")
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                    .help("Share, export, archive, and more")
                }
            }
        }
        .sheet(isPresented: $showingRecipes) {
            RecipeListView(meetingId: meetingId)
        }
        .sheet(isPresented: $showingEditor) {
            if let meeting {
                MeetingEditorSheet(meeting: meeting) { title, startDate, endDate in
                    saveMeetingEdits(title: title, startDate: startDate, endDate: endDate)
                }
            }
        }
        .confirmationDialog(
            "Delete this meeting?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Meeting", role: .destructive) {
                deleteMeeting()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes the transcript, notes, summaries, action items, and any stored audio recording for this meeting. This cannot be undone.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .switchTab)) { notification in
            if let tabName = notification.object as? String,
               let tab = DetailTab(rawValue: tabName) {
                selectedTab = tab
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .exportMeeting)) { _ in
            Task { await exportFullReport() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .copySummary)) { _ in
            copySummaryMarkdown()
        }
        .onChange(of: appState.taskQueueManager.allTasks) { _, tasks in
            // Reload meeting when context enrichment completes for this meeting
            let contextDone = tasks.contains {
                $0.type == .contextEnrichment && $0.meetingId == meetingId && $0.status == .completed
            }
            if contextDone {
                Task { meeting = try? await appState.meetingRepository.find(id: meetingId) }
            }
        }
        // Refresh meeting status when recording starts or stops so "Start Early"
        // disappears immediately instead of waiting for the next manual reload.
        .onChange(of: appState.activeMeeting?.id) { _, _ in
            Task { meeting = try? await appState.meetingRepository.find(id: meetingId) }
        }
        .onChange(of: appState.isRecording) { _, _ in
            Task { meeting = try? await appState.meetingRepository.find(id: meetingId) }
        }
        .task {
            await loadInitialContext()
        }
    }

    /// Initial-load helper extracted out of the `.task` closure: long inline
    /// async chains in a SwiftUI view body trigger the Swift type-checker's
    /// "unable to type-check this expression" timeout on clean builds.
    /// Append a manually-entered name to the meeting's participant list and
    /// persist. Does nothing if the name is already present (case-insensitive).
    /// Manual additions help when calendar invites missed someone (drop-ins,
    /// folks invited verbally, partners on the call) — these names then flow
    /// through every downstream signal: voice attribution, vocative mining,
    /// the Speakers tab suggestions, etc.
    private func addParticipantToMeeting(_ rawName: String) {
        guard var m = meeting else { return }
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Dedup with format-tolerance: "dave@acme.com", "Dave Smith",
        // and "Dave" all share the canonical key "dave". Prevents adding a
        // duplicate when calendar already lists the email and the user
        // types the display name (or vice versa).
        let newKey = VocativeMiningService.canonicalKey(for: trimmed)
        let existingKeys = m.participantList.map { VocativeMiningService.canonicalKey(for: $0) }
        guard !existingKeys.contains(newKey) else { return }
        var list = m.participantList
        list.append(trimmed)
        m.participants = list.joined(separator: ", ")
        meeting = m
        Task {
            try? await appState.meetingRepository.update(m)
        }
    }

    /// Scrollable metadata band — participants, context brief, previous
    /// sessions. Capped at 200pt so the tab content always gets the
    /// majority of the window height.
    @ViewBuilder
    private func metadataSection(for meeting: Meeting) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                ParticipantBar(
                    participants: meeting.participantList,
                    onTap: { _ in
                        appState.sidebarDestination = .people
                    },
                    onAddParticipant: { newName in
                        addParticipantToMeeting(newName)
                    }
                )

                RelatedMeetingsSection(
                    contextJSON: meeting.contextJSON,
                    onSelectMeeting: { relatedId in
                        appState.selectedMeetingId = relatedId
                    }
                )

                if !previousSessions.isEmpty {
                    previousSessionsSection
                }
            }
        }
        .frame(maxHeight: 200)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Tab body extracted out of the main `body` to keep the SwiftUI type
    /// checker under its complexity budget — see the comment on
    /// `loadInitialContext` for why long inline switches in `body` time out.
    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .summary:
            SummaryView(meetingId: meetingId)
        case .outline:
            DetailedOutlineView(meetingId: meetingId)
        case .transcript:
            FullTranscriptView(meetingId: meetingId)
        case .notes:
            // Pre-recording meetings get the editable, autosaving notepad
            // (NotepadPaneView). The pre-meeting brief stays above the
            // tab strip so it's visible no matter which tab the user is
            // on, and the tab strip itself doesn't shift between tabs.
            // Once recording starts, the same `MeetingNote` row carries
            // forward into LiveMeetingView's NotepadPane (both load via
            // `noteRepository.latestNote(meetingId:)`).
            // Post-recording meetings stay read-only via NotesReviewView.
            if isPreRecording {
                NotepadPaneView(meetingId: meetingId)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                NotesReviewView(meetingId: meetingId)
            }
        case .speakers:
            SpeakerAssignmentView(meetingId: meetingId)
        }
    }

    /// True when this meeting hasn't been recorded yet — `.scheduled` or
    /// `.notified`. Drives two behaviors:
    ///   1. The Notes tab renders the editable `NotepadPaneView` instead
    ///      of the read-only `NotesReviewView`, with autosave on every
    ///      keystroke and a final save on disappear.
    ///   2. The default selected tab is `.notes` rather than `.summary`,
    ///      since pre-recording the summary/transcript/speakers tabs are
    ///      empty and the most useful action is jotting agenda items.
    private var isPreRecording: Bool {
        guard let status = meeting?.status else { return false }
        return status == .scheduled || status == .notified
    }

    private func loadInitialContext() async {
        meeting = try? await appState.meetingRepository.find(id: meetingId)
        // Land users on the Notes tab for pre-recording meetings — the
        // summary/transcript/speakers tabs are all empty until after the
        // meeting runs, but Notes is immediately useful for capturing
        // agenda + context.
        if let status = meeting?.status, status == .scheduled || status == .notified {
            selectedTab = .notes
        }

        // Queue context enrichment when:
        //   1. There's no cache yet, OR
        //   2. The cache exists but has no synthesized brief (e.g. legacy
        //      pre-v3.4 cache, or a v3.4+ cache that ran when no AI backend
        //      was available). enrichContext is idempotent for fully-cached
        //      contexts so this is safe even on every appearance.
        if let m = meeting, !m.participantList.isEmpty {
            let cached = RelevantMeetingService.parseCachedContext(from: m.contextJSON)
            let needsBrief = (m.contextJSON?.isEmpty ?? true) || cached.brief == nil
            if needsBrief {
                await appState.taskQueueManager.enqueue(
                    type: .contextEnrichment,
                    meetingId: meetingId,
                    priority: 8
                )
            }
        }

        // Prep brief for the next upcoming meeting (for the Up Next banner)
        if let nextMeeting = appState.nextUpcomingMeeting {
            let prepService = MeetingPrepService(database: appState.database)
            upNextBrief = try? await prepService.prepBrief(for: nextMeeting)
        }

        // P5-T02: detect prior sessions in the same series.
        if let m = meeting {
            previousSessions = MeetingSeriesService.shared.detectSeries(for: m, in: appState.meetings)
        }

        // Model info for tab strip caption.
        let summaryRepo = appState.summaryRepository
        let latest: MeetingSummary? = try? await summaryRepo.latestSummary(meetingId: meetingId)
        if let s = latest {
            let model: String = s.modelUsed ?? "auto"
            let date: String = DateFormatting.fullDateTime(from: s.generatedAt)
            summaryModelInfo = "\(model) · \(date)"
        }
    }

    // MARK: - P5-T02 Previous Sessions

    private var previousSessionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PREVIOUS SESSIONS")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.appTextTertiary)
                .textCase(.uppercase)
                .tracking(0.5)

            ForEach(previousSessions.prefix(5)) { prev in
                Button {
                    appState.selectedMeetingId = prev.id
                } label: {
                    HStack(spacing: 8) {
                        Text(prev.scheduledStartDate ?? prev.startDate ?? prev.createdAt,
                             format: .dateTime.month(.abbreviated).day())
                            .font(.caption2.weight(.medium).monospacedDigit())
                            .foregroundStyle(Color.appAccent)
                            .frame(width: 44, alignment: .leading)
                        Text(prev.title)
                            .font(.caption)
                            .foregroundStyle(Color.appTextPrimary)
                            .lineLimit(1)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Actions

    private func saveMeetingEdits(title: String, startDate: Date?, endDate: Date?) {
        guard var updatedMeeting = meeting else { return }
        updatedMeeting.title = title
        updatedMeeting.scheduledStartDate = startDate
        updatedMeeting.scheduledEndDate = endDate

        Task {
            do {
                try await appState.meetingRepository.update(updatedMeeting)
                meeting = updatedMeeting
                appState.loadMeetings()
            } catch {
                errorMessage = "Failed to update meeting: \(error.localizedDescription)"
            }
        }
    }

    private func archiveMeeting() {
        Task {
            do {
                try await appState.meetingRepository.archive(id: meetingId)
                meeting?.status = .archived
                appState.loadMeetings()
            } catch {
                errorMessage = "Failed to archive meeting: \(error.localizedDescription)"
            }
        }
    }

    private func unarchiveMeeting() {
        Task {
            do {
                try await appState.meetingRepository.unarchive(id: meetingId)
                meeting?.status = .complete
                appState.loadMeetings()
            } catch {
                errorMessage = "Failed to unarchive meeting: \(error.localizedDescription)"
            }
        }
    }

    private func cancelMeeting() {
        guard var updatedMeeting = meeting else { return }
        updatedMeeting.status = .cancelled

        Task {
            do {
                try await appState.meetingRepository.update(updatedMeeting)
                meeting = updatedMeeting
                appState.loadMeetings()
            } catch {
                errorMessage = "Failed to cancel meeting: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Export Actions

    private func exportSummary() async {
        guard let meeting else { return }
        guard let summary = try? await appState.summaryRepository.latestSummary(meetingId: meetingId) else { return }
        let content = exportService.exportSummaryMarkdown(meeting: meeting, summary: summary)
        let filename = ExportService.sanitizedFilename(from: meeting.title) + "-summary.md"
        _ = await exportService.saveToFile(content: content, suggestedName: filename, fileType: "md")
    }

    private func exportTranscript() async {
        guard let meeting else { return }
        let transcripts = (try? await appState.transcriptRepository.transcriptsForMeeting(meetingId)) ?? []
        let content = exportService.exportTranscriptText(meeting: meeting, transcripts: transcripts)
        let filename = ExportService.sanitizedFilename(from: meeting.title) + "-transcript.txt"
        _ = await exportService.saveToFile(content: content, suggestedName: filename, fileType: "txt")
    }

    private func exportFullReport() async {
        guard let meeting else { return }
        let summary = try? await appState.summaryRepository.latestSummary(meetingId: meetingId)
        let transcripts = (try? await appState.transcriptRepository.transcriptsForMeeting(meetingId)) ?? []
        let notes = (try? await appState.noteRepository.notesForMeeting(meetingId)) ?? []
        let content = exportService.exportFullReport(meeting: meeting, summary: summary, transcripts: transcripts, notes: notes)
        let filename = ExportService.sanitizedFilename(from: meeting.title) + "-report.md"
        _ = await exportService.saveToFile(content: content, suggestedName: filename, fileType: "md")
    }

    private func copySummaryMarkdown() {
        guard let meeting else { return }
        Task {
            guard let summary = try? await appState.summaryRepository.latestSummary(meetingId: meetingId) else { return }
            let markdown = exportService.exportSummaryMarkdown(meeting: meeting, summary: summary)
            ShareService.copyToClipboard(markdown)
        }
    }

    private func shareSummary() async {
        guard let meeting else { return }
        guard let summary = try? await appState.summaryRepository.latestSummary(meetingId: meetingId) else { return }
        let content = exportService.exportSummaryMarkdown(meeting: meeting, summary: summary)
        ShareService.share(content)
    }

    private func shareFullReport() async {
        guard let meeting else { return }
        let summary = try? await appState.summaryRepository.latestSummary(meetingId: meetingId)
        let transcripts = (try? await appState.transcriptRepository.transcriptsForMeeting(meetingId)) ?? []
        let notes = (try? await appState.noteRepository.notesForMeeting(meetingId)) ?? []
        let content = exportService.exportFullReport(meeting: meeting, summary: summary, transcripts: transcripts, notes: notes)
        ShareService.share(content)
    }

    private func deleteMeeting() {
        guard let meeting else { return }
        Task {
            do {
                try await appState.meetingRepository.delete(meeting)
                appState.selectedMeetingId = nil
                appState.loadMeetings()
            } catch {
                errorMessage = "Failed to delete meeting: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Underlined Tab Strip

private struct UnderlinedTabStrip: View {
    let tabs: [MeetingDetailView.DetailTab]
    @Binding var selected: MeetingDetailView.DetailTab
    let modelInfo: String?

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs, id: \.self) { tab in
                tabButton(tab)
            }
            Spacer()
            if let info = modelInfo {
                Text(info)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.appTextMuted)
                    .padding(.trailing, 16)
            }
        }
        .padding(.horizontal, 4)
        .background(Color.appBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.appSeparator)
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private func tabButton(_ tab: MeetingDetailView.DetailTab) -> some View {
        let isSelected = selected == tab
        Button {
            selected = tab
        } label: {
            Text(tab.label)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(isSelected ? Color.appTextPrimary : Color.appTextTertiary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(isSelected ? Color.appAccentMid : Color.clear)
                        .frame(height: 2)
                        .offset(y: 0)
                }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }
}

// MARK: - Preview

// #Preview("Detail View") {
//     MeetingDetailView(meetingId: "preview-1")
//         .environment(AppState())
//         .frame(width: 600, height: 700)
// }

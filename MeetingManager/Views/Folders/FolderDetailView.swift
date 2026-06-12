import SwiftUI

/// Detail view for a recurring meeting series folder.
/// Shows Notes (meeting history), People tabs, and a scoped "Ask about this folder" AI chat.
struct FolderDetailView: View {
    let folder: MeetingFolder
    @Environment(AppState.self) private var appState

    enum Tab { case notes, people, chat, thread }
    @State private var selectedTab: Tab = .notes
    @State private var openItems: [ActionItem] = []
    @State private var thread: SeriesThread?
    @State private var conflicts: [FactLinkDescriptor] = []
    @State private var roiStats: MeetingROI.FolderStats?
    @State private var showHandover = false
    @State private var speakingTrend: (average: Double, points: [Double])?
    @AppStorage("speaking.cardEnabled") private var speakingCardEnabled = false

    private func loadROI() async {
        let ids = folder.meetings.map(\.id)
        let facts = (try? await EntityFactRepository(database: AppDatabase.shared)
            .factsForMeetings(ids, kinds: ["decision"])) ?? []
        let intents = (try? await MeetingIntentRepository(database: AppDatabase.shared)
            .intents(meetingIds: ids)) ?? []
        roiStats = MeetingROI.folderStats(meetings: folder.meetings,
                                          decisionFacts: facts,
                                          intents: intents)
        // TASK-059: your talk-share trend across this series (opt-in).
        if speakingCardEnabled {
            let ordered = folder.meetings.sorted { $0.effectiveDate < $1.effectiveDate }.map(\.id)
            let stats = (try? await SpeechStatsRepository(database: AppDatabase.shared)
                .stats(meetingIds: ordered)) ?? []
            speakingTrend = SpeechStatsBuilder.trend(stats: stats, orderedMeetingIds: ordered)
        }
    }

    private func loadThread() async {
        thread = try? await SeriesThreadRepository(database: AppDatabase.shared).thread(folderKey: folder.key)
        // TASK-056: gardener-detected reversals scoped to this series.
        let ids = Set(folder.meetings.map(\.id))
        conflicts = ((try? await FactLinkRepository(database: AppDatabase.shared).allDescriptors()) ?? [])
            .filter { $0.relation != "duplicate" && ids.contains($0.fromMeetingId) }
    }

    private func loadOpenItems() async {
        let repo = ActionItemRepository(database: AppDatabase.shared)
        let ids = Set(folder.meetings.map(\.id))
        let all = (try? await repo.allOpenItems(limit: 200)) ?? []
        openItems = all.filter { ids.contains($0.meetingId) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // MARK: - Header
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 14) {
                    // Folder icon with stacked-paper look
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.appAccent.opacity(0.18))
                            .frame(width: 48, height: 48)
                        Image(systemName: "folder.fill")
                            .font(.title2)
                            .foregroundStyle(Color.appAccent)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(folder.displayName)
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(Color.appTextPrimary)
                            .lineLimit(1)

                        HStack(spacing: 10) {
                            Label("\(folder.meetingCount) meetings", systemImage: "calendar")
                                .font(.subheadline)
                                .foregroundStyle(Color.appTextSecondary)

                            if let date = folder.lastMeetingDate {
                                Label(date.formatted(date: .abbreviated, time: .omitted),
                                      systemImage: "clock")
                                    .font(.subheadline)
                                    .foregroundStyle(Color.appTextSecondary)
                            }
                        }
                    }

                    Spacer()

                    // TASK-062: generate/view the series handover brief.
                    Button {
                        showHandover = true
                    } label: {
                        Label("Handover", systemImage: "doc.badge.arrow.up")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.appAccent)
                    .help("A brief for someone taking over this series — history, state, decisions, open items, who's who")
                }

                // TASK-065: does this series produce decisions, and do you get
                // what you come for? Neutral stats — never blame framing.
                if let roi = roiStats, roi.decisionsPerHour != nil || roi.hitRate != nil || speakingTrend != nil {
                    HStack(spacing: 12) {
                        if let perHour = roi.decisionsPerHour {
                            Label(String(format: "%.1f decisions/hour", perHour),
                                  systemImage: "checkmark.seal")
                                .font(.caption)
                                .foregroundStyle(Color.appTextSecondary)
                                .help("\(roi.decisionCount) unique decisions across \(String(format: "%.1f", roi.totalHours)) recorded hours")
                        }
                        if let rate = roi.hitRate {
                            Label("\(roi.intentsMet) of \(roi.intentsSet) intents met",
                                  systemImage: "target")
                                .font(.caption)
                                .foregroundStyle(Color.appTextSecondary)
                                .help(rate >= 0.5
                                      ? "You usually get what you come for in this series."
                                      : "You often leave this series without what you came for\(roi.intentsPartial > 0 ? " (\(roi.intentsPartial) partly met)" : "").")
                        }
                        if let trend = speakingTrend {
                            Label("You spoke ~\(Int((trend.average * 100).rounded()))% (last \(trend.points.count))",
                                  systemImage: "waveform")
                                .font(.caption)
                                .foregroundStyle(Color.appTextSecondary)
                                .help("Average share of speaking time across this series' recent sessions. On-device; only you see this.")
                        }
                    }
                }

                // Participant avatars
                if !folder.participants.isEmpty {
                    HStack(spacing: -6) {
                        ForEach(Array(folder.participants.prefix(5).enumerated()), id: \.offset) { idx, name in
                            InitialsAvatar(name: name, size: 26, index: idx)
                        }
                        if folder.participants.count > 5 {
                            Text("+\(folder.participants.count - 5)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.appTextSecondary)
                                .padding(.leading, 10)
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 16)

            // MARK: - Open action items across the series (TASK-040) —
            // the running to-do list a recurring meeting accumulates.
            if !openItems.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("OPEN ACTION ITEMS · \(openItems.count)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.appTextMuted)
                        .tracking(0.4)
                    ForEach(openItems.prefix(4)) { item in
                        HStack(spacing: 8) {
                            Image(systemName: "circle")
                                .font(.caption)
                                .foregroundStyle(Color.appTextTertiary)
                            Text(item.title)
                                .font(.subheadline)
                                .foregroundStyle(Color.appTextSecondary)
                                .lineLimit(1)
                            if let assignee = item.assignee, !assignee.isEmpty {
                                Text(assignee)
                                    .font(.caption2)
                                    .foregroundStyle(Color.appAccent)
                            }
                            Spacer()
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 14)
            }

            // MARK: - Tab Bar
            HStack(spacing: 0) {
                TabButton(label: "Notes", icon: "doc.text", tab: .notes, selected: selectedTab) { selectedTab = .notes }
                TabButton(label: "People", icon: "person.2", tab: .people, selected: selectedTab) { selectedTab = .people }
                TabButton(label: "Ask AI", icon: "sparkles", tab: .chat, selected: selectedTab) { selectedTab = .chat }
                TabButton(label: "Thread", icon: "text.line.first.and.arrowtriangle.forward", tab: .thread, selected: selectedTab) { selectedTab = .thread }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 2)

            Divider().background(Color.appSeparator)
                .task(id: folder.key) { await loadOpenItems(); await loadThread(); await loadROI() }

            // MARK: - Tab Content
            switch selectedTab {
            case .notes:
                FolderNotesTab(folder: folder)
            case .people:
                FolderPeopleTab(folder: folder)
            case .chat:
                FolderChatTab(folder: folder)
            case .thread:
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if let thread {
                            MarkdownRenderer(text: thread.content, baseFontSize: 13)
                            if !conflicts.isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("REVERSALS & CONFLICTS")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(Color.appTextMuted)
                                        .tracking(0.4)
                                    ForEach(Array(conflicts.prefix(6).enumerated()), id: \.offset) { _, c in
                                        HStack(alignment: .top, spacing: 6) {
                                            Text(c.relation == "supersedes" ? "Updated" : "Conflict")
                                                .font(.caption2.weight(.semibold))
                                                .foregroundStyle(.orange)
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 1)
                                                .background(.orange.opacity(0.15))
                                                .clipShape(Capsule())
                                            VStack(alignment: .leading, spacing: 1) {
                                                Text(c.toText)
                                                    .font(.caption)
                                                    .strikethrough(c.relation == "supersedes")
                                                    .foregroundStyle(Color.appTextTertiary)
                                                    .lineLimit(2)
                                                Text(c.fromText)
                                                    .font(.caption)
                                                    .foregroundStyle(Color.appTextSecondary)
                                                    .lineLimit(2)
                                            }
                                        }
                                    }
                                }
                                .padding(.top, 12)
                            }
                            Text("Updated \(thread.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption2)
                                .foregroundStyle(Color.appTextTertiary)
                        } else {
                            Text("The running thread builds itself after the next summarized session in this series.")
                                .font(.subheadline)
                                .foregroundStyle(Color.appTextTertiary)
                                .padding(.top, 24)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
                }
            }
        }
        .background(Color.appBackground)
        .sheet(isPresented: $showHandover) {
            HandoverDocSheet(folder: folder)
                .environment(appState)
        }
    }
}

// MARK: - Handover doc sheet (TASK-062)

private struct HandoverDocSheet: View {
    let folder: MeetingFolder
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var doc: GeneratedDoc?
    @State private var isGenerating = false
    @State private var statusText: String?
    @State private var requestId: UUID?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "doc.badge.arrow.up")
                    .foregroundStyle(Color.appAccent)
                Text("Handover — \(folder.displayName)")
                    .font(.headline)
                    .foregroundStyle(Color.appTextPrimary)
                    .lineLimit(1)
                Spacer()
                if isGenerating {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(statusText ?? "Writing…")
                            .font(.caption)
                            .foregroundStyle(Color.appTextTertiary)
                    }
                } else {
                    Button(doc == nil ? "Generate" : "Regenerate") {
                        Task { await generate() }
                    }
                    .font(.caption)
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .font(.caption)
            }
            .padding(14)
            Divider()

            if let doc {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        MarkdownRenderer(text: doc.content, baseFontSize: 13)
                        Text("Generated \(doc.createdAt.formatted(date: .abbreviated, time: .shortened)). Built only from this series' recorded threads, facts, and summaries.")
                            .font(.caption2)
                            .foregroundStyle(Color.appTextTertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                }
            } else if !isGenerating {
                Spacer()
                VStack(spacing: 8) {
                    Text("No handover brief yet.")
                        .font(.subheadline)
                        .foregroundStyle(Color.appTextSecondary)
                    Text("Generate one from this series' running thread, extracted facts, and recent summaries.")
                        .font(.caption)
                        .foregroundStyle(Color.appTextTertiary)
                }
                Spacer()
            } else {
                Spacer()
            }
        }
        .frame(width: 620, height: 540)
        .task {
            doc = try? await GeneratedDocRepository(database: AppDatabase.shared)
                .latest(kind: "handover", anchorKey: folder.key)
        }
        .onDisappear {
            if let id = requestId { appState.interactiveAIBroker.cancel(id: id) }
        }
    }

    private func generate() async {
        isGenerating = true
        statusText = "Gathering the record…"

        let ids = folder.meetings.map(\.id)
        let thread = try? await SeriesThreadRepository(database: AppDatabase.shared).thread(folderKey: folder.key)
        let facts = ((try? await EntityFactRepository(database: AppDatabase.shared)
            .factsForMeetings(ids)) ?? [])
            .filter { $0.entityType == "series" }
        var summaries: [(title: String, date: Date, excerpt: String)] = []
        for meeting in folder.meetings.sorted(by: { $0.effectiveDate > $1.effectiveDate }).prefix(3) {
            if let s = try? await appState.summaryRepository.latestSummary(meetingId: meeting.id),
               !s.summaryText.isEmpty {
                summaries.append((meeting.title, meeting.effectiveDate, s.summaryText))
            }
        }
        guard thread != nil || !facts.isEmpty || !summaries.isEmpty else {
            statusText = nil
            isGenerating = false
            doc = GeneratedDoc(id: nil, kind: "handover", anchorKey: folder.key,
                               content: "Nothing recorded for this series yet — record and summarize a session first.",
                               createdAt: Date())
            return
        }
        guard let textGen = await appState.makeTextGenerator(
            maxOutputTokens: 1800,
            activityLabel: "Writing handover brief"
        ) else {
            statusText = nil
            isGenerating = false
            return
        }

        let userPrompt = HandoverDoc.userPrompt(
            folderName: folder.displayName,
            participants: folder.participants,
            threadContent: thread?.content,
            facts: facts,
            summaries: summaries)
        let folderKey = folder.key
        let folderName = folder.displayName
        let id = UUID()
        requestId = id
        statusText = appState.interactiveAIBroker.isBlocked
            ? "Waiting for the model…" : "Writing…"
        appState.interactiveAIBroker.submit(id: id, label: "Handover: \(folderName)") {
            let content = (try? await textGen(HandoverDoc.systemPrompt, userPrompt)) ?? ""
            await MainActor.run {
                defer { isGenerating = false; statusText = nil }
                guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                let newDoc = GeneratedDoc(id: nil, kind: "handover", anchorKey: folderKey,
                                          content: content, createdAt: Date())
                doc = newDoc
                Task {
                    try? await GeneratedDocRepository(database: AppDatabase.shared).save(newDoc)
                    if appState.settings.kbWriteBack,
                       let root = KnowledgeBaseService.shared.rootURL {
                        let dir = root.appendingPathComponent("Handovers", isDirectory: true)
                        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        let url = dir.appendingPathComponent("\(folderName) Handover.md")
                        try? content.write(to: url, atomically: true, encoding: .utf8)
                        await KnowledgeBaseService.shared.reindexFile(url: url)
                    }
                }
            }
        }
    }
}

// MARK: - Tab Button

private struct TabButton: View {
    let label: String
    let icon: String
    let tab: FolderDetailView.Tab
    let selected: FolderDetailView.Tab
    let action: () -> Void

    private var isSelected: Bool { tab == selected }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.caption)
                Text(label)
                    .font(.subheadline.weight(isSelected ? .semibold : .regular))
            }
            .foregroundStyle(isSelected ? Color.appAccent : Color.appTextSecondary)
            .padding(.vertical, 8)
            .padding(.horizontal, 14)
            .overlay(
                Rectangle()
                    .fill(isSelected ? Color.appAccent : Color.clear)
                    .frame(height: 2),
                alignment: .bottom
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Notes Tab

private struct FolderNotesTab: View {
    let folder: MeetingFolder
    @Environment(AppState.self) private var appState

    var body: some View {
        ScrollView {
            VStack(spacing: 6) {
                ForEach(folder.meetings) { meeting in
                    FolderMeetingRow(meeting: meeting)
                        .onTapGesture {
                            appState.selectedMeetingId = meeting.id
                            appState.sidebarDestination = .meetings
                        }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
    }
}

// MARK: - Folder Meeting Row

private struct FolderMeetingRow: View {
    let meeting: Meeting

    var body: some View {
        HStack(spacing: 14) {
            // Date badge
            VStack(spacing: 1) {
                Text(meeting.effectiveDate.formatted(.dateTime.month(.abbreviated)))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.appTextSecondary)
                    .textCase(.uppercase)
                Text(meeting.effectiveDate.formatted(.dateTime.day()))
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.appTextPrimary)
            }
            .frame(width: 40)
            .padding(.vertical, 8)
            .background(Color.appSurface)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(meeting.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.appTextPrimary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(meeting.effectiveDate.formatted(.dateTime.hour().minute()))
                        .font(.caption)
                        .foregroundStyle(Color.appTextSecondary)

                    let dur = meeting.formattedDuration
                    if dur != "--" {
                        Text("·")
                            .font(.caption)
                            .foregroundStyle(Color.appTextTertiary)
                        Text(dur)
                            .font(.caption)
                            .foregroundStyle(Color.appTextSecondary)
                    }
                }

                // Participant avatars
                if !meeting.participantList.isEmpty {
                    HStack(spacing: -4) {
                        ForEach(Array(meeting.participantList.prefix(4).enumerated()), id: \.offset) { idx, name in
                            InitialsAvatar(name: name, size: 18, index: idx)
                        }
                    }
                }
            }

            Spacer()

            Image(systemName: meeting.status == .complete ? "checkmark.circle.fill" : "circle")
                .font(.caption)
                .foregroundStyle(meeting.status == .complete ? Color.appSuccess : Color.appTextTertiary)

            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(Color.appTextTertiary)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(Color.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - People Tab

private struct FolderPeopleTab: View {
    let folder: MeetingFolder
    @Environment(AppState.self) private var appState

    var body: some View {
        ScrollView {
            VStack(spacing: 6) {
                if folder.participants.isEmpty {
                    EmptyStateView(
                        icon: "person.2.slash",
                        title: "No Participants",
                        subtitle: "No named participants found in this series."
                    )
                    .padding()
                } else {
                    ForEach(folder.participants, id: \.self) { name in
                        let meetings = folder.meetings.filter { $0.participantList.contains(name) }
                        Button {
                            appState.sidebarDestination = .people
                        } label: {
                            HStack(spacing: 12) {
                                InitialsAvatar(name: name, size: 36)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(name)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(Color.appTextPrimary)
                                    Text("\(meetings.count) meeting\(meetings.count == 1 ? "" : "s") in this series")
                                        .font(.caption)
                                        .foregroundStyle(Color.appTextSecondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(Color.appTextTertiary)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Color.appSurface)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .contentShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
    }
}

// MARK: - Chat Tab

private struct FolderChatTab: View {
    let folder: MeetingFolder
    @Environment(AppState.self) private var appState

    @State private var messages: [GlobalChatMessage] = []
    @State private var inputText = ""
    @State private var isProcessing = false
    @State private var error: String?
    @State private var currentTask: Task<Void, Never>?
    @FocusState private var isInputFocused: Bool

    private let folderRecipes: [(icon: String, label: String, prompt: String)] = [
        ("checklist", "Action items", "What are all the action items from this meeting series?"),
        ("lightbulb", "Key decisions", "What are the most important decisions made in this meeting series?"),
        ("arrow.triangle.2.circlepath", "Recurring themes", "What topics keep coming up across these meetings?"),
        ("exclamationmark.triangle", "Open issues", "What problems or blockers have been raised but not resolved?"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            if messages.isEmpty {
                // Empty state with recipe chips
                FolderChatEmptyState(
                    folderName: folder.displayName,
                    recipes: folderRecipes,
                    onSelect: { prompt in
                        inputText = prompt
                        currentTask = Task { await sendMessage() }
                    }
                )
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(messages) { message in
                                GlobalChatBubble(message: message)
                                    .id(message.id)
                            }
                            if isProcessing {
                                ThinkingBubble()
                                    .id("folder-thinking")
                            }
                        }
                        .padding(.vertical, 12)
                    }
                    .onChange(of: messages.count) {
                        if let last = messages.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
            }

            if let error {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(Color.appWarning)
                    Text(error)
                        .font(.caption).foregroundStyle(Color.appTextSecondary)
                    Spacer()
                    Button("Dismiss") { self.error = nil }
                        .font(.caption).buttonStyle(.plain).foregroundStyle(Color.appAccent)
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(Color.appWarning.opacity(0.08))
            }

            Divider().background(Color.appSeparator)

            HStack(spacing: 10) {
                TextField("Ask about \(folder.displayName)…", text: $inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
                    .lineLimit(1...4)
                    .focused($isInputFocused)
                    .onSubmit {
                        guard !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                        currentTask = Task { await sendMessage() }
                    }

                Button {
                    if isProcessing {
                        currentTask?.cancel()
                        currentTask = nil
                        isProcessing = false
                    } else {
                        currentTask = Task { await sendMessage() }
                    }
                } label: {
                    Image(systemName: isProcessing ? "stop.circle.fill" : "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(
                            inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? Color.appTextTertiary : Color.appAccent
                        )
                }
                .buttonStyle(.plain)
                .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isProcessing)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
    }

    @MainActor
    private func sendMessage() async {
        let query = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        inputText = ""
        error = nil
        withAnimation { messages.append(GlobalChatMessage(role: .user, content: query)) }

        isProcessing = true
        defer { isProcessing = false }

        guard let textGen = await appState.makeTextGenerator() else {
            error = "No AI configured. Add a Claude API key or start Ollama in Settings."
            return
        }

        do {
            let context = try await buildFolderContext()
            let systemPrompt = """
                You are a meeting assistant. Answer questions about the "\(folder.displayName)" meeting series. \
                Use only the context below — if information isn't available, say so clearly.

                \(context)
                """
            let response = try await textGen(systemPrompt, query)
            withAnimation { messages.append(GlobalChatMessage(role: .assistant, content: response)) }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func buildFolderContext() async throws -> String {
        let txRepo = appState.transcriptRepository
        let sumRepo = appState.summaryRepository
        var parts: [String] = []

        for meeting in folder.meetings.prefix(10) {
            var lines: [String] = ["## \(meeting.title) — \(meeting.effectiveDate.formatted(date: .abbreviated, time: .shortened))"]
            if !meeting.participantList.isEmpty {
                lines.append("Participants: \(meeting.participantList.joined(separator: ", "))")
            }
            if let summary = try? await sumRepo.latestSummary(meetingId: meeting.id), !summary.summaryText.isEmpty {
                lines.append("Notes: \(summary.summaryText.prefix(500))")
            } else {
                let segs = try await txRepo.transcriptsForMeeting(meeting.id)
                if !segs.isEmpty {
                    lines.append("Transcript: \(segs.map(\.text).joined(separator: " ").prefix(400))…")
                }
            }
            parts.append(lines.joined(separator: "\n"))
        }

        return parts.isEmpty
            ? "No recorded content available for this series yet."
            : parts.joined(separator: "\n\n---\n\n")
    }
}

// MARK: - Folder Chat Empty State

private struct FolderChatEmptyState: View {
    let folderName: String
    let recipes: [(icon: String, label: String, prompt: String)]
    let onSelect: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Spacer().frame(height: 16)

                VStack(spacing: 8) {
                    ZStack {
                        Circle()
                            .fill(Color.appAccent.opacity(0.12))
                            .frame(width: 52, height: 52)
                        Image(systemName: "sparkles")
                            .font(.title2)
                            .foregroundStyle(Color.appAccent)
                    }
                    Text("Ask about \(folderName)")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(Color.appTextPrimary)
                    Text("Questions are answered using notes and\ntranscripts from this meeting series only.")
                        .font(.caption)
                        .foregroundStyle(Color.appTextSecondary)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 6) {
                    ForEach(recipes, id: \.label) { recipe in
                        Button { onSelect(recipe.prompt) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: recipe.icon)
                                    .font(.subheadline)
                                    .foregroundStyle(Color.appAccent)
                                    .frame(width: 20)
                                Text(recipe.label)
                                    .font(.subheadline)
                                    .foregroundStyle(Color.appTextPrimary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(Color.appTextTertiary)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background(Color.appSurface)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .contentShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 4)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
    }
}

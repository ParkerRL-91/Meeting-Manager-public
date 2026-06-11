import SwiftUI

/// App-level "Ask Anything" chat interface.
/// Unlike MeetingChatView (scoped to one meeting), this searches across ALL meetings.
struct GlobalChatView: View {
    @Environment(AppState.self) private var appState

    // messages live in AppState so they survive navigation away and back
    @State private var inputText = ""
    @State private var isProcessing = false
    @State private var error: String?
    @State private var showClearConfirm = false
    @State private var currentTask: Task<Void, Never>?
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {

            // MARK: - Header
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.title3)
                    .foregroundStyle(Color.appAccent)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Ask Anything")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(Color.appTextPrimary)
                    Text("Search across all your meetings")
                        .font(.caption)
                        .foregroundStyle(Color.appTextSecondary)
                }
                Spacer()
                if !appState.globalChatMessages.isEmpty {
                    Button {
                        showClearConfirm = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.caption)
                            .foregroundStyle(Color.appTextTertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear conversation")
                    .confirmationDialog("Clear conversation?", isPresented: $showClearConfirm, titleVisibility: .visible) {
                        Button("Clear", role: .destructive) { withAnimation { appState.globalChatMessages = [] } }
                        Button("Cancel", role: .cancel) {}
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider().background(Color.appSeparator)

            // MARK: - Message Area
            // Wrap in a Group with maxHeight:.infinity so this region is flexible
            // and the input bar at the bottom always gets its natural height.
            Group {
                if appState.globalChatMessages.isEmpty {
                    GlobalChatEmptyState(onSuggest: { suggestion in
                        inputText = suggestion
                        // EXEMPT from TaskQueue: interactive conversational AI chat.
                        // User expects streaming, immediate responses, and cancellation via Stop button.
                        // Chat history managed in AppState; routing through TaskQueue adds no value here.
                        Task { await sendMessage() }
                    })
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(appState.globalChatMessages) { message in
                                    GlobalChatBubble(message: message)
                                        .id(message.id)
                                }
                                if isProcessing {
                                    ThinkingBubble()
                                        .id("thinking-indicator")
                                }
                            }
                            .padding(.vertical, 12)
                        }
                        .onChange(of: appState.globalChatMessages.count) {
                            withAnimation(.easeOut(duration: 0.2)) {
                                if let lastId = appState.globalChatMessages.last?.id {
                                    proxy.scrollTo(lastId, anchor: .bottom)
                                }
                            }
                        }
                        .onChange(of: isProcessing) {
                            if isProcessing {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    proxy.scrollTo("thinking-indicator", anchor: .bottom)
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // MARK: - Error Banner
            if let error {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.appWarning)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(Color.appTextSecondary)
                    Spacer()
                    Button("Dismiss") { self.error = nil }
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.appAccent)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.appWarning.opacity(0.08))
            }

            // MARK: - Input
            // Floating pill input — always visible, strong background so it
            // reads clearly regardless of window size.
            HStack(spacing: 10) {
                TextField("Ask about your meetings…", text: $inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
                    .foregroundStyle(Color.appTextPrimary)
                    .lineLimit(1...5)
                    .focused($isInputFocused)
                    .onSubmit {
                        if !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            currentTask = Task { await sendMessage() }
                        }
                    }
                    .submitLabel(.send)

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
                            inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isProcessing
                                ? Color.appTextTertiary
                                : Color.appAccent
                        )
                }
                .buttonStyle(.plain)
                .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isProcessing)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.appSurface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.appBorderStrong, lineWidth: 1)
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
            .padding(.top, 10)
        }
        .background(Color.appBackground)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { isInputFocused = true }
    }

    // MARK: - Send

    @MainActor
    private func sendMessage() async {
        let query = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        inputText = ""
        error = nil

        let userMsg = GlobalChatMessage(role: .user, content: query)
        withAnimation { appState.globalChatMessages.append(userMsg) }

        isProcessing = true
        defer { isProcessing = false }

        guard let textGen = await appState.makeTextGenerator() else {
            error = "No AI configured. Add a Claude API key or start Ollama in Settings."
            return
        }

        do {
            let (meetingContext, sources, kbContext) = await buildRetrievalContext(query: query)

            var systemPrompt = """
                You are a helpful meeting assistant for \(getDisplayName()). \
                The numbered SOURCES below were retrieved from their meeting \
                history for this question.

                **Formatting rules — always follow these:**
                - Respond in Markdown.
                - Use ## for section headings when the answer has multiple parts.
                - Use bullet lists (- item) for lists of facts, people, or action items.
                - Use **bold** for names, decisions, and key phrases.
                - Cite sources inline as [1], [2] … wherever a claim comes from one.
                - Keep answers concise — prefer 150–300 words unless depth is clearly needed.

                Answer ONLY from the sources and excerpts provided. If they \
                don't contain the answer, say exactly what's missing rather \
                than guessing.

                \(meetingContext)
                """

            if !kbContext.isEmpty {
                systemPrompt += """


                    Knowledge Base excerpts (authoritative reference material — cite source path when used):
                    \(kbContext)
                    """
            }

            let response = try await textGen(systemPrompt, query)
            let assistantMsg = GlobalChatMessage(role: .assistant, content: response, sources: sources)
            withAnimation { appState.globalChatMessages.append(assistantMsg) }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// TASK-048: retrieval REPLACES the old recent-15-meetings dump.
    /// Semantic top-k (when the embedding index exists) fused with FTS,
    /// deduped to the best 2 chunks per meeting, capped at 8 numbered
    /// sources. Falls back to FTS alone — and to the most recent summaries
    /// when the query matches nothing — so the chat never goes blind.
    private func buildRetrievalContext(query: String) async -> (context: String, sources: [GlobalChatMessage.SourceRef], kb: String) {
        var ranked: [(meetingId: String, snippet: String, score: Float)] = []

        let hits = (try? await appState.embeddingService.topK(
            query: query, k: 12, sourceTypes: ["transcriptChunk", "summary", "kbDoc"])) ?? []
        for h in hits where h.meetingId != nil {
            ranked.append((h.meetingId!, h.text, h.score))
        }
        if let fts = try? await appState.transcriptRepository.searchAllMeetings(query: query, limit: 6) {
            for (mid, snip) in fts where !snip.isEmpty {
                ranked.append((mid, snip, 0.45))   // below strong semantic hits, above weak ones
            }
        }

        // Dedup: at most 2 chunks per meeting, 8 total, best first.
        var perMeeting: [String: Int] = [:]
        var picked: [(String, String)] = []
        for item in ranked.sorted(by: { $0.score > $1.score }) {
            guard perMeeting[item.meetingId, default: 0] < 2 else { continue }
            perMeeting[item.meetingId, default: 0] += 1
            picked.append((item.meetingId, item.snippet))
            if picked.count >= 8 { break }
        }

        let all = (try? await appState.meetingRepository.allActiveMeetings()) ?? []
        let byId = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

        // Last resort: nothing matched — give the model the 5 most recent
        // summaries so "what did I do this week" still works.
        if picked.isEmpty {
            for meeting in all.prefix(5) {
                if let summary = try? await appState.summaryRepository.latestSummary(meetingId: meeting.id) {
                    picked.append((meeting.id, String(summary.summaryText.prefix(600))))
                }
            }
        }

        var sources: [GlobalChatMessage.SourceRef] = []
        var blocks: [String] = []
        var indexForMeeting: [String: Int] = [:]
        for (mid, snippet) in picked {
            let meeting = byId[mid]
            let title = meeting?.title ?? "Meeting"
            let date = meeting?.effectiveDate.formatted(date: .abbreviated, time: .omitted) ?? ""
            let n: Int
            if let existing = indexForMeeting[mid] {
                n = existing
            } else {
                sources.append(.init(meetingId: mid, title: title))
                n = sources.count
                indexForMeeting[mid] = n
            }
            blocks.append("[\(n)] \(title) — \(date)\n\(snippet)")
        }

        let context = blocks.isEmpty
            ? "SOURCES: none found for this question."
            : "SOURCES:\n\n" + blocks.joined(separator: "\n\n---\n\n")
        let kbContext = await KnowledgeBaseService.shared.retrieveContext(query: query)
        return (context, sources, kbContext)
    }

    private func getDisplayName() -> String {
        // Best-effort: use system name
        ProcessInfo.processInfo.fullUserName
    }
}

// MARK: - Empty State with Quick Prompts

private struct GlobalChatEmptyState: View {
    let onSuggest: (String) -> Void
    private let suggestions: [(icon: String, label: String, prompt: String)] = [
        ("checklist", "Recent action items", "What are all the action items from my recent meetings?"),
        ("lightbulb", "Key decisions", "What were the key decisions made in my meetings this week?"),
        ("person.2", "Who I met with", "Who did I meet with most recently and what did we discuss?"),
        ("clock.badge.questionmark", "Follow-ups needed", "What follow-ups or open questions were raised in my recent meetings?"),
        ("doc.text.magnifyingglass", "Search topics", "What was discussed about project planning in recent meetings?"),
    ]

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // Icon + headline
            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Color.appAccent.opacity(0.12))
                        .frame(width: 60, height: 60)
                    Image(systemName: "sparkles")
                        .font(.title)
                        .foregroundStyle(Color.appAccent)
                }
                Text("Ask about your meetings")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.appTextPrimary)
                Text("Search across notes, transcripts, and\naction items from all your meetings.")
                    .font(.subheadline)
                    .foregroundStyle(Color.appTextSecondary)
                    .multilineTextAlignment(.center)
            }

            // Quick suggestion chips
            VStack(alignment: .leading, spacing: 8) {
                Text("Try asking…")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.appTextTertiary)
                    .textCase(.uppercase)
                    .tracking(0.6)

                ForEach(suggestions, id: \.label) { item in
                    Button {
                        onSuggest(item.prompt)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: item.icon)
                                .font(.subheadline)
                                .foregroundStyle(Color.appAccent)
                                .frame(width: 20)
                            Text(item.label)
                                .font(.subheadline)
                                .foregroundStyle(Color.appTextPrimary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(Color.appTextTertiary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color.appSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 380)

            Spacer()
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Chat Bubble

struct GlobalChatBubble: View {
    let message: GlobalChatMessage
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if message.role == .user {
                Spacer(minLength: 60)
                Text(message.content)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.appAccent)
                    .clipShape(BubbleShape(isUser: true))
            } else {
                // Assistant avatar
                ZStack {
                    Circle()
                        .fill(Color.appAccent.opacity(0.15))
                        .frame(width: 26, height: 26)
                    Image(systemName: "sparkles")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.appAccent)
                }
                .padding(.top, 4)

                // Render Markdown so headings, bullets, bold etc. display
                // properly; citation chips (TASK-048) sit under the answer —
                // [n] in the text maps to these in order, click opens the
                // meeting.
                VStack(alignment: .leading, spacing: 6) {
                    MarkdownRenderer(text: message.content, baseFontSize: 14)
                    if !message.sources.isEmpty {
                        FlowLayout(spacing: 4) {
                            ForEach(Array(message.sources.enumerated()), id: \.element.id) { idx, src in
                                Button {
                                    appState.sidebarDestination = .meetings
                                    appState.selectedMeetingId = src.meetingId
                                } label: {
                                    Text("[\(idx + 1)] \(src.title)")
                                        .font(.caption2)
                                        .lineLimit(1)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.appAccentSubtle)
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.appSurface)
                    .clipShape(BubbleShape(isUser: false))
                    .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 16)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }
}

struct ThinkingBubble: View {
    @State private var dot = 0
    private let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.appAccent.opacity(0.15))
                    .frame(width: 26, height: 26)
                Image(systemName: "sparkles")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.appAccent)
            }
            .padding(.top, 2)

            HStack(spacing: 4) {
                ForEach(0..<3) { i in
                    Circle()
                        .fill(Color.appTextSecondary)
                        .frame(width: 6, height: 6)
                        .scaleEffect(dot == i ? 1.3 : 0.8)
                        .animation(.easeInOut(duration: 0.3), value: dot)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .background(Color.appSurface)
            .clipShape(BubbleShape(isUser: false))

            Spacer(minLength: 40)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 3)
        .onReceive(timer) { _ in
            dot = (dot + 1) % 3
        }
    }
}

struct BubbleShape: Shape {
    let isUser: Bool
    func path(in rect: CGRect) -> Path {
        let r: CGFloat = 14
        var path = Path()
        path.addRoundedRect(in: rect, cornerSize: CGSize(width: r, height: r))
        return path
    }
}

// MARK: - Model

struct GlobalChatMessage: Identifiable {
    let id = UUID()
    let role: Role
    let content: String
    let createdAt = Date()
    /// Numbered retrieval sources behind an assistant answer (TASK-048).
    /// Index order matches the [n] citations the prompt mandates.
    var sources: [SourceRef] = []

    enum Role { case user, assistant }

    struct SourceRef: Identifiable {
        let meetingId: String
        let title: String
        var id: String { meetingId }
    }
}

import SwiftUI

/// Global search sheet (⌘K — TASK-039). One query field over four sources:
/// meeting titles, transcript full text (FTS5, best snippet per meeting),
/// people, and open action items. Selecting a result navigates and closes
/// the sheet. Queries debounce 250 ms; everything is read-only.
struct GlobalSearchView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var titleHits: [Meeting] = []
    @State private var transcriptHits: [(meeting: Meeting, snippet: String)] = []
    @State private var peopleHits: [Person] = []
    @State private var itemHits: [(item: TaskItem, meetingTitle: String?)] = []
    @State private var discussedBy: [PersonTopicAffinity.Ranked] = []
    @State private var glossaryHits: [GlossaryTerm] = []
    @State private var slideHits: [(slide: MeetingSlide, meetingTitle: String?)] = []
    @State private var decisionHits: [(decision: Decision, meetingTitle: String?)] = []
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var fieldFocused: Bool

    // TASK-057: timeline mode — "everything we said about X, in order".
    @State private var showTimeline = false
    @State private var timelinePoints: [TrajectoryBuilder.Point] = []
    @State private var timelineTopic = ""
    @State private var timelineLoading = false
    @State private var stanceRequestId: UUID?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Color.appTextTertiary)
                TextField("Search meetings, transcripts, people, action items…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($fieldFocused)
                    .onSubmit { openFirstHit() }
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.appTextTertiary)
            }
            .padding(14)

            Divider()

            if showTimeline {
                timelineView
            } else if query.trimmingCharacters(in: .whitespaces).count < 2 {
                Spacer()
                Text("Type at least two characters to search.")
                    .font(.subheadline)
                    .foregroundStyle(Color.appTextTertiary)
                Spacer()
            } else if titleHits.isEmpty && transcriptHits.isEmpty && peopleHits.isEmpty && itemHits.isEmpty && discussedBy.isEmpty && glossaryHits.isEmpty && slideHits.isEmpty && decisionHits.isEmpty {
                Spacer()
                Text("No matches for \"\(query)\".")
                    .font(.subheadline)
                    .foregroundStyle(Color.appTextTertiary)
                Spacer()
            } else {
                List {
                    if query.trimmingCharacters(in: .whitespaces).count >= 3 {
                        // TASK-057: switch to the chronological topic view.
                        resultRow(icon: "chart.xyaxis.line",
                                  title: "View timeline for \"\(query.trimmingCharacters(in: .whitespaces))\"",
                                  subtitle: "Every mention in order, oldest first") {
                            Task { await buildTimeline() }
                        }
                    }
                    if !titleHits.isEmpty {
                        Section("Meetings") {
                            ForEach(titleHits) { meeting in
                                resultRow(icon: "calendar", title: meeting.title,
                                          subtitle: meeting.effectiveDate.formatted(date: .abbreviated, time: .shortened)) {
                                    open(meetingId: meeting.id)
                                }
                            }
                        }
                    }
                    if !transcriptHits.isEmpty {
                        Section("In Transcripts") {
                            ForEach(transcriptHits, id: \.meeting.id) { hit in
                                resultRow(icon: "text.quote", title: hit.meeting.title,
                                          subtitle: hit.snippet) {
                                    open(meetingId: hit.meeting.id)
                                }
                            }
                        }
                    }
                    if !slideHits.isEmpty {
                        // TASK-069: "find the meeting where they showed
                        // the pricing slide".
                        Section("Slides") {
                            ForEach(slideHits, id: \.slide.id) { hit in
                                resultRow(icon: "camera.on.rectangle",
                                          title: hit.meetingTitle ?? "Captured slide",
                                          subtitle: String(hit.slide.text.prefix(120))) {
                                    open(meetingId: hit.slide.meetingId)
                                }
                            }
                        }
                    }
                    if !glossaryHits.isEmpty {
                        // TASK-064: team vocabulary, defined from usage.
                        Section("Glossary") {
                            ForEach(glossaryHits) { term in
                                resultRow(icon: "character.book.closed",
                                          title: term.term,
                                          subtitle: term.definition) {
                                    if let meetingId = term.exampleMeetingId { open(meetingId: meetingId) }
                                }
                                .contextMenu {
                                    Button("Remove from glossary", role: .destructive) {
                                        Task {
                                            try? await GlossaryRepository(database: AppDatabase.shared).hide(term: term.term)
                                            glossaryHits.removeAll { $0.term == term.term }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    if !discussedBy.isEmpty {
                        // TASK-060: who already knows this topic.
                        Section("People who've discussed this") {
                            ForEach(discussedBy, id: \.name) { ranked in
                                resultRow(icon: "person.2.wave.2",
                                          title: ranked.name,
                                          subtitle: "\(ranked.meetingCount) meeting\(ranked.meetingCount == 1 ? "" : "s") · last \(ranked.lastDiscussed.formatted(date: .abbreviated, time: .omitted))") {
                                    appState.sidebarDestination = .people
                                    dismiss()
                                }
                            }
                        }
                    }
                    if !peopleHits.isEmpty {
                        Section("People") {
                            ForEach(peopleHits) { person in
                                resultRow(icon: "person", title: person.canonicalName,
                                          subtitle: person.primaryEmail ?? "") {
                                    appState.sidebarDestination = .people
                                    dismiss()
                                }
                            }
                        }
                    }
                    if !itemHits.isEmpty {
                        Section("Open Action Items") {
                            ForEach(itemHits, id: \.item.id) { hit in
                                resultRow(icon: "checklist", title: hit.item.title,
                                          subtitle: hit.meetingTitle ?? "") {
                                    if let mid = hit.item.meetingId { open(meetingId: mid) }
                                }
                            }
                        }
                    }
                    if !decisionHits.isEmpty {
                        // TASK-129: recall a decision from anywhere. Confirmed +
                        // suggested both searchable (suggested labeled
                        // "Unreviewed"); dismissed excluded upstream.
                        Section("Decisions") {
                            ForEach(decisionHits, id: \.decision.id) { hit in
                                resultRow(icon: hit.decision.isSuggested ? "checkmark.seal" : "checkmark.seal.fill",
                                          title: hit.decision.title,
                                          subtitle: decisionSubtitle(hit.decision, meetingTitle: hit.meetingTitle)) {
                                    open(meetingId: hit.decision.meetingId)
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(width: 560, height: 460)
        .onAppear { fieldFocused = true }
        .onDisappear {
            if let id = stanceRequestId { appState.interactiveAIBroker.cancel(id: id) }
        }
        .onChange(of: query) { _, newValue in
            searchTask?.cancel()
            searchTask = Task {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                await runSearch(newValue)
            }
        }
    }

    // MARK: - Timeline mode (TASK-057)

    @ViewBuilder
    private var timelineView: some View {
        HStack(spacing: 8) {
            Button {
                showTimeline = false
                if let id = stanceRequestId { appState.interactiveAIBroker.cancel(id: id) }
            } label: {
                Label("Results", systemImage: "chevron.left")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.appAccent)
            Text("Timeline · \(timelineTopic)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.appTextSecondary)
                .lineLimit(1)
            Spacer()
            if timelineLoading { ProgressView().controlSize(.mini) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)

        if timelinePoints.isEmpty && !timelineLoading {
            Spacer()
            Text("No mentions of \"\(timelineTopic)\" found.")
                .font(.subheadline)
                .foregroundStyle(Color.appTextTertiary)
            Spacer()
        } else {
            List {
                if !discussedBy.isEmpty {
                    Section("People who've discussed this") {
                        Text(discussedBy.map(\.name).joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(Color.appTextSecondary)
                    }
                }
                Section("Oldest first") {
                    ForEach(timelinePoints) { point in
                        Button {
                            open(meetingId: point.meetingId)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(point.date.formatted(date: .abbreviated, time: .omitted))
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(Color.appAccent)
                                    Text(point.title)
                                        .font(.caption)
                                        .foregroundStyle(Color.appTextTertiary)
                                        .lineLimit(1)
                                    Spacer()
                                    if let stance = point.stance {
                                        Text(stance)
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(Color.appTextSecondary)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 1)
                                            .background(Color.appSurfaceSecondary.opacity(0.7))
                                            .clipShape(Capsule())
                                    }
                                }
                                Text(point.excerpt)
                                    .font(.caption)
                                    .foregroundStyle(Color.appTextSecondary)
                                    .lineLimit(3)
                                    .multilineTextAlignment(.leading)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private func buildTimeline() async {
        let topic = query.trimmingCharacters(in: .whitespaces)
        guard topic.count >= 3 else { return }
        if let id = stanceRequestId { appState.interactiveAIBroker.cancel(id: id) }
        timelineTopic = topic
        showTimeline = true
        timelineLoading = true
        defer { timelineLoading = false }

        let all = (try? await appState.meetingRepository.allActiveMeetings()) ?? []
        var semantic: [(meetingId: String, text: String, score: Float)] = []
        if appState.ollamaService.inFlightCount == 0,
           let hits = try? await appState.embeddingService.topK(
               query: topic, k: 30, sourceTypes: ["transcriptChunk", "summary", "slide"]) {
            semantic = hits.compactMap { hit in hit.meetingId.map { ($0, hit.text, hit.score) } }
        }
        let fts = (try? await appState.transcriptRepository.searchAllMeetings(query: topic, limit: 20)) ?? []
        let points = TrajectoryBuilder.build(semanticHits: semantic, ftsHits: fts, meetings: all)
        timelinePoints = points
        guard !points.isEmpty else { return }

        // Optional stance pass — interactive, so it routes through the
        // broker (review m5) and the timeline renders unlabeled meanwhile.
        guard let textGen = await appState.makeTextGenerator(
            maxOutputTokens: 600,
            schemaJSON: TrajectoryBuilder.stanceSchemaJSON,
            activityLabel: "Labeling timeline stances"
        ) else { return }
        let requestId = UUID()
        stanceRequestId = requestId
        let topicCopy = topic
        appState.interactiveAIBroker.submit(id: requestId, label: "Timeline: \(String(topic.prefix(40)))") {
            let response = (try? await textGen(
                TrajectoryBuilder.stanceSystemPrompt,
                TrajectoryBuilder.stanceUserPrompt(topic: topicCopy, points: points))) ?? ""
            await MainActor.run {
                guard self.timelineTopic == topicCopy, self.showTimeline else { return }
                self.timelinePoints = TrajectoryBuilder.applyStances(response, to: self.timelinePoints)
            }
        }
    }

    private func resultRow(icon: String, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.subheadline)
                    .foregroundStyle(Color.appAccent)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.subheadline)
                        .foregroundStyle(Color.appTextPrimary)
                        .lineLimit(1)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(Color.appTextTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// "Unreviewed · Decided by Jordan · Standup · Jul 3" — owner, meeting, and
    /// date, prefixed with the triage state for a suggested row.
    private func decisionSubtitle(_ decision: Decision, meetingTitle: String?) -> String {
        var parts: [String] = []
        if decision.isSuggested { parts.append("Unreviewed") }
        if let owner = decision.ownerName, !owner.isEmpty { parts.append("Decided by \(owner)") }
        if let target = decision.targetName, !target.isEmpty { parts.append("For \(target)") }
        if let title = meetingTitle, !title.isEmpty { parts.append(title) }
        parts.append(decision.extractedAt.formatted(date: .abbreviated, time: .omitted))
        return parts.joined(separator: " · ")
    }

    private func open(meetingId: String) {
        appState.sidebarDestination = .meetings
        appState.selectedMeetingId = meetingId
        dismiss()
    }

    private func openFirstHit() {
        if let m = titleHits.first { open(meetingId: m.id); return }
        if let t = transcriptHits.first { open(meetingId: t.meeting.id) }
    }

    private func runSearch(_ raw: String) async {
        let q = raw.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else {
            titleHits = []; transcriptHits = []; peopleHits = []; itemHits = []
            decisionHits = []
            return
        }
        let lowered = q.lowercased()

        let all = (try? await appState.meetingRepository.allActiveMeetings()) ?? []
        let titles = all.filter { $0.title.lowercased().contains(lowered) }.prefix(6)

        var transcripts: [(Meeting, String)] = []
        if let hits = try? await appState.transcriptRepository.searchAllMeetings(query: q) {
            let byId = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
            transcripts = hits.compactMap { hit in
                byId[hit.meetingId].map { ($0, hit.snippet) }
            }
        }

        let people = ((try? await PersonRepository(database: AppDatabase.shared).allPersons()) ?? [])
            .filter { $0.canonicalName.lowercased().contains(lowered)
                   || $0.aliases.contains { $0.lowercased().contains(lowered) } }
            .prefix(5)

        let openItems = ((try? await TaskRepository(database: AppDatabase.shared).allOpenItems(limit: 100)) ?? [])
            .filter { $0.title.lowercased().contains(lowered)
                   || ($0.assignee?.lowercased().contains(lowered) ?? false) }
            .prefix(5)
        let titlesById = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0.title) })

        titleHits = Array(titles)
        transcriptHits = transcripts.map { (meeting: $0.0, snippet: $0.1) }
        peopleHits = Array(people)
        itemHits = openItems.map { item in (item: item, meetingTitle: item.meetingId.flatMap { titlesById[$0] }) }
        glossaryHits = ((try? await GlossaryRepository(database: AppDatabase.shared).visibleTerms()) ?? [])
            .filter { $0.term.lowercased().contains(lowered) || $0.definition.lowercased().contains(lowered) }
            .prefix(4).map { $0 }
        slideHits = ((try? await MeetingSlideRepository(database: AppDatabase.shared)
            .search(query: q)) ?? [])
            .map { (slide: $0, meetingTitle: titlesById[$0.meetingId]) }

        // TASK-129: decision recall. `allDecisions` excludes dismissed rows
        // (dismissedAt set) — confirmed + suggested remain. Match title /
        // rationale / owner / involved, in-memory over the 500 cap.
        decisionHits = ((try? await DecisionRepository(database: appState.database)
            .allDecisions()) ?? [])
            .filter { d in
                d.title.lowercased().contains(lowered)
                    || (d.rationale?.lowercased().contains(lowered) ?? false)
                    || (d.ownerName?.lowercased().contains(lowered) ?? false)
                    || d.involvedNames.contains { $0.lowercased().contains(lowered) }
            }
            .prefix(6)
            .map { (decision: $0, meetingTitle: titlesById[$0.meetingId]) }

        // TASK-060: semantic person-affinity. Skipped when the local model
        // is mid-generation — a type-ahead must not queue behind a summary
        // (the FTS sections above already rendered).
        discussedBy = []
        if q.count >= 3,
           appState.ollamaService.inFlightCount == 0,
           let semanticHits = try? await appState.embeddingService.topK(
               query: q, k: 12, sourceTypes: ["transcriptChunk", "summary", "slide"]) {
            guard !Task.isCancelled else { return }
            discussedBy = PersonTopicAffinity.rank(
                hits: semanticHits.compactMap { hit in hit.meetingId.map { ($0, hit.score) } },
                meetings: all,
                excludingSelf: ProcessInfo.processInfo.fullUserName)
        }
    }
}

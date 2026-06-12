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
    @State private var itemHits: [(item: ActionItem, meetingTitle: String?)] = []
    @State private var discussedBy: [PersonTopicAffinity.Ranked] = []
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var fieldFocused: Bool

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

            if query.trimmingCharacters(in: .whitespaces).count < 2 {
                Spacer()
                Text("Type at least two characters to search.")
                    .font(.subheadline)
                    .foregroundStyle(Color.appTextTertiary)
                Spacer()
            } else if titleHits.isEmpty && transcriptHits.isEmpty && peopleHits.isEmpty && itemHits.isEmpty && discussedBy.isEmpty {
                Spacer()
                Text("No matches for \"\(query)\".")
                    .font(.subheadline)
                    .foregroundStyle(Color.appTextTertiary)
                Spacer()
            } else {
                List {
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
                                    open(meetingId: hit.item.meetingId)
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
        .onChange(of: query) { _, newValue in
            searchTask?.cancel()
            searchTask = Task {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                await runSearch(newValue)
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

        let openItems = ((try? await ActionItemRepository(database: AppDatabase.shared).allOpenItems(limit: 100)) ?? [])
            .filter { $0.title.lowercased().contains(lowered)
                   || ($0.assignee?.lowercased().contains(lowered) ?? false) }
            .prefix(5)
        let titlesById = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0.title) })

        titleHits = Array(titles)
        transcriptHits = transcripts.map { (meeting: $0.0, snippet: $0.1) }
        peopleHits = Array(people)
        itemHits = openItems.map { (item: $0, meetingTitle: titlesById[$0.meetingId]) }

        // TASK-060: semantic person-affinity. Skipped when the local model
        // is mid-generation — a type-ahead must not queue behind a summary
        // (the FTS sections above already rendered).
        discussedBy = []
        if q.count >= 3,
           appState.ollamaService.inFlightCount == 0,
           let semanticHits = try? await appState.embeddingService.topK(
               query: q, k: 12, sourceTypes: ["transcriptChunk", "summary"]) {
            guard !Task.isCancelled else { return }
            discussedBy = PersonTopicAffinity.rank(
                hits: semanticHits.compactMap { hit in hit.meetingId.map { ($0, hit.score) } },
                meetings: all,
                excludingSelf: ProcessInfo.processInfo.fullUserName)
        }
    }
}

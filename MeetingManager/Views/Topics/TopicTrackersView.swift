import SwiftUI

/// Topic trackers (TASK-081): define a topic once, see it counted across
/// meetings, jump to where it came up. Create / edit / delete; counts +
/// recent hits. Keyword matching is deterministic and offline.
struct TopicTrackersView: View {
    @Environment(AppState.self) private var appState

    @State private var trackers: [TopicTracker] = []
    @State private var counts: [Int64: (total: Int, recent: Int)] = [:]
    @State private var newName = ""
    @State private var newKeywords = ""
    @State private var editingId: Int64?
    @State private var expandedId: Int64?
    @State private var hits: [Int64: [TopicTrackerHit]] = [:]
    @State private var isLoading = true
    @State private var errorMessage: String?

    private var meetingsById: [String: Meeting] {
        Dictionary(appState.meetings.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Topics")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Color.appTextPrimary)
                Spacer()
            }
            .padding(.horizontal, 24).padding(.vertical, 16)
            Divider().background(Color.appSeparator)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    editorCard
                    if isLoading {
                        ProgressView().padding()
                    } else if trackers.isEmpty {
                        Text("No topics yet. Add one above — for example \"pricing\" or \"renewal\" — and Meeting Manager will count and surface where it comes up across your meetings.")
                            .font(.subheadline)
                            .foregroundStyle(Color.appTextTertiary)
                            .frame(maxWidth: 460, alignment: .leading)
                    } else {
                        ForEach(trackers) { tracker in
                            trackerRow(tracker)
                        }
                    }
                }
                .padding(20)
            }
        }
        .background(Color.appBackground)
        .task { await load() }
        .alert("Couldn't Save Topic", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var editorCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(editingId == nil ? "New topic" : "Edit topic")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.appAccent)
            TextField("Name (e.g. Pricing)", text: $newName)
                .textFieldStyle(.roundedBorder)
            TextField("Keywords, comma-separated (e.g. price, pricing, discount)", text: $newKeywords)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button(editingId == nil ? "Add topic" : "Save changes") { commit() }
                    .disabled(!canCommit)
                if editingId != nil {
                    Button("Cancel") { resetEditor() }
                }
                Spacer()
            }
        }
        .padding(14)
        .background(Color.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: 520, alignment: .leading)
    }

    private var canCommit: Bool {
        let kws = parseKeywords(newKeywords)
        return !newName.trimmingCharacters(in: .whitespaces).isEmpty
            && TopicMatcher.isValid(keywords: kws, semanticSeed: nil)
    }

    @ViewBuilder
    private func trackerRow(_ tracker: TopicTracker) -> some View {
        let id = tracker.id ?? -1
        let c = counts[id] ?? (0, 0)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    toggleExpand(tracker)
                } label: {
                    Image(systemName: expandedId == id ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(Color.appTextTertiary)
                }
                .buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 1) {
                    Text(tracker.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.appTextPrimary)
                    Text(tracker.keywordList.joined(separator: ", "))
                        .font(.caption2)
                        .foregroundStyle(Color.appTextTertiary)
                        .lineLimit(1)
                }
                Spacer()
                Text("\(c.total) meeting\(c.total == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)
                if c.recent > 0 {
                    Text("+\(c.recent) this week")
                        .font(.caption2)
                        .foregroundStyle(Color.appAccent)
                }
                Button { startEdit(tracker) } label: {
                    Image(systemName: "pencil").foregroundStyle(Color.appTextTertiary)
                }.buttonStyle(.plain)
                Button { delete(tracker) } label: {
                    Image(systemName: "trash").foregroundStyle(Color.appTextTertiary)
                }.buttonStyle(.plain)
            }
            if expandedId == id {
                ForEach(hits[id] ?? []) { hit in
                    Button { open(hit) } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "play.circle").foregroundStyle(Color.appAccent)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(hit.snippet)
                                    .font(.caption)
                                    .foregroundStyle(Color.appTextSecondary)
                                    .lineLimit(2)
                                Text(meetingsById[hit.meetingId]?.title ?? "Meeting")
                                    .font(.caption2)
                                    .foregroundStyle(Color.appTextTertiary)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 20)
                }
                if (hits[id] ?? []).isEmpty {
                    Text("No mentions yet.")
                        .font(.caption2)
                        .foregroundStyle(Color.appTextTertiary)
                        .padding(.leading, 20)
                }
            }
        }
        .padding(12)
        .background(Color.appSurfaceSecondary.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Actions

    private func parseKeywords(_ raw: String) -> [String] {
        raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func commit() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        let kws = parseKeywords(newKeywords)
        guard TopicMatcher.isValid(keywords: kws, semanticSeed: nil) else { return }
        let repo = TopicTrackerRepository(database: appState.database)
        Task {
            do {
                if let id = editingId {
                    try await repo.updateKeywords(id: id, name: name, keywords: kws, semanticSeed: nil)
                } else {
                    try await repo.save(TopicTracker(id: nil, name: name,
                                                      keywords: TopicTracker.encode(keywords: kws),
                                                      semanticSeed: nil, createdAt: Date(), hiddenAt: nil))
                }
            } catch {
                errorMessage = error.localizedDescription
                return
            }
            resetEditor()
            await load()
            await appState.enqueueTopicBackfill()   // scan history for the new/edited topic
        }
    }

    private func startEdit(_ tracker: TopicTracker) {
        editingId = tracker.id
        newName = tracker.name
        newKeywords = tracker.keywordList.joined(separator: ", ")
    }

    private func resetEditor() {
        editingId = nil; newName = ""; newKeywords = ""
    }

    private func delete(_ tracker: TopicTracker) {
        guard let id = tracker.id else { return }
        Task {
            do {
                try await TopicTrackerRepository(database: appState.database).hide(id: id)
            } catch {
                errorMessage = error.localizedDescription
                return
            }
            await load()
        }
    }

    private func toggleExpand(_ tracker: TopicTracker) {
        guard let id = tracker.id else { return }
        if expandedId == id { expandedId = nil; return }
        expandedId = id
        Task {
            hits[id] = (try? await TopicTrackerRepository(database: appState.database).hits(trackerId: id)) ?? []
        }
    }

    private func open(_ hit: TopicTrackerHit) {
        if let at = hit.atSeconds {
            appState.pendingPlaybackRange = (hit.meetingId, at, at)   // seek-only
        }
        appState.selectedMeetingId = hit.meetingId
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        let repo = TopicTrackerRepository(database: appState.database)
        trackers = (try? await repo.activeTrackers()) ?? []
        let weekAgo = Date().addingTimeInterval(-7 * 86_400)
        var newCounts: [Int64: (Int, Int)] = [:]
        for t in trackers {
            guard let id = t.id else { continue }
            let total = (try? await repo.hitCount(trackerId: id)) ?? 0
            let recent = (try? await repo.recentHitCount(trackerId: id, since: weekAgo)) ?? 0
            newCounts[id] = (total, recent)
        }
        counts = newCounts
    }
}

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
    @State private var loadingHits: Set<Int64> = []
    @State private var scanningIds: Set<Int64> = []
    @State private var pendingDelete: TopicTracker?
    @State private var isLoading = true
    @State private var errorMessage: String?

    /// TASK-094 (REQ-7): cap inline hits so one busy topic doesn't render an
    /// endless list. The repo still fetches up to its own limit; we show the
    /// most recent `hitDisplayCap` and surface the remainder as "+M more".
    private static let hitDisplayCap = 10

    private let editorAnchor = "topic-editor"

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

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        editorCard.id(editorAnchor)
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
                .onChange(of: editScrollTrigger) {
                    withAnimation { proxy.scrollTo(editorAnchor, anchor: .top) }
                }
            }
        }
        .background(Color.appBackground)
        .task { await load() }
        // TASK-094 (REQ-2): a just-added/edited topic kicks off a background
        // history scan; AppState bumps this token once the scan fully completes
        // (after any rerun for a topic added mid-pass). Refresh counts/hits and
        // drop the "Scanning…" affordance.
        .onChange(of: appState.topicBackfillToken) {
            Task {
                await load()
                scanningIds.removeAll()
                if let id = expandedId { await reloadHits(id) }
            }
        }
        .alert("Couldn't Save Topic", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog(
            "Delete this topic?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { tracker in
            Button("Delete Topic", role: .destructive) { delete(tracker) }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { tracker in
            Text("“\(tracker.name)” and its tracked mentions will be removed. This can't be undone.")
        }
    }

    /// Flips whenever an edit starts, to scroll the editor into view (REQ-3).
    @State private var editScrollTrigger = 0

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
        let isScanning = scanningIds.contains(id)
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
                .accessibilityLabel(expandedId == id ? "Collapse topic \(tracker.name)" : "Expand topic \(tracker.name)")
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
                if isScanning {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.small)
                        Text("Scanning your history…")
                            .font(.caption)
                            .foregroundStyle(Color.appTextSecondary)
                    }
                } else {
                    Text("\(c.total) meeting\(c.total == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(Color.appTextSecondary)
                    if c.recent > 0 {
                        Text("+\(c.recent) this week")
                            .font(.caption2)
                            .foregroundStyle(Color.appAccent)
                    }
                }
                Button { startEdit(tracker) } label: {
                    Image(systemName: "pencil").foregroundStyle(Color.appTextTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Edit topic \(tracker.name)")
                Button { pendingDelete = tracker } label: {
                    Image(systemName: "trash").foregroundStyle(Color.appTextTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete topic \(tracker.name)")
            }
            if expandedId == id {
                expandedHits(id)
            }
        }
        .padding(12)
        .background(Color.appSurfaceSecondary.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func expandedHits(_ id: Int64) -> some View {
        if loadingHits.contains(id) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading mentions…")
                    .font(.caption2)
                    .foregroundStyle(Color.appTextTertiary)
            }
            .padding(.leading, 20)
        } else {
            let all = hits[id] ?? []
            if all.isEmpty {
                Text("No mentions yet.")
                    .font(.caption2)
                    .foregroundStyle(Color.appTextTertiary)
                    .padding(.leading, 20)
            } else {
                let shown = min(all.count, Self.hitDisplayCap)
                ForEach(all.prefix(Self.hitDisplayCap)) { hit in
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
                    .accessibilityLabel("Play this mention in \(meetingsById[hit.meetingId]?.title ?? "the meeting")")
                }
                // REQ-7: the overflow reflects the true lifetime total (the
                // unbounded hitCount in `counts`), not the capped fetch window,
                // so a topic with >50 mentions doesn't top out at "+40 more".
                if let overflow = Self.overflowCount(total: counts[id]?.total ?? all.count, shown: shown) {
                    Text("+\(overflow) more")
                        .font(.caption2)
                        .foregroundStyle(Color.appTextTertiary)
                        .padding(.leading, 20)
                }
            }
        }
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
        let editedId = editingId
        Task {
            let savedId: Int64?
            do {
                if let id = editedId {
                    try await repo.updateKeywords(id: id, name: name, keywords: kws, semanticSeed: nil)
                    savedId = id
                } else {
                    let saved = try await repo.save(TopicTracker(id: nil, name: name,
                                                                 keywords: TopicTracker.encode(keywords: kws),
                                                                 semanticSeed: nil, createdAt: Date(), hiddenAt: nil))
                    savedId = saved.id
                }
            } catch {
                errorMessage = error.localizedDescription
                return
            }
            resetEditor()
            await load()
            if let savedId { scanningIds.insert(savedId) }   // REQ-2: show "Scanning…" until backfill posts
            await appState.enqueueTopicBackfill()             // scan history for the new/edited topic
        }
    }

    private func startEdit(_ tracker: TopicTracker) {
        editingId = tracker.id
        newName = tracker.name
        newKeywords = tracker.keywordList.joined(separator: ", ")
        editScrollTrigger &+= 1   // REQ-3: bring the populated editor into view
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
        Task { await reloadHits(id) }
    }

    /// REQ-1: track the in-flight fetch so the row shows a loading state and
    /// "No mentions yet" appears only after a completed zero-hit fetch.
    private func reloadHits(_ id: Int64) async {
        loadingHits.insert(id)
        defer { loadingHits.remove(id) }
        hits[id] = (try? await TopicTrackerRepository(database: appState.database).hits(trackerId: id)) ?? []
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

    /// REQ-7: remaining hits beyond the inline cap, or nil when none overflow. Pure.
    static func overflowCount(total: Int, shown: Int) -> Int? {
        total > shown ? total - shown : nil
    }
}

import SwiftUI

/// Global "Key Quotes" — every saved clip across all meetings (TASK-078),
/// newest first, grouped by meeting. Each row shows the quote, speaker,
/// and timestamp; play cues the clip in its meeting's player; an inline
/// note is editable. No sharing/export (scope).
struct KeyQuotesView: View {
    @Environment(AppState.self) private var appState
    @State private var clips: [Clip] = []
    @State private var searchText = ""
    @State private var pendingDelete: Clip?
    @State private var isLoading = true
    @State private var errorMessage: String?

    /// REQ-6: only surface the filter once the list is big enough to need it.
    private static let filterThreshold = 8

    private var meetingsById: [String: Meeting] {
        Dictionary(appState.meetings.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private var filteredClips: [Clip] {
        Self.filter(clips, query: searchText, titleFor: { meetingsById[$0]?.title })
    }

    /// Clips grouped by meeting, newest meeting first.
    private var grouped: [(meeting: Meeting?, meetingId: String, clips: [Clip])] {
        let byMeeting = Dictionary(grouping: filteredClips, by: \.meetingId)
        return byMeeting
            .map { (meetingsById[$0.key], $0.key, $0.value.sorted { $0.startTime < $1.startTime }) }
            .sorted { ($0.meeting?.effectiveDate ?? .distantPast) > ($1.meeting?.effectiveDate ?? .distantPast) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Key Quotes")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Color.appTextPrimary)
                Spacer()
                if !clips.isEmpty {
                    Text("\(clips.count) saved")
                        .font(.caption)
                        .foregroundStyle(Color.appTextSecondary)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            Divider().background(Color.appSeparator)

            if isLoading && clips.isEmpty {
                Spacer(); ProgressView(); Spacer()
            } else if clips.isEmpty {
                emptyState
            } else {
                if clips.count >= Self.filterThreshold {
                    filterField
                }
                if filteredClips.isEmpty {
                    noMatchesState
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            ForEach(grouped, id: \.meetingId) { group in
                                quoteGroup(group)
                            }
                        }
                        .padding(20)
                    }
                }
            }
        }
        .background(Color.appBackground)
        .task { await load() }
        // A quote saved from a meeting's transcript should appear without a
        // relaunch. The spinner is gated on first load (clips empty) so a tab
        // switch doesn't flash it; `.task` + `.onAppear` both fire on first
        // appearance, but `load()` is idempotent (one harmless extra load).
        .onAppear { Task { await load() } }
        .alert("Couldn't Update Quote", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog(
            "Delete this quote?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { clip in
            Button("Delete Quote", role: .destructive) { delete(clip) }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { _ in
            Text("This saved quote will be removed. This can't be undone.")
        }
    }

    private var filterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.appTextTertiary)
            TextField("Filter by quote, speaker, or meeting", text: $searchText)
                .textFieldStyle(.plain)
                .accessibilityLabel("Filter key quotes")
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.appTextTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear filter")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.appSurfaceSecondary.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    private var noMatchesState: some View {
        VStack(spacing: 6) {
            Spacer()
            Text("No quotes match your filter")
                .font(.subheadline)
                .foregroundStyle(Color.appTextSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "quote.bubble")
                .font(.system(size: 44))
                .foregroundStyle(Color.appTextTertiary)
            Text("No key quotes yet")
                .font(.title3)
                .foregroundStyle(Color.appTextSecondary)
            Text("In a meeting's transcript, right-click a line and choose \"Save as Key Quote\" to keep and replay it here.")
                .font(.subheadline)
                .foregroundStyle(Color.appTextTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func quoteGroup(_ group: (meeting: Meeting?, meetingId: String, clips: [Clip])) -> some View {
        let hasAudio = !(group.meeting?.audioFilePaths.isEmpty ?? true)
        VStack(alignment: .leading, spacing: 8) {
            Button {
                appState.selectedMeetingId = group.meetingId
            } label: {
                HStack(spacing: 6) {
                    Text(group.meeting?.title ?? "Meeting")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.appAccent)
                    if let date = group.meeting?.effectiveDate {
                        Text(date.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption)
                            .foregroundStyle(Color.appTextTertiary)
                    }
                }
            }
            .buttonStyle(.plain)

            ForEach(group.clips) { clip in
                QuoteRow(clip: clip,
                         hasAudio: hasAudio,
                         onPlay: { open(clip) },
                         onDelete: { pendingDelete = clip },
                         onNote: { note in saveNote(clip, note: note) })
            }
        }
    }

    private func open(_ clip: Clip) {
        appState.pendingPlaybackRange = (clip.meetingId, clip.startTime, clip.endTime)
        appState.selectedMeetingId = clip.meetingId
    }

    private func delete(_ clip: Clip) {
        guard let id = clip.id else { return }
        Task {
            do {
                try await ClipRepository(database: appState.database).delete(id: id)
                clips.removeAll { $0.id == id }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func saveNote(_ clip: Clip, note: String) {
        guard let id = clip.id else { return }
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                try await ClipRepository(database: appState.database).updateNote(id: id, note: trimmed.isEmpty ? nil : trimmed)
                if let idx = clips.firstIndex(where: { $0.id == id }) {
                    clips[idx].note = trimmed.isEmpty ? nil : trimmed
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        clips = (try? await ClipRepository(database: appState.database).allClips()) ?? []
    }

    /// REQ-6: case-insensitive match on quote text, speaker labels, or the
    /// clip's meeting title. An empty/whitespace query passes everything. Pure.
    static func filter(_ clips: [Clip], query: String, titleFor: (String) -> String?) -> [Clip] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return clips }
        return clips.filter { clip in
            if clip.quoteText.lowercased().contains(needle) { return true }
            if let s = clip.speakerLabels, s.lowercased().contains(needle) { return true }
            if let t = titleFor(clip.meetingId), t.lowercased().contains(needle) { return true }
            return false
        }
    }
}

/// One quote row with play, the quote + speaker/time, an inline note, and
/// delete.
private struct QuoteRow: View {
    let clip: Clip
    let hasAudio: Bool
    let onPlay: () -> Void
    let onDelete: () -> Void
    let onNote: (String) -> Void

    @State private var noteText: String = ""
    @State private var editingNote = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: onPlay) {
                Image(systemName: "play.circle")
                    .font(.title3)
                    .foregroundStyle(hasAudio ? Color.appAccent : Color.appTextTertiary)
            }
            .buttonStyle(.plain)
            .disabled(!hasAudio)
            .help(hasAudio ? "Open the meeting and play this quote" : "No audio available for this meeting")
            .accessibilityLabel(hasAudio ? "Play this quote" : "Play unavailable, no audio for this meeting")

            VStack(alignment: .leading, spacing: 3) {
                Text(clip.quoteText)
                    .font(.callout)
                    .foregroundStyle(Color.appTextPrimary)
                    .textSelection(.enabled)
                Text("\(clip.speakerLabels.map { "\($0) · " } ?? "")\(clip.timestampLabel)")
                    .font(.caption2)
                    .foregroundStyle(Color.appTextTertiary)

                if editingNote {
                    HStack(spacing: 6) {
                        TextField("Note", text: $noteText)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption)
                            .onSubmit { commitNote() }
                            .onExitCommand { cancelNote() }   // REQ-8: Escape cancels
                        Button("Save") { commitNote() }
                            .font(.caption)
                            .accessibilityLabel("Save note")
                        Button("Cancel") { cancelNote() }
                            .font(.caption)
                            .accessibilityLabel("Cancel note edit")
                    }
                } else if let note = clip.note, !note.isEmpty {
                    Button { startEditing() } label: {
                        Label(note, systemImage: "note.text")
                            .font(.caption)
                            .foregroundStyle(Color.appTextSecondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Edit note")
                } else {
                    Button { startEditing() } label: {
                        Label("Add note", systemImage: "plus.circle")
                            .font(.caption2)
                            .foregroundStyle(Color.appTextTertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add note")
                }
            }
            Spacer(minLength: 0)
            Button(action: onDelete) {
                Image(systemName: "xmark.circle")
                    .foregroundStyle(Color.appTextTertiary)
            }
            .buttonStyle(.plain)
            .help("Delete this quote")
            .accessibilityLabel("Delete this quote")
        }
        .padding(10)
        .background(Color.appSurfaceSecondary.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func startEditing() {
        noteText = clip.note ?? ""
        editingNote = true
    }

    private func commitNote() {
        onNote(noteText)
        editingNote = false
    }

    private func cancelNote() {
        noteText = clip.note ?? ""
        editingNote = false
    }
}

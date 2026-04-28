import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

struct FullTranscriptView: View {
    let meetingId: String

    @Environment(AppState.self) private var appState
    @State private var transcripts: [Transcript] = []
    @State private var meeting: Meeting?
    @State private var searchQuery: String = ""
    @State private var isLoading = true
    @State private var filteredTranscripts: [Transcript] = []
    @State private var speakerToCustomRename: Transcript?
    @State private var renameError: String?

    private let exportService = ExportService()

    var body: some View {
        VStack(spacing: 0) {
            // Search bar and export button
            HStack(spacing: 12) {
                SearchBar(query: $searchQuery, placeholder: "Search transcript...")

                CopyButton(
                    text: { formatTranscriptText() },
                    label: "Copy Transcript"
                )
                .disabled(transcripts.isEmpty)

                CopyButton(
                    text: { formatTranscriptMarkdown() },
                    label: "Copy as Markdown"
                )
                .disabled(transcripts.isEmpty)

                Button {
                    Task { await exportTranscript() }
                } label: {
                    Label("Export Transcript", systemImage: "square.and.arrow.up")
                        .font(.caption)
                        .fontWeight(.medium)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(transcripts.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()
                .foregroundStyle(Color.appSeparator)

            if isLoading {
                Spacer()
                ProgressView()
                Spacer()
            } else if transcripts.isEmpty {
                Spacer()
                EmptyStateView(
                    icon: "text.quote",
                    title: "No Transcript",
                    subtitle: "The transcript will appear here once the meeting recording is processed."
                )
                Spacer()
            } else if filteredTranscripts.isEmpty {
                Spacer()
                EmptyStateView(
                    icon: "magnifyingglass",
                    title: "No Results",
                    subtitle: "No transcript segments match \"\(searchQuery)\". Try different search terms."
                )
                Spacer()
            } else {
                transcriptList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            meeting = try? await appState.meetingRepository.find(id: meetingId)
            await loadTranscripts()
            updateFilteredTranscripts()
        }
        .onChange(of: searchQuery) { _, _ in updateFilteredTranscripts() }
        .onChange(of: transcripts) { _, _ in updateFilteredTranscripts() }
        .sheet(item: $speakerToCustomRename) { transcript in
            CustomSpeakerNameSheet(
                currentName: transcript.displayedSpeakerName(
                    meeting: meeting,
                    userDisplayName: NSFullUserName()
                )
            ) { newName in
                renameSpeaker(transcript: transcript, newName: newName)
            }
        }
        .alert("Rename Failed", isPresented: Binding(
            get: { renameError != nil },
            set: { if !$0 { renameError = nil } }
        )) {
            Button("OK", role: .cancel) { renameError = nil }
        } message: {
            Text(renameError ?? "")
        }
    }

    // MARK: - Transcript List

    private var transcriptList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(filteredTranscripts) { transcript in
                    TranscriptBubble(
                        transcript: transcript,
                        meeting: meeting,
                        onRename: { action in
                            handleRenameAction(action, for: transcript)
                        },
                        isAIAttributed: isAIAttributed(transcript)
                    )

                    if transcript.id != filteredTranscripts.last?.id {
                        Divider()
                            .foregroundStyle(Color.appSeparator.opacity(0.5))
                            .padding(.leading, 66)
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }

    // MARK: - Rename

    /// True when the transcript's `speakerLabel` was assigned by the LLM
    /// (i.e. the meeting's `speakerMap` contains the cluster id as a key OR
    /// the resolved name as a value). Per the v3.1 plan we keep this purely
    /// in-memory for ship — once the user clicks rename the local
    /// `meeting.speakerMap` no longer reflects an unconfirmed mapping after
    /// the upsert path completes the next reload.
    private func isAIAttributed(_ transcript: Transcript) -> Bool {
        guard let label = transcript.speakerLabel,
              let map = meeting?.speakerMapDictionary,
              !map.isEmpty else { return false }
        // The label may be the cluster id (pre-Layer-2 rewrite) OR the mapped
        // name (post-rewrite). Match either side.
        if map.keys.contains(label) { return true }
        if map.values.contains(label) { return true }
        return false
    }

    private func handleRenameAction(_ action: TranscriptBubbleRenameAction,
                                    for transcript: Transcript) {
        switch action {
        case .assign(let name):
            renameSpeaker(transcript: transcript, newName: name)
        case .custom:
            speakerToCustomRename = transcript
        }
    }

    private func renameSpeaker(transcript: Transcript, newName: String) {
        Task { @MainActor in
            guard let meeting else { return }
            let clusterId = transcript.speakerLabel ?? ""
            guard !clusterId.isEmpty else { return }
            let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != clusterId else { return }

            // 1. Bulk-rename every transcript in this meeting where speakerLabel == clusterId.
            do {
                try await appState.transcriptRepository.updateSpeakerLabel(
                    meetingId: meeting.id,
                    from: clusterId,
                    to: trimmed
                )
            } catch {
                renameError = error.localizedDescription
                return
            }

            // 2. Persist the new mapping on the meeting.
            var updated = meeting
            var map = updated.speakerMapDictionary
            map[clusterId] = trimmed
            updated.setSpeakerMap(map)
            do {
                try await appState.meetingRepository.update(updated)
                self.meeting = updated
            } catch {
                // Non-fatal — the transcripts are already renamed; the alias
                // upsert below still records the user's intent for future
                // meetings in the series.
                renameError = error.localizedDescription
            }

            // 3. Remember for future meetings in the same series.
            let seriesKey = MeetingSeriesService.shared.seriesKey(for: meeting)
            try? await SpeakerAliasRepository(database: AppDatabase.shared)
                .upsert(seriesKey: seriesKey, clusterId: clusterId, resolvedName: trimmed)

            // 4. Reload to reflect the rewritten labels.
            await loadTranscripts()
            updateFilteredTranscripts()
        }
    }

    // MARK: - Filtering

    private func updateFilteredTranscripts() {
        if searchQuery.isEmpty {
            filteredTranscripts = transcripts
        } else {
            let userName = NSFullUserName()
            let m = meeting
            filteredTranscripts = transcripts.filter {
                $0.text.localizedCaseInsensitiveContains(searchQuery)
                || $0.displayedSpeakerName(meeting: m, userDisplayName: userName)
                    .localizedCaseInsensitiveContains(searchQuery)
            }
        }
    }

    // MARK: - Copy

    private func formatTranscriptText() -> String {
        let userName = NSFullUserName()
        let m = meeting
        return transcripts.map { transcript in
            let speaker = transcript.displayedSpeakerName(meeting: m, userDisplayName: userName)
            return "[\(transcript.formattedTimestamp)] \(speaker): \(transcript.text)"
        }.joined(separator: "\n\n")
    }

    private func formatTranscriptMarkdown() -> String {
        guard let meeting else { return formatTranscriptText() }
        return exportService.exportTranscriptText(meeting: meeting, transcripts: transcripts)
    }

    // MARK: - Export

    private func exportTranscript() async {
        guard let meeting else { return }
        let content = exportService.exportTranscriptText(meeting: meeting, transcripts: transcripts)
        let filename = ExportService.sanitizedFilename(from: meeting.title) + "-transcript.txt"
        _ = await exportService.saveToFile(content: content, suggestedName: filename, fileType: "txt")
    }

    // MARK: - Data Loading

    private func loadTranscripts() async {
        isLoading = true
        defer { isLoading = false }
        transcripts = (try? await appState.transcriptRepository.transcriptsForMeeting(meetingId)) ?? []
    }
}

// MARK: - Previews

// #Preview("With Transcripts") {
//     FullTranscriptView(meetingId: "preview-1")
//         .environment(AppState())
//         .frame(width: 600, height: 500)
//         .background(Color.appBackground)
// }

// #Preview("Empty") {
//     FullTranscriptView(meetingId: "no-transcript")
//         .environment(AppState())
//         .frame(width: 600, height: 500)
//         .background(Color.appBackground)
// }

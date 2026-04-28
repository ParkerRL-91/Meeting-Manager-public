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
    }

    // MARK: - Transcript List

    private var transcriptList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(filteredTranscripts) { transcript in
                    TranscriptBubble(transcript: transcript, meeting: meeting)

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

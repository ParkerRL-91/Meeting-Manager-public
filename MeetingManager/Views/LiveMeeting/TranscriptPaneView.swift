import SwiftUI
import GRDB

/// Left pane: scrollable list of live transcript segments with auto-scroll.
struct TranscriptPaneView: View {
    let meetingId: String
    @Environment(AppState.self) private var appState

    @State private var transcripts: [Transcript] = []
    @State private var observation: DatabaseCancellable?
    @State private var autoScrollEnabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "waveform")
                    .foregroundStyle(Color.appAccent)
                Text("Transcript")
                    .font(.headline)
                    .foregroundStyle(Color.appTextPrimary)
                Spacer()
                Text("\(transcripts.count) segments")
                    .font(.caption)
                    .foregroundStyle(Color.appTextTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // Transcript list
            if transcripts.isEmpty {
                listeningPlaceholder
            } else {
                transcriptList
            }
        }
        .background(Color.appBackground)
        .onAppear(perform: startObserving)
        .onDisappear(perform: stopObserving)
    }

    // MARK: - Subviews

    private var listeningPlaceholder: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "mic.fill")
                .font(.largeTitle)
                .foregroundStyle(Color.appTextTertiary)
            Text("Listening...")
                .font(.title3)
                .foregroundStyle(Color.appTextSecondary)
            Text("Transcript will appear here as people speak.")
                .font(.caption)
                .foregroundStyle(Color.appTextTertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var transcriptList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(transcripts) { segment in
                        TranscriptBubble(transcript: segment)
                            .id(segment.id)
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: transcripts.count) { _, _ in
                guard autoScrollEnabled, let lastId = transcripts.last?.id else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(lastId, anchor: .bottom)
                }
            }
        }
    }

    // MARK: - Observation

    private func startObserving() {
        observation = appState.transcriptRepository.observeTranscripts(
            meetingId: meetingId
        ) { updatedTranscripts in
            Task { @MainActor in
                self.transcripts = updatedTranscripts
            }
        }
    }

    private func stopObserving() {
        observation?.cancel()
        observation = nil
    }
}

// MARK: - Preview

#Preview {
    TranscriptPaneView(meetingId: "preview-123")
        .frame(width: 400, height: 500)
        .environment(AppState())
}

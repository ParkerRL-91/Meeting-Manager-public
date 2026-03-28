import SwiftUI

/// Flagship live meeting screen with split-screen layout:
/// recording controls on top, real-time transcript on the left, notepad on the right.
struct LiveMeetingView: View {
    let meetingId: String
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            RecordingControlBar(meetingId: meetingId)
            Divider()
            HSplitView {
                TranscriptPaneView(meetingId: meetingId)
                    .frame(minWidth: 300)
                NotepadPaneView(meetingId: meetingId)
                    .frame(minWidth: 250)
            }
        }
        .background(Color.appBackground)
        .frame(minWidth: 700, minHeight: 400)
    }
}

// MARK: - Preview

#Preview {
    LiveMeetingView(meetingId: "preview-123")
        .frame(width: 900, height: 600)
        .environment(AppState())
}

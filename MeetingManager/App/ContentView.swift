import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            detailView
        }
        .navigationSplitViewStyle(.balanced)
    }

    @ViewBuilder
    private var detailView: some View {
        if let meetingId = appState.selectedMeetingId {
            if appState.isRecording, appState.activeMeeting?.id == meetingId {
                LiveMeetingView(meetingId: meetingId)
                    .id(meetingId)
            } else {
                MeetingDetailView(meetingId: meetingId)
                    .id(meetingId)   // force view recreation so .task re-fires on selection change
            }
        } else {
            EmptyStateView(
                icon: "waveform.badge.mic",
                title: "No Meeting Selected",
                subtitle: "Select a meeting from the sidebar or start a new one"
            )
        }
    }
}

import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState

        // The model download status now lives as a slim footer inside the sidebar
        // (see SidebarView). Rendering it here pushed the entire NavigationSplitView
        // down and clipped sidebar nav items, which felt broken.
        NavigationSplitView {
            SidebarView()
        } detail: {
            detailView
        }
        .navigationSplitViewStyle(.balanced)
        .errorAlert($appState.lastUserError)
    }

    @ViewBuilder
    private var detailView: some View {
        switch appState.sidebarDestination {
        case .home:
            HomeView()

        case .dailyBrief:
            DailyBriefView()

        case .chat:
            GlobalChatView()

        case .people:
            PeopleView()

        case .tasks:
            TaskQueueView()

        case .search:
            MeetingSearchView()

        case .analytics:
            AnalyticsView()

        case .folder(let key):
            let folders = appState.meetingFolders()
            if let folder = folders.first(where: { $0.key == key }) {
                FolderDetailView(folder: folder)
                    .id(key)
            } else {
                HomeView()
            }

        case .meetings:
            meetingDetailView
        }
    }

    @ViewBuilder
    private var meetingDetailView: some View {
        if let meetingId = appState.selectedMeetingId {
            if appState.isRecording, appState.activeMeeting?.id == meetingId {
                LiveMeetingView(meetingId: meetingId)
                    .id(meetingId)
            } else {
                MeetingDetailView(meetingId: meetingId)
                    .id(meetingId)
            }
        } else {
            HomeView()
        }
    }
}

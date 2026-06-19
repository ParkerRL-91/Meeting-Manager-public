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
                // Explicit min/ideal/max so the sidebar divider is clearly
                // draggable and remembers a sensible width across launches.
                .navigationSplitViewColumnWidth(min: 180, ideal: 240, max: 360)
        } detail: {
            detailView
                .navigationSplitViewColumnWidth(min: 600, ideal: 900)
        }
        .navigationSplitViewStyle(.balanced)
        .errorAlert($appState.lastUserError)
        .sheet(isPresented: Binding(
            get: { !appState.recoverableDrafts.isEmpty },
            set: { presented in if !presented { appState.recoverableDrafts = [] } }
        )) {
            DraftRecoverySheet()
        }
        .sheet(isPresented: $appState.showGlobalSearch) {
            GlobalSearchView()
                .environment(appState)
        }
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

        case .activity:
            TaskQueueView()

        case .taskBoard:
            TaskManagerRootView()

        case .search:
            MeetingSearchView()

        case .analytics:
            AnalyticsView()

        case .keyQuotes:
            KeyQuotesView()

        case .topics:
            TopicTrackersView()

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

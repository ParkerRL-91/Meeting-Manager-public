import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState

        VStack(spacing: 0) {
            // Model download banner
            if appState.isLoadingModel {
                HStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.small)

                    Text("Downloading transcription model...")
                        .font(.subheadline)
                        .foregroundStyle(Color.appTextPrimary)

                    ProgressView(value: appState.modelDownloadProgress)
                        .progressViewStyle(.linear)
                        .tint(Color.appAccent)
                        .frame(maxWidth: 200)

                    Text("\(Int(appState.modelDownloadProgress * 100))%")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(Color.appTextSecondary)

                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.appAccent.opacity(0.08).background(Color.appSurface))
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            NavigationSplitView {
                SidebarView()
            } detail: {
                detailView
            }
            .navigationSplitViewStyle(.balanced)
        }
        .animation(.easeInOut(duration: 0.3), value: appState.isLoadingModel)
        .errorAlert($appState.lastUserError)
    }

    @ViewBuilder
    private var detailView: some View {
        switch appState.sidebarDestination {
        case .home:
            HomeView()

        case .chat:
            GlobalChatView()

        case .people:
            PeopleView()

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

import SwiftUI

struct SidebarView: View {
    @Environment(AppState.self) private var appState
    @State private var searchQuery = ""
    @State private var showArchived = false
    @State private var showAllActionItems = false
    @State private var errorMessage: String?
    @FocusState private var isSearchFocused: Bool

    private var filteredUpcoming: [Meeting] {
        let base = showArchived
            ? appState.upcomingMeetings
            : appState.upcomingMeetings.filter { $0.status != .archived }
        if searchQuery.isEmpty {
            return base
        }
        return base.filter {
            $0.title.localizedCaseInsensitiveContains(searchQuery)
        }
    }

    private var filteredPast: [Meeting] {
        let base = showArchived
            ? appState.pastMeetings
            : appState.pastMeetings.filter { $0.status != .archived }
        if searchQuery.isEmpty {
            return base
        }
        return base.filter {
            $0.title.localizedCaseInsensitiveContains(searchQuery)
        }
    }

    private var hasNoResults: Bool {
        !searchQuery.isEmpty && filteredUpcoming.isEmpty && filteredPast.isEmpty
    }

    private var hasNoMeetings: Bool {
        searchQuery.isEmpty && appState.upcomingMeetings.isEmpty && appState.pastMeetings.isEmpty
    }

    var body: some View {
        @Bindable var appState = appState

        VStack(spacing: 0) {
            // MARK: - Header

            VStack(spacing: 10) {
                Button {
                    createAdHocMeeting()
                } label: {
                    Label("New Meeting", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.appAccent)
                .controlSize(.large)

                SearchBar(query: $searchQuery, placeholder: "Search meetings...")
                    .focused($isSearchFocused)

                HStack {
                    Toggle(isOn: $showArchived) {
                        Label("Show Archived", systemImage: "archivebox")
                            .font(.subheadline)
                    }
                    .toggleStyle(.checkbox)

                    Spacer()

                    Button {
                        showAllActionItems = true
                    } label: {
                        Label("Action Items", systemImage: "checklist")
                            .font(.subheadline)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            // MARK: - Status Banners

            if appState.isRecording, let meeting = appState.activeMeeting {
                SidebarRecordingBar(meeting: meeting)
                Divider()
            } else if let callApp = appState.detectedCallApp {
                DetectedCallBanner(appName: callApp)
                Divider()
            }

            // MARK: - Meeting List

            if hasNoMeetings {
                Spacer()
                EmptyStateView(
                    icon: "calendar.badge.plus",
                    title: "No Meetings",
                    subtitle: "Start a new meeting or connect your calendar to see upcoming events."
                )
                .padding()
                Spacer()
            } else if hasNoResults {
                Spacer()
                EmptyStateView(
                    icon: "magnifyingglass",
                    title: "No Results",
                    subtitle: "No meetings match \"\(searchQuery)\". Try a different search term."
                )
                .padding()
                Spacer()
            } else {
                List(selection: $appState.selectedMeetingId) {
                    if !filteredUpcoming.isEmpty {
                        Section("Upcoming") {
                            ForEach(filteredUpcoming) { meeting in
                                MeetingListRow(meeting: meeting, onError: { errorMessage = $0 })
                                    .tag(meeting.id)
                                    .contextMenu {
                                        if meeting.status == .scheduled || meeting.status == .notified {
                                            Button {
                                                startEarly(meeting)
                                            } label: {
                                                Label("Start Early", systemImage: "play.fill")
                                            }
                                        }
                                    }
                            }
                        }
                    } else if searchQuery.isEmpty {
                        Section("Upcoming") {
                            Text("No upcoming meetings")
                                .font(.subheadline)
                                .foregroundStyle(Color.appTextSecondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 8)
                        }
                    }

                    if !filteredPast.isEmpty {
                        Section("Past") {
                            ForEach(filteredPast) { meeting in
                                MeetingListRow(meeting: meeting, onError: { errorMessage = $0 })
                                    .tag(meeting.id)
                            }
                        }
                    } else if searchQuery.isEmpty {
                        Section("Past") {
                            Text("No past meetings")
                                .font(.subheadline)
                                .foregroundStyle(Color.appTextSecondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 8)
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .background(Color.appBackground)
        .errorAlert($errorMessage)
        .sheet(isPresented: $showAllActionItems) {
            AllActionItemsView()
                .environment(appState)
                .frame(minWidth: 500, minHeight: 400)
        }
        .onAppear {
            appState.loadMeetings()
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusSearch)) { _ in
            isSearchFocused = true
        }
        // .createNewMeeting is handled by AppState — no need to observe here
    }

    // MARK: - Actions

    private func startEarly(_ meeting: Meeting) {
        appState.startRecording(for: meeting)
    }

    private func createAdHocMeeting() {
        // Post notification so AppState handles meeting creation + transcription start
        NotificationCenter.default.post(name: .createNewMeeting, object: nil)
    }
}

// MARK: - Sidebar Recording Bar

/// Compact recording indicator shown in the sidebar when a meeting is being recorded.
/// Visible even when the user navigates away from LiveMeetingView.
private struct SidebarRecordingBar: View {
    let meeting: Meeting
    @Environment(AppState.self) private var appState
    @State private var elapsedSeconds: Int = 0
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.appRecording)
                .frame(width: 8, height: 8)
                .opacity(pulse ? 0.3 : 1.0)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
                .onAppear { pulse = true }

            VStack(alignment: .leading, spacing: 1) {
                Text("Recording")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.appRecording)
                Text(formattedElapsed)
                    .font(.caption2.monospaced())
                    .foregroundStyle(Color.appTextSecondary)
            }

            Spacer()

            Button {
                appState.stopRecording()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Color.appRecording)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .help("Stop Recording")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.appRecording.opacity(0.08))
        .onAppear(perform: startTimer)
        .onDisappear(perform: stopTimer)
    }

    @State private var timer: Timer?

    private var formattedElapsed: String {
        let h = elapsedSeconds / 3600
        let m = (elapsedSeconds % 3600) / 60
        let s = elapsedSeconds % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }

    private func startTimer() {
        updateElapsed()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            updateElapsed()
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func updateElapsed() {
        guard let start = meeting.startDate else { elapsedSeconds = 0; return }
        elapsedSeconds = max(0, Int(Date().timeIntervalSince(start)))
    }
}

// MARK: - Detected Call Banner

/// Shown when a call app is running but recording hasn't started (manual-start mode).
private struct DetectedCallBanner: View {
    let appName: String
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "video.fill")
                .font(.caption)
                .foregroundStyle(Color.appAccent)

            VStack(alignment: .leading, spacing: 1) {
                Text("\(appName) detected")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.appTextPrimary)
                Text("Tap to begin recording")
                    .font(.caption2)
                    .foregroundStyle(Color.appTextSecondary)
            }

            Spacer()

            Button("Record") {
                NotificationCenter.default.post(name: .startRecording, object: nil)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.appAccent)
            .controlSize(.mini)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.appAccent.opacity(0.08))
    }
}

// MARK: - Previews

// #Preview("With Meetings") {
//     SidebarView()
//         .environment(AppState())
//         .frame(width: 300, height: 600)
// }

// #Preview("Empty State") {
//     SidebarView()
//         .environment(AppState())
//         .frame(width: 300, height: 600)
// }

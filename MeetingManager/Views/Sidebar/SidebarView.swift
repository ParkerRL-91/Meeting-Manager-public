import SwiftUI

struct SidebarView: View {
    @Environment(AppState.self) private var appState
    @State private var searchQuery = ""
    @State private var showArchived = false
    @State private var showAllActionItems = false
    @State private var errorMessage: String?
    @FocusState private var isSearchFocused: Bool
    @State private var scheduledExpanded = true
    @State private var historyExpanded = true

    // MARK: - Filtered Meetings

    private var filteredUpcoming: [Meeting] {
        let base = showArchived
            ? appState.upcomingMeetings
            : appState.upcomingMeetings.filter { $0.status != .archived }
        if searchQuery.isEmpty { return base }
        return base.filter { $0.title.localizedCaseInsensitiveContains(searchQuery) }
    }

    private var filteredPast: [Meeting] {
        let base = showArchived
            ? appState.pastMeetings
            : appState.pastMeetings.filter { $0.status != .archived }
        if searchQuery.isEmpty { return base }
        return base.filter { $0.title.localizedCaseInsensitiveContains(searchQuery) }
    }

    private var hasNoResults: Bool {
        !searchQuery.isEmpty && filteredUpcoming.isEmpty && filteredPast.isEmpty
    }

    private var hasNoMeetings: Bool {
        searchQuery.isEmpty && appState.upcomingMeetings.isEmpty && appState.pastMeetings.isEmpty
    }

    // MARK: - Body

    var body: some View {
        @Bindable var appState = appState

        VStack(spacing: 0) {

            // MARK: - Top Nav Items (Granola-style)
            VStack(spacing: 2) {
                NavItem(
                    icon: "house.fill",
                    label: "Home",
                    destination: .home,
                    current: appState.sidebarDestination
                ) {
                    appState.sidebarDestination = .home
                    appState.selectedMeetingId = nil
                }

                NavItem(
                    icon: "sparkles",
                    label: "Ask Anything",
                    destination: .chat,
                    current: appState.sidebarDestination
                ) {
                    appState.sidebarDestination = .chat
                    appState.selectedMeetingId = nil
                }

                NavItem(
                    icon: "person.2.fill",
                    label: "People",
                    destination: .people,
                    current: appState.sidebarDestination
                ) {
                    appState.sidebarDestination = .people
                    appState.selectedMeetingId = nil
                }

                // MARK: - Spaces (auto-grouped meeting folders)
                let folders = appState.meetingFolders()
                if !folders.isEmpty {
                    SpacesSidebarSection(
                        folders: folders,
                        currentDestination: appState.sidebarDestination,
                        onSelect: { folder in
                            appState.sidebarDestination = .folder(folder.key)
                            appState.selectedMeetingId = nil
                        }
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Divider()
                .background(Color.appSeparator)

            // MARK: - Meetings Header

            VStack(spacing: 8) {
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
                        Section(isExpanded: $scheduledExpanded) {
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
                        } header: {
                            Text("Scheduled")
                        }
                    } else if searchQuery.isEmpty {
                        Section(isExpanded: $scheduledExpanded) {
                            Text("No scheduled meetings")
                                .font(.subheadline)
                                .foregroundStyle(Color.appTextSecondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 8)
                        } header: {
                            Text("Scheduled")
                        }
                    }

                    if !filteredPast.isEmpty {
                        Section(isExpanded: $historyExpanded) {
                            ForEach(filteredPast) { meeting in
                                MeetingListRow(meeting: meeting, isHistory: true, onError: { errorMessage = $0 })
                                    .tag(meeting.id)
                            }
                        } header: {
                            Text("History")
                        }
                    } else if searchQuery.isEmpty {
                        Section(isExpanded: $historyExpanded) {
                            Text("No past meetings")
                                .font(.subheadline)
                                .foregroundStyle(Color.appTextSecondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 8)
                        } header: {
                            Text("History")
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
    }

    // MARK: - Actions

    private func startEarly(_ meeting: Meeting) {
        appState.startRecording(for: meeting)
    }

    private func createAdHocMeeting() {
        NotificationCenter.default.post(name: .createNewMeeting, object: nil)
    }
}

// MARK: - Spaces Sidebar Section (collapsible)

private struct SpacesSidebarSection: View {
    let folders: [MeetingFolder]
    let currentDestination: SidebarDestination
    let onSelect: (MeetingFolder) -> Void

    @State private var isExpanded = true

    var body: some View {
        VStack(spacing: 2) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Text("My Notes")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.appTextTertiary)
                        .textCase(.uppercase)
                        .tracking(0.7)
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.appTextTertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 8)

            if isExpanded {
                ForEach(folders) { folder in
                    FolderNavItem(
                        folder: folder,
                        current: currentDestination,
                        action: { onSelect(folder) }
                    )
                }
            }
        }
    }
}

// MARK: - Sidebar Section Header

private struct SidebarSectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color.appTextTertiary)
            .textCase(.uppercase)
            .tracking(0.7)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Folder Nav Item

private struct FolderNavItem: View {
    let folder: MeetingFolder
    let current: SidebarDestination
    let action: () -> Void

    private var isSelected: Bool { current == .folder(folder.key) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill")
                    .font(.subheadline)
                    .foregroundStyle(isSelected ? Color.appAccent : Color.appTextSecondary)
                    .frame(width: 18)
                Text(folder.displayName)
                    .font(.subheadline.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.appTextPrimary : Color.appTextSecondary)
                    .lineLimit(1)
                Spacer()
                Text("\(folder.meetingCount)")
                    .font(.caption2)
                    .foregroundStyle(Color.appTextTertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.appSurfaceSecondary)
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(isSelected ? Color.appAccent.opacity(0.12) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Nav Item

private struct NavItem: View {
    let icon: String
    let label: String
    let destination: SidebarDestination
    let current: SidebarDestination
    let action: () -> Void

    private var isSelected: Bool { current == destination }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.subheadline)
                    .foregroundStyle(isSelected ? Color.appAccent : Color.appTextSecondary)
                    .frame(width: 18)
                Text(label)
                    .font(.subheadline.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.appTextPrimary : Color.appTextSecondary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(isSelected ? Color.appAccent.opacity(0.12) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Sidebar Recording Bar

/// Compact recording indicator shown in the sidebar when a meeting is being recorded.
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
        .onReceive(tickTimer) { _ in updateElapsed() }
    }

    private let tickTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

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
    }

    private func stopTimer() {}

    private func updateElapsed() {
        guard let start = meeting.startDate else { elapsedSeconds = 0; return }
        elapsedSeconds = max(0, Int(Date().timeIntervalSince(start)))
    }
}

// MARK: - Detected Call Banner

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

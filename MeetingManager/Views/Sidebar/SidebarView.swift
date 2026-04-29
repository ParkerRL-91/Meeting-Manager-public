import SwiftUI

struct SidebarView: View {
    @Environment(AppState.self) private var appState
    @State private var showAllActionItems = false
    @State private var errorMessage: String?

    // MARK: - Body

    var body: some View {
        @Bindable var appState = appState

        VStack(spacing: 0) {

            // MARK: - Top Nav Items
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
                    icon: "calendar.badge.clock",
                    label: "Daily Brief",
                    badge: appState.dailyBriefMeetingsNeedingPrep,
                    destination: .dailyBrief,
                    current: appState.sidebarDestination
                ) {
                    appState.sidebarDestination = .dailyBrief
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

                NavItem(
                    icon: "magnifyingglass",
                    label: "Search",
                    destination: .search,
                    current: appState.sidebarDestination
                ) {
                    appState.sidebarDestination = .search
                    appState.selectedMeetingId = nil
                }

                NavItem(
                    icon: "chart.bar.xaxis",
                    label: "Analytics",
                    destination: .analytics,
                    current: appState.sidebarDestination
                ) {
                    appState.sidebarDestination = .analytics
                    // Intentionally preserve selectedMeetingId so the
                    // talk-time card can target the previously-selected meeting.
                }

                NavItem(
                    icon: "checklist",
                    label: "Activity",
                    badge: appState.taskQueueManager.pendingCount,
                    destination: .tasks,
                    current: appState.sidebarDestination
                ) {
                    appState.sidebarDestination = .tasks
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

            // MARK: - New Meeting + Action Items

            VStack(spacing: 6) {
                Button {
                    createAdHocMeeting()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .semibold))
                        Text("New Meeting")
                            .font(.system(size: 12.5, weight: .medium))
                    }
                    .foregroundStyle(Color.appTextSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
                    .background(Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4]))
                            .foregroundStyle(Color.appBorderStrongest)
                    )
                }
                .buttonStyle(.plain)
                .help("New Meeting (⌘N)")
                // ⌘N is registered at the app level via `CommandGroup` in
                // MeetingManagerApp; binding it locally too caused a duplicate
                // registration with non-deterministic responder-chain behaviour.

                Button {
                    showAllActionItems = true
                } label: {
                    Label("Action Items", systemImage: "checklist")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.appTextMuted)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)

            Divider()

            // MARK: - Status Banners

            if appState.isRecording, let meeting = appState.activeMeeting {
                SidebarRecordingBar(meeting: meeting)
                Divider()
            } else if let callApp = appState.detectedCallApp {
                DetectedCallBanner(appName: callApp)
                Divider()
            }

            Spacer()

            // Footer: model download status (slim, non-blocking — only visible while loading)
            ModelDownloadBanner()
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
    }

    // MARK: - Actions

    private func createAdHocMeeting() {
        appState.startNewMeeting()
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
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.appTextMuted)
                        .textCase(.uppercase)
                        .tracking(0.4)
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.appTextMuted)
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
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(Color.appTextMuted)
            .textCase(.uppercase)
            .tracking(0.4)
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

    @State private var isHovered = false
    private var isSelected: Bool { current == .folder(folder.key) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: "folder")
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? Color.appAccentLight : Color.appTextMuted)
                    .frame(width: 16)
                Text(folder.displayName)
                    .font(.system(size: 12.5))
                    .foregroundStyle(isSelected ? Color.appTextPrimary : Color.appTextSecondary)
                    .lineLimit(1)
                Spacer()
                Text("\(folder.meetingCount)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.appTextMuted)
                    .monospacedDigit()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(minHeight: 28)
            .background(
                isSelected
                    ? Color.appSurfaceElevated
                    : (isHovered ? Color.appSurfaceSecondary : Color.clear)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Nav Item

private struct NavItem: View {
    let icon: String
    let label: String
    var badge: Int = 0
    let destination: SidebarDestination
    let current: SidebarDestination
    let action: () -> Void

    @State private var isHovered = false
    private var isSelected: Bool { current == destination }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? Color.appAccentLight : Color.appTextTertiary)
                    .frame(width: 16)
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? Color.appAccentLight : Color.appTextSecondary)
                Spacer()
                if badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(Color.appTextMuted)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(minHeight: 28)
            .background(
                isSelected
                    ? Color.appAccentSubtle
                    : (isHovered ? Color.appSurfaceSecondary : Color.clear)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
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
            .accessibilityLabel("Stop recording")
            .accessibilityHint("Ends the meeting and starts transcription")
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

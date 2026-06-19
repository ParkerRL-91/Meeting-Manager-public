import SwiftUI

struct SidebarView: View {
    @Environment(AppState.self) private var appState
    @State private var showAllActionItems = false
    @AppStorage("folders.pinnedKeys") private var pinnedFolderKeysCSV: String = ""
    @State private var errorMessage: String?

    // MARK: - Body

    var body: some View {
        @Bindable var appState = appState

        // Top nav (Home / Daily Brief / etc + Spaces folders) scrolls
        // independently. Bottom block (New Meeting / Action Items / status
        // banners / model download) is pinned and always visible — when
        // the window shrinks, the scroll region shrinks but you can still
        // hit New Meeting and see whether you're recording. Earlier design
        // had the entire sidebar in one VStack with a Spacer pushing the
        // footer down, so a tall folder list pushed New Meeting off-screen.
        VStack(spacing: 0) {

            // MARK: - Top: Scrollable nav + folders
            ScrollView {
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
                        destination: .activity,
                        current: appState.sidebarDestination
                    ) {
                        appState.sidebarDestination = .activity
                        appState.selectedMeetingId = nil
                    }

                    NavItem(
                        icon: "tray.full",
                        label: "Tasks",
                        destination: .taskBoard,
                        current: appState.sidebarDestination
                    ) {
                        appState.sidebarDestination = .taskBoard
                        appState.selectedMeetingId = nil
                    }

                    NavItem(
                        icon: "quote.bubble",
                        label: "Key Quotes",
                        destination: .keyQuotes,
                        current: appState.sidebarDestination
                    ) {
                        appState.sidebarDestination = .keyQuotes
                        appState.selectedMeetingId = nil
                    }

                    NavItem(
                        icon: "tag",
                        label: "Topics",
                        destination: .topics,
                        current: appState.sidebarDestination
                    ) {
                        appState.sidebarDestination = .topics
                        appState.selectedMeetingId = nil
                    }

                    // PRJ-014: shown only when a Knowledge Base folder is
                    // configured. Unconfigured users discover the KB via the
                    // chat / Daily Brief empty-state hooks instead.
                    if appState.kbConfigured {
                        NavItem(
                            icon: "books.vertical",
                            label: "Knowledge Base",
                            destination: .knowledgeBase,
                            current: appState.sidebarDestination
                        ) {
                            appState.sidebarDestination = .knowledgeBase
                            appState.selectedMeetingId = nil
                        }
                    }

                    // MARK: - Spaces (auto-grouped meeting folders)
                    // Pinned folders sort first (stable — recency order kept
                    // within each group); pin/unpin via row context menu
                    // (TASK-040).
                    let pinned = Set(pinnedFolderKeysCSV.split(separator: ",").map(String.init))
                    let folders = appState.meetingFolders()
                        .sorted { (pinned.contains($0.key) ? 0 : 1) < (pinned.contains($1.key) ? 0 : 1) }
                    if !folders.isEmpty {
                        SpacesSidebarSection(
                            folders: folders,
                            pinnedKeys: pinned,
                            currentDestination: appState.sidebarDestination,
                            onSelect: { folder in
                                appState.sidebarDestination = .folder(folder.key)
                                appState.selectedMeetingId = nil
                            },
                            onTogglePin: { folder in
                                var keys = Set(pinnedFolderKeysCSV.split(separator: ",").map(String.init))
                                if keys.contains(folder.key) { keys.remove(folder.key) } else { keys.insert(folder.key) }
                                pinnedFolderKeysCSV = keys.sorted().joined(separator: ",")
                            }
                        )
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 10)
                .padding(.bottom, 6)
            }
            // Take all available space above the pinned footer. Inner
            // ScrollView handles overflow when many folders / a tall
            // window-height combination would otherwise hide the footer.
            .frame(maxHeight: .infinity)

            Divider()
                .background(Color.appSeparator)

            // MARK: - Pinned bottom: New Meeting + Action Items + status

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

            // Status banners (recording bar / call-detected) sit just above
            // the model-download footer, still inside the pinned region so
            // a long folder list never hides the active-recording indicator.
            if appState.isStartingMeeting && !appState.isRecording {
                SidebarStartingBar()
                Divider()
            } else if appState.isRecording, let meeting = appState.activeMeeting {
                SidebarRecordingBar(meeting: meeting, capture: appState.audioCaptureService)
                if let prompt = appState.departurePrompt {
                    DepartureConfirmBar(prompt: prompt)
                }
                Divider()
            } else if let callApp = appState.detectedCallApp {
                DetectedCallBanner(appName: callApp)
                Divider()
            }

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
    let pinnedKeys: Set<String>
    let currentDestination: SidebarDestination
    let onSelect: (MeetingFolder) -> Void
    let onTogglePin: (MeetingFolder) -> Void

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
                        isPinned: pinnedKeys.contains(folder.key),
                        current: currentDestination,
                        action: { onSelect(folder) }
                    )
                    .contextMenu {
                        Button(pinnedKeys.contains(folder.key) ? "Unpin" : "Pin") {
                            onTogglePin(folder)
                        }
                    }
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
    let isPinned: Bool
    let current: SidebarDestination
    let action: () -> Void

    @State private var isHovered = false
    private var isSelected: Bool { current == .folder(folder.key) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: isPinned ? "pin.fill" : "folder")
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

// MARK: - Sidebar Starting Bar

/// Shown in the sidebar from the instant a start is requested until audio is
/// actually live (`isStartingMeeting && !isRecording`). The audio stack —
/// ScreenCaptureKit then mic acquisition — takes 1–3 s to come up; without this
/// the recording UI would appear out of nowhere with no preceding feedback.
/// Uses the recording bar's tint so the transition into `SidebarRecordingBar`
/// is seamless.
private struct SidebarStartingBar: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .tint(Color.appRecording)

            VStack(alignment: .leading, spacing: 2) {
                Text("Starting recording…")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.appRecording)
                Text("Setting up audio…")
                    .font(.caption2)
                    .foregroundStyle(Color.appTextSecondary)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.appRecording.opacity(0.08))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Starting recording, setting up audio")
    }
}

// MARK: - Sidebar Recording Bar

/// Compact recording indicator shown in the sidebar when a meeting is being recorded.
private struct SidebarRecordingBar: View {
    let meeting: Meeting
    /// Observed directly so the level meters track the published mic/system
    /// RMS in real time — a dead mic is visible within a second instead of
    /// being discovered in the transcript hours later (TASK-038).
    @ObservedObject var capture: AudioCaptureService
    @Environment(AppState.self) private var appState
    @State private var elapsedSeconds: Int = 0
    @State private var pulse = false
    @State private var micStatus: String?
    @State private var slideCaptureBusy = false
    @State private var slideCaptureStatus: String?

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.appRecording)
                .frame(width: 8, height: 8)
                .opacity(pulse ? 0.3 : 1.0)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
                .onAppear { pulse = true }

            VStack(alignment: .leading, spacing: 2) {
                Text("Recording")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.appRecording)
                HStack(spacing: 6) {
                    Text(formattedElapsed)
                        .font(.caption2.monospaced())
                        .foregroundStyle(Color.appTextSecondary)
                    CaptureLevelMeter(icon: "mic.fill", level: capture.micLevel,
                                      warn: micStatus != nil)
                    CaptureLevelMeter(icon: "speaker.wave.2.fill", level: capture.systemLevel,
                                      warn: false)
                }
                if let micStatus {
                    Text(micStatus)
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
                if let slideCaptureStatus {
                    Text(slideCaptureStatus)
                        .font(.system(size: 9))
                        .foregroundStyle(Color.appTextTertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // TASK-069: one-click slide capture — grabs the call window,
            // OCRs on-device, saves the text searchably. Manual only.
            Button {
                guard !slideCaptureBusy else { return }
                slideCaptureBusy = true
                let meetingId = meeting.id
                let start = meeting.startDate ?? Date()
                Task {
                    let outcome = await SlideCapture.capture(
                        meetingId: meetingId,
                        recordingStart: start,
                        database: appState.database)
                    slideCaptureStatus = outcome.message
                    slideCaptureBusy = false
                    try? await Task.sleep(for: .seconds(3))
                    slideCaptureStatus = nil
                }
            } label: {
                Image(systemName: "camera.on.rectangle")
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)
                    .frame(width: 22, height: 22)
                    .background(Color.appSurfaceSecondary.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .disabled(slideCaptureBusy)
            .help("Capture slide — OCRs the call window's text on-device so you can search it later")
            .accessibilityLabel("Capture slide")

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
        // Refresh the mic-source/recovery status on the same 1 s tick the
        // elapsed clock uses (these aren't @Published).
        if capture.isMicRecovering {
            micStatus = "acquiring microphone…"
        } else if capture.micSource == .screenCaptureKit {
            micStatus = "mic via screen capture"
        } else {
            micStatus = nil
        }

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

/// Tiny live level meter (icon + 24×4 capsule). RMS is normalised against
/// 0.15 — loud speech peaks the bar, silence empties it. `warn` tints the
/// icon orange while the mic is missing/recovering (TASK-038).
private struct CaptureLevelMeter: View {
    let icon: String
    let level: Float
    let warn: Bool

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 8))
                .foregroundStyle(warn ? AnyShapeStyle(.orange) : AnyShapeStyle(Color.appTextTertiary))
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.appTextTertiary.opacity(0.25))
                    Capsule()
                        .fill(warn ? Color.orange : Color.appAccent)
                        .frame(width: geo.size.width * CGFloat(min(1, level / 0.15)))
                        .animation(.linear(duration: 0.2), value: level)
                }
            }
            .frame(width: 24, height: 4)
        }
        .help(warn ? "Microphone not capturing — recovery is running" : "Live capture level")
    }
}

// MARK: - Departure Confirmation (TASK-072)

/// "Looks like you left the call" bar under the recording indicator.
/// Auto-ends after the grace period unless the user objects — the
/// back-to-back-meetings fix: forgetting to stop meeting A no longer
/// merges it into meeting B.
private struct DepartureConfirmBar: View {
    let prompt: AppState.DeparturePrompt
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Looks like the call ended — still recording \u{201C}\(prompt.meetingTitle)\u{201D}. Ends automatically in ~\(Int(AppState.departureGraceSeconds / 60)) min.")
                .font(.caption)
                .foregroundStyle(Color.appTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("End Now") {
                    appState.dismissDeparturePrompt(stillHere: false)
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Button("I'm Still Here") {
                    appState.dismissDeparturePrompt(stillHere: true)
                }
                .font(.caption)
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12))
    }
}

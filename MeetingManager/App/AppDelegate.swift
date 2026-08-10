import AppKit
import Carbon.HIToolbox
import SwiftUI
import UserNotifications
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem?
    private var callDetectionService: CallDetectionService?

    /// The popover shown from the menu bar status item.
    private var popover: NSPopover?

    /// Fallback menu for right-click or when popover isn't appropriate.
    private var statusMenu: NSMenu?

    /// Observers for dynamic menu bar updates.
    private var statusObservers: [NSObjectProtocol] = []

    /// Floating pre-meeting HUD panel.
    private var reminderWindowController: MeetingReminderWindowController?

    /// Floating "switch meetings" panel — separate from the reminder so the
    /// two can coexist (rare, but possible if a 3rd meeting is on deck).
    private var switchWindowController: MeetingReminderWindowController?

    /// Timer that polls model download progress to update the menu bar.
    private var modelProgressTimer: Timer?

    /// PRJ-017 F4: system-wide "record a thought" hotkey (⌥⌘R).
    private var quickMemoHotKey: GlobalHotKey?

    /// Local recording state mirror — updated by .meetingStateChanged and .startRecording/.stopRecording.
    private var _isRecording = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBarItem()
        setupPopover()
        setupNotifications()
        startCallDetection()
        observeStatusChanges()
        startModelProgressPolling()
        setupGlobalHotKeys()
    }

    /// Register the system-wide Quick Memo hotkey (⌥⌘R). Posts the same
    /// notification the menu-bar item and ⇧⌘M command use, so all three paths
    /// converge on `AppState.startQuickMemo` (PRJ-017 F4).
    private func setupGlobalHotKeys() {
        quickMemoHotKey = GlobalHotKey(
            keyCode: UInt32(kVK_ANSI_R),
            modifiers: UInt32(cmdKey | optionKey)
        ) {
            NSApp.activate(ignoringOtherApps: true)
            NotificationCenter.default.post(name: .startQuickMemo, object: nil)
        }
    }

    // MARK: - Menu Bar

    private func setupMenuBarItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem?.button else { return }
        button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Meeting Manager")
        button.imagePosition = .imageLeading
        button.action = #selector(togglePopover)
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    // MARK: - Popover

    private func setupPopover() {
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 300, height: 300)
        popover.behavior = .transient
        popover.animates = true

        // The SwiftUI view needs AppState from the environment.
        // We'll set the content view lazily on first show so AppState is available.
        self.popover = popover

        // Listen for dismiss requests from the SwiftUI view
        NotificationCenter.default.addObserver(
            forName: .dismissMenuBarPopover,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.popover?.performClose(nil)
            }
        }
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent

        // Right-click shows the traditional menu as a fallback
        if event?.type == .rightMouseUp {
            showContextMenu()
            return
        }

        guard let popover, let button = statusItem?.button else { return }

        if popover.isShown {
            popover.performClose(sender)
        } else {
            // Set the content view with current AppState each time
            // This ensures the environment is fresh
            if let appState = findAppState() {
                let hostingView = NSHostingView(
                    rootView: MenuBarPopoverView()
                        .environment(appState)
                )
                popover.contentViewController = NSViewController()
                popover.contentViewController?.view = hostingView

                // Let SwiftUI size the popover naturally
                let fittingSize = hostingView.fittingSize
                popover.contentSize = NSSize(
                    width: max(300, fittingSize.width),
                    height: max(150, fittingSize.height)
                )
            }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    /// Show the popover automatically (e.g., when recording starts).
    private func showPopoverIfNeeded() {
        guard let popover, let button = statusItem?.button else { return }
        guard !popover.isShown else { return }

        if let appState = findAppState() {
            let hostingView = NSHostingView(
                rootView: MenuBarPopoverView()
                    .environment(appState)
            )
            popover.contentViewController = NSViewController()
            popover.contentViewController?.view = hostingView

            let fittingSize = hostingView.fittingSize
            popover.contentSize = NSSize(
                width: max(300, fittingSize.width),
                height: max(150, fittingSize.height)
            )
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    /// Find the AppState from the SwiftUI app's WindowGroup.
    /// AppState is created as a singleton in the @main App struct.
    private func findAppState() -> AppState? {
        // Access the shared AppState instance via the app's scene storage
        // The AppState is stored on the main window's rootView environment
        guard let window = NSApplication.shared.windows.first,
              let contentView = window.contentView else { return nil }

        // Walk the view hierarchy to find AppState
        // Since AppState is @Observable and set via .environment(), we can access it
        // through the hosting view's environment
        return findAppStateInView(contentView)
    }

    private func findAppStateInView(_ view: NSView) -> AppState? {
        if let hosting = view as? NSHostingView<AnyView> {
            // Can't directly extract from hosting view
        }
        // Fall back to the shared instance pattern
        return AppState.shared
    }

    /// Right-click context menu (traditional NSMenu fallback).
    private func showContextMenu() {
        let menu = NSMenu()

        let isRecording = _isRecording

        if isRecording {
            let header = NSMenuItem(title: "Recording in progress", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            menu.addItem(NSMenuItem(title: "Stop Recording", action: #selector(stopRecording), keyEquivalent: ""))
            menu.addItem(NSMenuItem.separator())

            // Pending switch suggestion (TASK-118): a disabled header plus the
            // same two actions offered on every other surface.
            if let suggestion = findAppState()?.pendingSwitchSuggestion {
                // Truncate — a long tab title would stretch the context menu.
                let headerTitle = suggestion.detectedTitle.count > 60
                    ? "New meeting detected: \(suggestion.detectedTitle.prefix(57))…"
                    : "New meeting detected: \(suggestion.detectedTitle)"
                let switchHeader = NSMenuItem(title: headerTitle, action: nil, keyEquivalent: "")
                switchHeader.isEnabled = false
                menu.addItem(switchHeader)
                let accept = NSMenuItem(title: "Switch & Record", action: #selector(acceptSwitchSuggestion), keyEquivalent: "")
                accept.target = self
                menu.addItem(accept)
                let declineTitle = suggestion.origin == .detectedApp ? "Keep recording" : "Same meeting"
                let decline = NSMenuItem(title: declineTitle, action: #selector(declineSwitchSuggestion), keyEquivalent: "")
                decline.target = self
                menu.addItem(decline)
                menu.addItem(NSMenuItem.separator())
            }
        }

        menu.addItem(NSMenuItem(title: "New Meeting", action: #selector(newMeeting), keyEquivalent: "n"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Open Meeting Manager", action: #selector(openMainWindow), keyEquivalent: "o"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Check for Updates...", action: #selector(checkForUpdates), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        // Clear menu so left-click goes back to popover
        DispatchQueue.main.async { [weak self] in
            self?.statusItem?.menu = nil
        }
    }

    // MARK: - Dynamic Status Bar Updates

    private func observeStatusChanges() {
        let nc = NotificationCenter.default

        // Recording started (via state machine)
        statusObservers.append(nc.addObserver(
            forName: .meetingStateChanged, object: nil, queue: .main
        ) { [weak self] notification in
            let status = notification.userInfo?["status"] as? String
            MainActor.assumeIsolated {
                if status == "recording" {
                    self?._isRecording = true
                    // Auto-show the popover dropdown when recording starts
                    self?.showPopoverIfNeeded()
                } else if status == "transcribing" || status == "complete" || status == "cancelled" {
                    self?._isRecording = false
                }
                self?.updateStatusBar()
            }
        })

        // Call app detected
        statusObservers.append(nc.addObserver(
            forName: .callAppLaunched, object: nil, queue: .main
        ) { [weak self] notification in
            let appName = notification.userInfo?["appName"] as? String ?? "Call"
            MainActor.assumeIsolated {
                self?.showStatusBarMessage(
                    icon: "phone.fill",
                    text: "\(appName) detected",
                    tint: .systemGreen
                )
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                MainActor.assumeIsolated { self?.updateStatusBar() }
            }
        })

        // Call app terminated
        statusObservers.append(nc.addObserver(
            forName: .callAppTerminated, object: nil, queue: .main
        ) { [weak self] notification in
            let appName = notification.userInfo?["appName"] as? String ?? "Call"
            MainActor.assumeIsolated {
                self?.showStatusBarMessage(
                    icon: "phone.down.fill",
                    text: "\(appName) ended",
                    tint: .systemOrange
                )
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                MainActor.assumeIsolated { self?.updateStatusBar() }
            }
        })

        // Meeting starting soon — update status bar only
        statusObservers.append(nc.addObserver(
            forName: .meetingStartingSoon, object: nil, queue: .main
        ) { [weak self] notification in
            let minutes = notification.userInfo?["minutesUntilStart"] as? Int ?? 0
            let text = minutes <= 1 ? "Meeting starting now" : "Meeting in \(minutes) min"
            MainActor.assumeIsolated {
                self?.showStatusBarMessage(
                    icon: "calendar.badge.clock",
                    text: text,
                    tint: .systemYellow
                )
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
                MainActor.assumeIsolated { self?.updateStatusBar() }
            }
        })

        // 1-minute HUD: show the floating pre-meeting card (fired independently
        // of the lead-time notification so it always appears at ~1 min before)
        statusObservers.append(nc.addObserver(
            forName: .meetingHUDShow, object: nil, queue: .main
        ) { [weak self] notification in
            let meetingId = notification.userInfo?["meetingId"] as? String
            MainActor.assumeIsolated {
                if let meetingId,
                   let meeting = AppState.shared?.upcomingMeetings.first(where: { $0.id == meetingId }) {
                    if self?.reminderWindowController == nil {
                        self?.reminderWindowController = MeetingReminderWindowController()
                    }
                    self?.reminderWindowController?.show(meeting: meeting)
                }
            }
        })

        // Unified switch suggestion (TASK-118): the floating window shows only
        // for high-confidence, undemoted offers — a speculative medium guess
        // must not pop UI over a live screen share. The orange status item is
        // the beacon for medium offers; all surfaces read pendingSwitchSuggestion.
        statusObservers.append(nc.addObserver(
            forName: .meetingSwitchShow, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let appState = AppState.shared,
                      let suggestion = appState.pendingSwitchSuggestion else { return }
                if suggestion.confidence == .high && !appState.switchSuggestionDemoted {
                    if self.switchWindowController == nil {
                        self.switchWindowController = MeetingReminderWindowController()
                    }
                    self.switchWindowController?.show(suggestion: suggestion)
                }
                self.updateStatusBar()
            }
        })

        statusObservers.append(nc.addObserver(
            forName: .meetingSwitchDismiss, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.switchWindowController?.dismiss()
                self?.updateStatusBar()
            }
        })

        // TASK-124: silent-capture warning toggled — refresh the status item so
        // the orange "No audio?" title appears/clears while recording.
        statusObservers.append(nc.addObserver(
            forName: .captureSilenceChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateStatusBar()
            }
        })

        // Start recording
        statusObservers.append(nc.addObserver(
            forName: .startRecording, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?._isRecording = true
                self?.updateStatusBar()
                self?.showPopoverIfNeeded()
            }
        })

        // Stop recording
        statusObservers.append(nc.addObserver(
            forName: .stopRecording, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?._isRecording = false
                self?.showStatusBarMessage(
                    icon: "checkmark.circle.fill",
                    text: "Recording saved",
                    tint: .systemGreen
                )
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                MainActor.assumeIsolated { self?.updateStatusBar() }
            }
        })
    }

    /// Update the status bar to reflect the current live state.
    private func updateStatusBar() {
        guard let button = statusItem?.button else { return }

        let isRecording = _isRecording
        let isCallActive = callDetectionService?.activeCallApp != nil
        let callAppName = callDetectionService?.activeCallAppName

        if isRecording {
            let appState = findAppState()
            // Precedence in the recording branch (TASK-124): silence warning >
            // switch suggestion > plain "Recording". A capture producing nothing
            // invalidates everything else, so it outranks the switch beacon.
            // In every case the red record dot stays — the always-visible "am I
            // recording?" signal must never disappear — and only the title swaps
            // (orange via attributedTitle; contentTintColor would tint the whole
            // button and erase the red icon).
            if let appState, appState.captureSilenceWarning {
                button.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Recording — no audio detected")
                button.contentTintColor = .systemRed
                button.attributedTitle = NSAttributedString(
                    string: "  No audio?",
                    attributes: [.foregroundColor: NSColor.systemOrange,
                                 .font: NSFont.menuBarFont(ofSize: 0)]
                )
            } else if let appState,
                      appState.pendingSwitchSuggestion != nil,
                      !appState.switchSuggestionDemoted {
                button.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Recording — new meeting suggested")
                button.contentTintColor = .systemRed
                button.attributedTitle = NSAttributedString(
                    string: "  Switch?",
                    attributes: [.foregroundColor: NSColor.systemOrange,
                                 .font: NSFont.menuBarFont(ofSize: 0)]
                )
            } else {
                button.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Recording")
                button.title = "  Recording"
                button.contentTintColor = .systemRed
            }
        } else if let appState = findAppState(), appState.isLoadingModel {
            // Show download progress in the menu bar
            let pct = Int(appState.modelDownloadProgress * 100)
            button.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: "Downloading")
            button.title = "  Downloading \(pct)%"
            button.contentTintColor = .systemBlue
        } else if isCallActive {
            let name = callAppName ?? "Call"
            button.image = NSImage(systemSymbolName: "phone.fill", accessibilityDescription: name)
            button.title = "  \(name)"
            button.contentTintColor = .systemGreen
        } else {
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Meeting Manager")
            button.title = ""
            button.contentTintColor = nil
        }
    }

    /// Show a transient message in the menu bar with an icon and text.
    private func showStatusBarMessage(icon: String, text: String, tint: NSColor) {
        guard let button = statusItem?.button else { return }
        button.image = NSImage(systemSymbolName: icon, accessibilityDescription: text)
        button.title = "  \(text)"
        button.contentTintColor = tint
    }

    // MARK: - Actions

    @objc private func newMeeting() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .createNewMeeting, object: nil)
    }

    @objc private func openMainWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @objc private func stopRecording() {
        NotificationCenter.default.post(name: .stopRecording, object: nil)
    }

    @objc private func acceptSwitchSuggestion() {
        AppState.shared?.acceptSwitchSuggestion()
    }

    @objc private func declineSwitchSuggestion() {
        AppState.shared?.dismissSwitchSuggestion(byUser: true)
    }

    @objc private func startRecordingAction() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .startRecording, object: nil)
    }

    @objc private func checkForUpdates() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .openUpdateSettings, object: nil)
    }

    // MARK: - Notifications

    private func setupNotifications() {
        UNUserNotificationCenter.current().delegate = self
        NotificationActions.registerCategories()
        Task {
            _ = await AppState.shared?.notificationService.requestAuthorization()
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let meetingId = response.notification.request.content.userInfo["meetingId"] as? String
        let meetLink = response.notification.request.content.userInfo["meetLink"] as? String
        let taskIdString = response.notification.request.content.userInfo["taskId"] as? String
        let taskId = taskIdString.flatMap { Int64($0) }
        let categoryId = response.notification.request.content.categoryIdentifier
        let identifier = response.notification.request.identifier
        Logger.notifications.info("[didReceive] action=\(response.actionIdentifier, privacy: .public) category=\(categoryId, privacy: .public) id=\(identifier, privacy: .public) meetingId=\(meetingId ?? "nil", privacy: .public) hasLink=\(meetLink != nil)")

        switch response.actionIdentifier {
        case NotificationActions.joinMeeting:
            Logger.notifications.info("[didReceive] joinMeeting tapped — opening link + starting recording")
            // Open the video call URL in the default browser
            if let meetLink, let url = URL(string: meetLink) {
                let opened = NSWorkspace.shared.open(url)
                Logger.notifications.info("[didReceive] NSWorkspace.open(\(url.absoluteString, privacy: .public)) returned \(opened)")
            } else {
                Logger.notifications.warning("[didReceive] joinMeeting: no meetLink in userInfo — recording will start but no URL to open")
            }
            // Also start recording
            if let meetingId {
                Logger.notifications.info("[didReceive] posting .startRecording for meeting=\(meetingId, privacy: .public)")
                NotificationCenter.default.post(
                    name: .startRecording,
                    object: nil,
                    userInfo: ["meetingId": meetingId]
                )
            } else {
                Logger.notifications.error("[didReceive] joinMeeting: no meetingId in userInfo — cannot start recording")
            }
        case NotificationActions.startRecording:
            Logger.notifications.info("[didReceive] startRecording tapped")
            if let meetingId {
                NotificationCenter.default.post(
                    name: .startRecording,
                    object: nil,
                    userInfo: ["meetingId": meetingId]
                )
            } else {
                Logger.notifications.error("[didReceive] startRecording: no meetingId")
            }
        case NotificationActions.snooze:
            Logger.notifications.info("[didReceive] snooze tapped")
            if let meetingId {
                AppState.shared?.notificationService.scheduleSnooze(meetingId: meetingId, minutes: 5)
            }
        case NotificationActions.prepMeeting:
            Logger.notifications.info("[didReceive] prepMeeting tapped")
            if let meetingId {
                AppState.shared?.selectedMeetingId = meetingId
            }
        case NotificationActions.sendRecap:
            Logger.notifications.info("[didReceive] sendRecap tapped")
            if let meetingId {
                AppState.shared?.selectedMeetingId = meetingId
            }
        case NotificationActions.markTaskDone:
            Logger.notifications.info("[didReceive] markTaskDone tapped task=\(taskId.map(String.init) ?? "nil", privacy: .public)")
            if let taskId {
                Task { @MainActor in
                    try? await AppState.shared?.taskRepository.setCompleted(id: taskId, true)
                }
            }
        case NotificationActions.snoozeTask:
            Logger.notifications.info("[didReceive] snoozeTask tapped task=\(taskId.map(String.init) ?? "nil", privacy: .public)")
            if let taskId {
                Task { @MainActor in
                    if let updated = try? await AppState.shared?.taskRepository.snoozeReminder(id: taskId, byDays: 1) {
                        await AppState.shared?.notificationService.scheduleTaskDueNotification(for: updated)
                    }
                }
            }
        case NotificationActions.openTask:
            Logger.notifications.info("[didReceive] openTask tapped task=\(taskId.map(String.init) ?? "nil", privacy: .public)")
            if let taskId {
                AppState.shared?.selectedTaskId = taskId
                AppState.shared?.sidebarDestination = .taskBoard
            }
        case UNNotificationDefaultActionIdentifier:
            Logger.notifications.info("[didReceive] banner tapped (default action) category=\(categoryId, privacy: .public)")
            if categoryId == NotificationActions.summaryReadyCategory, let meetingId {
                AppState.shared?.selectedMeetingId = meetingId
            } else if categoryId == NotificationActions.overdueTaskCategory, let taskId {
                AppState.shared?.selectedTaskId = taskId
                AppState.shared?.sidebarDestination = .taskBoard
            }
        case UNNotificationDismissActionIdentifier:
            Logger.notifications.info("[didReceive] notification dismissed by user")
        default:
            Logger.notifications.warning("[didReceive] unhandled action=\(response.actionIdentifier, privacy: .public)")
        }

        completionHandler()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let id = notification.request.identifier
        let category = notification.request.content.categoryIdentifier
        Logger.notifications.info("[willPresent] notification firing id=\(id, privacy: .public) category=\(category, privacy: .public) — presenting as banner+sound")
        completionHandler([.banner, .sound])
    }

    // MARK: - Call Detection

    private func startCallDetection() {
        callDetectionService = CallDetectionService()
        // Suppress the browser mic-usage heuristic while we're recording —
        // otherwise our own capture engine makes "in call" permanently true
        // and browser call-end detection can never fire.
        callDetectionService?.isRecordingProvider = { AppState.shared?.isRecording ?? false }
        // Switch detection (TASK-117): forward every in-call browser title poll
        // and debounced call-app activations to AppState's engine.
        callDetectionService?.onBrowserCallTitles = { titles in
            AppState.shared?.forwardBrowserCallTitles(titles)
        }
        callDetectionService?.onCallAppActivated = { bundleId, name in
            AppState.shared?.forwardCallAppActivation(bundleId: bundleId, name: name)
        }
        callDetectionService?.startMonitoring()
    }

    // MARK: - Model Download Progress Polling

    /// Poll AppState.isLoadingModel so the menu bar shows download progress.
    /// Invalidates on the loading true→false EDGE — the old condition also
    /// required the status-bar title to literally contain "Downloading", which
    /// is false whenever another state (e.g. "Recording") owns the title, so
    /// the 1 Hz timer ran for the entire process lifetime.
    private func startModelProgressPolling() {
        var sawLoading = false
        var ticks = 0
        modelProgressTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                guard let appState = self.findAppState() else { return }
                ticks += 1
                if appState.isLoadingModel {
                    sawLoading = true
                    self.updateStatusBar()
                } else if sawLoading || appState.transcriptionService.isModelLoaded || ticks > 300 {
                    // Load finished (or never started within 5 min — failed
                    // or instant-cached) — update once and stop polling.
                    self.updateStatusBar()
                    timer.invalidate()
                    self.modelProgressTimer = nil
                }
            }
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let createNewMeeting = Notification.Name("createNewMeeting")
    static let startQuickMemo = Notification.Name("startQuickMemo")
    static let startRecording = Notification.Name("startRecording")
    static let stopRecording = Notification.Name("stopRecording")
    static let callAppLaunched = Notification.Name("callAppLaunched")
    static let callAppTerminated = Notification.Name("callAppTerminated")
    static let meetingStateChanged = Notification.Name("meetingStateChanged")
    static let switchTab = Notification.Name("switchTab")
    static let exportMeeting = Notification.Name("exportMeeting")
    static let summaryPromptTemplateDidChange = Notification.Name("summaryPromptTemplateDidChange")
    static let copySummary = Notification.Name("copySummary")
    static let focusSearch = Notification.Name("focusSearch")
    static let meetingStartingSoon = Notification.Name("meetingStartingSoon")
    static let meetingHUDShow = Notification.Name("meetingHUDShow")
    /// Posted when a different meeting is starting while one is already being
    /// recorded — drives the persistent "Switch meetings" banner.
    static let meetingSwitchShow = Notification.Name("meetingSwitchShow")
    /// Posted when the switch offer should be dismissed (user acted, meeting
    /// passed, recording stopped, etc.).
    static let meetingSwitchDismiss = Notification.Name("meetingSwitchDismiss")

    /// TASK-124: sustained silent-capture warning flipped on/off in AppState.
    /// The status item (an AppKit surface, can't observe @Observable) refreshes
    /// off this to show the orange "No audio?" title.
    static let captureSilenceChanged = Notification.Name("captureSilenceChanged")
    /// Posted by the switch banner when the user clicks "Switch & Record".
    /// AppState handles the stop+start sequencing.
    static let switchToMeeting = Notification.Name("switchToMeeting")
    /// Posted by `MeetingSwitchDetectionService` (TASK-117) when the live call
    /// appears to have changed while recording. userInfo (all value types):
    /// detectedTitle, normalizedTitle, sourceSignal, confidence, and optional
    /// matchedMeetingId / bundleIdentifier. The consumer funnel is TASK-118.
    static let meetingSwitchDetected = Notification.Name("meetingSwitchDetected")
    static let openUpdateSettings = Notification.Name("openUpdateSettings")
    static let calendarBackfillCompleted = Notification.Name("calendarBackfillCompleted")
    /// Posted whenever the user changes which calendar source the app should
    /// pull from. CalendarSyncManager observes this to stop/restart its timer
    /// without an app relaunch.
    static let calendarSourceChanged = Notification.Name("calendarSourceChanged")
    /// Posted by GoogleAuthManager on every `isSignedIn` transition — including
    /// both outcomes of the async Keychain restore, so "restore finished, and the
    /// user really is signed out" is observable rather than indistinguishable from
    /// "restore hasn't landed yet". CalendarSyncManager observes this to sync the
    /// moment auth becomes usable instead of waiting out the 15-minute tick.
    static let googleAuthStateChanged = Notification.Name("googleAuthStateChanged")
    /// TASK-122: posted when a weekly digest finishes writing. userInfo carries
    /// the ISO week id under "isoWeek". `WeeklyReviewSection` on Home observes it
    /// to refresh live without polling.
    static let weeklyDigestCompleted = Notification.Name("weeklyDigestCompleted")
}

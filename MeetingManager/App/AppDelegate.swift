import AppKit
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem?
    private var callDetectionService: CallDetectionService?
    private var notificationService: NotificationService?

    /// Observers for dynamic menu bar updates.
    private var statusObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBarItem()
        setupNotifications()
        startCallDetection()
        observeStatusChanges()
    }

    // MARK: - Menu Bar

    private func setupMenuBarItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem?.button else { return }
        button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Meeting Manager")
        button.imagePosition = .imageLeading

        rebuildMenu()
    }

    /// Rebuild the dropdown menu. Called when state changes to update dynamic items.
    private func rebuildMenu() {
        let menu = NSMenu()

        let isRecording = currentlyRecording()
        let isCallActive = callDetectionService?.activeCallApp != nil
        let callAppName = callDetectionService?.activeCallAppName

        if isRecording {
            // ── Recording header ──
            let header = NSMenuItem(title: "🔴  Recording in progress", action: nil, keyEquivalent: "")
            header.isEnabled = false
            header.attributedTitle = NSAttributedString(
                string: "🔴  Recording in progress",
                attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]
            )
            menu.addItem(header)

            let stopItem = NSMenuItem(title: "Stop Recording", action: #selector(stopRecording), keyEquivalent: "")
            stopItem.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "Stop")
            menu.addItem(stopItem)
            menu.addItem(NSMenuItem.separator())

        } else if isCallActive, let name = callAppName {
            // ── Call detected, not recording ──
            let header = NSMenuItem(title: "📞  \(name) detected", action: nil, keyEquivalent: "")
            header.isEnabled = false
            header.attributedTitle = NSAttributedString(
                string: "📞  \(name) detected",
                attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]
            )
            menu.addItem(header)

            let startItem = NSMenuItem(title: "Start Recording", action: #selector(startRecordingAction), keyEquivalent: "")
            startItem.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Record")
            menu.addItem(startItem)
            menu.addItem(NSMenuItem.separator())
        }

        menu.addItem(NSMenuItem(title: "New Meeting", action: #selector(newMeeting), keyEquivalent: "n"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Open Meeting Manager", action: #selector(openMainWindow), keyEquivalent: "o"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Check for Updates...", action: #selector(checkForUpdates), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem?.menu = menu
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
                if status == "recording" { self?._isRecording = true }
                else if status == "transcribing" || status == "complete" || status == "cancelled" {
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

        // Meeting starting soon
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

        // Start recording
        statusObservers.append(nc.addObserver(
            forName: .startRecording, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?._isRecording = true
                self?.updateStatusBar()
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
    /// Called after transient messages expire to show the "real" current state.
    private func updateStatusBar() {
        guard let button = statusItem?.button else { return }

        let isRecording = currentlyRecording()
        let isCallActive = callDetectionService?.activeCallApp != nil
        let callAppName = callDetectionService?.activeCallAppName

        if isRecording {
            // Red pulsing indicator while recording
            button.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Recording")
            button.title = "  Recording"
            button.contentTintColor = .systemRed
        } else if isCallActive {
            let name = callAppName ?? "Call"
            button.image = NSImage(systemSymbolName: "phone.fill", accessibilityDescription: name)
            button.title = "  \(name)"
            button.contentTintColor = .systemGreen
        } else {
            // Idle — waveform icon only, no text
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Meeting Manager")
            button.title = ""
            button.contentTintColor = nil
        }

        rebuildMenu()
    }

    /// Show a transient message in the menu bar with an icon and text.
    private func showStatusBarMessage(icon: String, text: String, tint: NSColor) {
        guard let button = statusItem?.button else { return }
        button.image = NSImage(systemSymbolName: icon, accessibilityDescription: text)
        button.title = "  \(text)"
        button.contentTintColor = tint
        rebuildMenu()
    }

    /// Whether a meeting is currently being recorded (checked via NSApplication shared state).
    private func currentlyRecording() -> Bool {
        // Derive recording state from the active .meetingStateChanged notification last value.
        // We track this locally since AppDelegate doesn't hold AppState.
        return _isRecording
    }

    /// Local recording state mirror — updated by .meetingStateChanged and .startRecording/.stopRecording.
    private var _isRecording = false

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

    @objc private func startRecordingAction() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .startRecording, object: nil)
    }

    @objc private func checkForUpdates() {
        // Open Settings > Updates tab where the user can manually check
        NSApplication.shared.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .openUpdateSettings, object: nil)
    }

    // MARK: - Notifications

    private func setupNotifications() {
        UNUserNotificationCenter.current().delegate = self
        NotificationActions.registerCategories()
        notificationService = NotificationService()
        Task {
            _ = await notificationService?.requestAuthorization()
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let meetingId = response.notification.request.content.userInfo["meetingId"] as? String

        switch response.actionIdentifier {
        case NotificationActions.startRecording:
            if let meetingId {
                NotificationCenter.default.post(
                    name: .startRecording,
                    object: nil,
                    userInfo: ["meetingId": meetingId]
                )
            }
        case NotificationActions.snooze:
            if let meetingId {
                notificationService?.scheduleSnooze(meetingId: meetingId, minutes: 5)
            }
        default:
            break
        }

        completionHandler()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    // MARK: - Call Detection

    private func startCallDetection() {
        callDetectionService = CallDetectionService()
        callDetectionService?.startMonitoring()
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let createNewMeeting = Notification.Name("createNewMeeting")
    static let startRecording = Notification.Name("startRecording")
    static let stopRecording = Notification.Name("stopRecording")
    static let callAppLaunched = Notification.Name("callAppLaunched")
    static let callAppTerminated = Notification.Name("callAppTerminated")
    static let meetingStateChanged = Notification.Name("meetingStateChanged")
    static let switchTab = Notification.Name("switchTab")
    static let exportMeeting = Notification.Name("exportMeeting")
    static let copySummary = Notification.Name("copySummary")
    static let focusSearch = Notification.Name("focusSearch")
    static let meetingStartingSoon = Notification.Name("meetingStartingSoon")
    static let openUpdateSettings = Notification.Name("openUpdateSettings")
}

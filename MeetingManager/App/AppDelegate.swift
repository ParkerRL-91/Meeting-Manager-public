import AppKit
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem?
    private var callDetectionService: CallDetectionService?
    private var notificationService: NotificationService?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBarItem()
        setupNotifications()
        startCallDetection()
    }

    // MARK: - Menu Bar

    private func setupMenuBarItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem?.button else { return }
        button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Meeting Manager")

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "New Meeting", action: #selector(newMeeting), keyEquivalent: "n"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Open Meeting Manager", action: #selector(openMainWindow), keyEquivalent: "o"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Check for Updates...", action: #selector(checkForUpdates), keyEquivalent: "u"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem?.menu = menu
    }

    @objc private func newMeeting() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .createNewMeeting, object: nil)
    }

    @objc private func openMainWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @objc private func checkForUpdates() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        // Sparkle's update check is triggered via the app menu command
        // The SPUStandardUpdaterController in MeetingManagerApp handles the actual check
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

    @MainActor private func startCallDetection() {
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
}

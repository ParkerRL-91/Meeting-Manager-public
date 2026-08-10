import AppKit
import Foundation

/// Monitors the system for call-app launch and termination events.
///
/// Tracks the most recently launched call app as the "active" one and posts
/// `.callAppLaunched` / `.callAppTerminated` notifications with `userInfo`
/// containing `"appName"` and `"bundleIdentifier"` keys.
@Observable
@MainActor
final class CallDetectionService {
    // MARK: - Published State

    private(set) var activeCallApp: NSRunningApplication?
    private(set) var activeCallAppName: String?

    // MARK: - Private

    /// All currently-running call apps, ordered by detection time (most recent last).
    private var runningCallApps: [NSRunningApplication] = []
    nonisolated(unsafe) private var launchObserver: NSObjectProtocol?
    nonisolated(unsafe) private var terminateObserver: NSObjectProtocol?

    /// Detects browser-based meetings (Google Meet, etc.) via window title polling.
    nonisolated(unsafe) private var browserDetector: BrowserCallDetector?

    /// Forwarded to BrowserCallDetector — suppresses the mic-usage heuristic
    /// while Meeting Manager itself is recording (our capture engine keeps the
    /// input device active, which would read as an always-on browser call).
    var isRecordingProvider: (() -> Bool)? {
        didSet { browserDetector?.isRecordingProvider = isRecordingProvider }
    }

    /// Passthrough for `BrowserCallDetector.onInCallTitlesObserved` — every
    /// matched meeting title per poll while recording, forwarded to the switch
    /// detector (see `MeetingSwitchDetectionService.noteBrowserTitles`).
    var onBrowserCallTitles: (([String]) -> Void)? {
        didSet { browserDetector?.onInCallTitlesObserved = onBrowserCallTitles }
    }

    /// A known call app was brought to the foreground. NSWorkspace launch
    /// events miss apps that reuse a running process (Zoom A→B) or auto-launch
    /// at login (Teams); activation partially covers those as a
    /// medium-confidence-only switch signal. `(bundleId, displayName)`.
    var onCallAppActivated: ((String, String) -> Void)?

    /// Debounce: activation is noisy (every app-switch fires it). Suppress a
    /// repeat activation of the same bundle within this window.
    private static let activationDebounce: TimeInterval = 30
    private var lastActivationByBundle: [String: Date] = [:]
    nonisolated(unsafe) private var activateObserver: NSObjectProtocol?

    /// Apps that were already running when we started monitoring.
    /// These are NOT treated as "call started" events because they may have been
    /// open before Meeting Manager launched (e.g., Teams auto-launches at login).
    /// We track them so we can detect when they *terminate* (call ended).
    private var preExistingApps: Set<pid_t> = []

    // MARK: - Lifecycle

    init(startImmediately: Bool = true) {
        if startImmediately {
            startMonitoring()
        }
    }

    deinit {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        if let observer = launchObserver { workspaceCenter.removeObserver(observer) }
        if let observer = terminateObserver { workspaceCenter.removeObserver(observer) }
        if let observer = activateObserver { workspaceCenter.removeObserver(observer) }
        let detector = browserDetector
        Task { @MainActor in detector?.stop() }
    }

    // MARK: - Monitoring

    func startMonitoring() {
        guard launchObserver == nil else { return }

        // Start browser-based meeting detection (Google Meet, etc.)
        browserDetector = BrowserCallDetector()
        browserDetector?.isRecordingProvider = isRecordingProvider
        browserDetector?.onInCallTitlesObserved = onBrowserCallTitles
        browserDetector?.start()

        let workspaceCenter = NSWorkspace.shared.notificationCenter

        // Scan for call apps that are already running. Track them so we detect
        // termination, but do NOT fire callAppLaunched — they were open before
        // Meeting Manager started, so they're not evidence of a new call.
        // (e.g., Teams auto-launches at login, Zoom left open from earlier)
        let alreadyRunning = NSWorkspace.shared.runningApplications.filter {
            guard let bundleID = $0.bundleIdentifier else { return false }
            return CallAppRegistry.isCallApp(bundleIdentifier: bundleID)
        }
        for app in alreadyRunning {
            preExistingApps.insert(app.processIdentifier)
            if !runningCallApps.contains(app) {
                runningCallApps.append(app)
            }
        }

        launchObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated {
                self?.handleAppLaunched(app)
            }
        }

        terminateObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated {
                self?.handleAppTerminated(app)
            }
        }

        activateObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated {
                self?.handleAppActivated(app)
            }
        }
    }

    func stopMonitoring() {
        browserDetector?.stop()
        browserDetector = nil

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        if let observer = launchObserver {
            workspaceCenter.removeObserver(observer)
            launchObserver = nil
        }
        if let observer = terminateObserver {
            workspaceCenter.removeObserver(observer)
            terminateObserver = nil
        }
        if let observer = activateObserver {
            workspaceCenter.removeObserver(observer)
            activateObserver = nil
        }
        runningCallApps.removeAll()
        preExistingApps.removeAll()
        lastActivationByBundle.removeAll()
        activeCallApp = nil
        activeCallAppName = nil
    }

    // MARK: - Internal Handlers

    private func handleAppLaunched(_ app: NSRunningApplication) {
        guard let bundleID = app.bundleIdentifier,
              CallAppRegistry.isCallApp(bundleIdentifier: bundleID) else { return }

        trackLaunch(of: app)
        postNotification(.callAppLaunched, app: app, bundleID: bundleID)
    }

    private func handleAppTerminated(_ app: NSRunningApplication) {
        guard let bundleID = app.bundleIdentifier,
              CallAppRegistry.isCallApp(bundleIdentifier: bundleID) else { return }

        runningCallApps.removeAll { $0 == app }

        // If the terminated app was the active one, fall back to the next most recent.
        if activeCallApp == app {
            if let fallback = runningCallApps.last,
               let fallbackID = fallback.bundleIdentifier {
                activeCallApp = fallback
                activeCallAppName = CallAppRegistry.displayName(for: fallbackID)
            } else {
                activeCallApp = nil
                activeCallAppName = nil
            }
        }

        postNotification(.callAppTerminated, app: app, bundleID: bundleID)
    }

    /// Forwards a debounced call-app foreground activation to the switch
    /// detector. Does NOT post `.callAppLaunched` — activation is not a launch,
    /// and the recording/auto-record paths must keep keying off real launches.
    private func handleAppActivated(_ app: NSRunningApplication) {
        guard let bundleID = app.bundleIdentifier,
              CallAppRegistry.isCallApp(bundleIdentifier: bundleID) else { return }

        let now = Date()
        if let last = lastActivationByBundle[bundleID],
           now.timeIntervalSince(last) < Self.activationDebounce {
            return
        }
        lastActivationByBundle[bundleID] = now

        let name = CallAppRegistry.displayName(for: bundleID) ?? bundleID
        onCallAppActivated?(bundleID, name)
    }

    // MARK: - Helpers

    /// Adds the app to the running list and makes it the active call app.
    private func trackLaunch(of app: NSRunningApplication) {
        // Avoid duplicates.
        if !runningCallApps.contains(app) {
            runningCallApps.append(app)
        }
        // Most recently launched app becomes active.
        activeCallApp = app
        if let bundleID = app.bundleIdentifier {
            activeCallAppName = CallAppRegistry.displayName(for: bundleID)
        }
    }

    private func postNotification(_ name: Notification.Name, app: NSRunningApplication, bundleID: String) {
        let userInfo: [String: Any] = [
            "appName": CallAppRegistry.displayName(for: bundleID) ?? bundleID,
            "bundleIdentifier": bundleID
        ]
        NotificationCenter.default.post(name: name, object: self, userInfo: userInfo)
    }
}

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
    private var launchObserver: NSObjectProtocol?
    private var terminateObserver: NSObjectProtocol?

    // MARK: - Lifecycle

    init(startImmediately: Bool = true) {
        if startImmediately {
            startMonitoring()
        }
    }

    deinit {
        // Observers use [weak self] so they're safe when object is deallocated
    }

    // MARK: - Monitoring

    func startMonitoring() {
        guard launchObserver == nil else { return }

        let workspaceCenter = NSWorkspace.shared.notificationCenter

        // Scan for call apps that are already running.
        let alreadyRunning = NSWorkspace.shared.runningApplications.filter {
            guard let bundleID = $0.bundleIdentifier else { return false }
            return CallAppRegistry.isCallApp(bundleIdentifier: bundleID)
        }
        for app in alreadyRunning {
            trackLaunch(of: app)
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
    }

    func stopMonitoring() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        if let observer = launchObserver {
            workspaceCenter.removeObserver(observer)
            launchObserver = nil
        }
        if let observer = terminateObserver {
            workspaceCenter.removeObserver(observer)
            terminateObserver = nil
        }
        runningCallApps.removeAll()
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

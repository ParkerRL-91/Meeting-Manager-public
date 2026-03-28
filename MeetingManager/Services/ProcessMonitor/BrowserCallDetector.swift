import AppKit
import CoreGraphics
import Foundation
import os

/// Detects browser-based video calls (Google Meet, Zoom web, etc.) by polling
/// the on-screen window list for meeting-related window titles.
///
/// Posts `.callAppLaunched` when a meeting window appears and `.callAppTerminated`
/// when all matching windows disappear.  Falls back silently if Screen Recording
/// permission has not been granted — in that case window titles are hidden by
/// the system and no notifications are posted.
@MainActor
final class BrowserCallDetector {

    // MARK: - State

    private var pollTimer: Timer?
    private(set) var isInBrowserCall = false

    // MARK: - Lifecycle

    /// Start polling every `interval` seconds (default 5 s).
    func start(interval: TimeInterval = 5) {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        pollTimer?.fire()
        Logger.general.info("BrowserCallDetector: started (interval \(interval, format: .fixed(precision: 0))s)")
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        if isInBrowserCall {
            isInBrowserCall = false
            postNotification(.callAppTerminated)
        }
        Logger.general.info("BrowserCallDetector: stopped")
    }

    // MARK: - Polling

    private func poll() {
        let nowInCall = detectBrowserCall()

        if nowInCall && !isInBrowserCall {
            isInBrowserCall = true
            Logger.general.info("BrowserCallDetector: browser meeting detected — posting callAppLaunched")
            postNotification(.callAppLaunched)
        } else if !nowInCall && isInBrowserCall {
            isInBrowserCall = false
            Logger.general.info("BrowserCallDetector: browser meeting ended — posting callAppTerminated")
            postNotification(.callAppTerminated)
        }
    }

    // MARK: - Detection Logic

    private func detectBrowserCall() -> Bool {
        // Only scan windows belonging to running browsers.
        let runningBrowserNames = Set(
            NSWorkspace.shared.runningApplications
                .compactMap { app -> String? in
                    guard let bundleID = app.bundleIdentifier,
                          CallAppRegistry.knownBrowsers[bundleID] != nil else { return nil }
                    return app.localizedName
                }
        )
        guard !runningBrowserNames.isEmpty else { return false }

        // CGWindowListCopyWindowInfo returns titles only when Screen Recording
        // permission is granted.  If titles are nil/empty we return false gracefully.
        let options = CGWindowListOption([.optionOnScreenOnly, .excludeDesktopElements])
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }

        for window in windowList {
            guard
                let ownerName = window[kCGWindowOwnerName as String] as? String,
                runningBrowserNames.contains(ownerName),
                let title = window[kCGWindowName as String] as? String,
                !title.isEmpty
            else { continue }

            if CallAppRegistry.browserMeetingKeywords.contains(where: { title.localizedCaseInsensitiveContains($0) }) {
                Logger.general.debug("BrowserCallDetector: matched window '\(title)' in '\(ownerName)'")
                return true
            }
        }
        return false
    }

    // MARK: - Notification

    private func postNotification(_ name: Notification.Name) {
        NotificationCenter.default.post(
            name: name,
            object: self,
            userInfo: [
                "appName": "Google Meet",
                "bundleIdentifier": "browser.googleMeet",
            ]
        )
    }
}

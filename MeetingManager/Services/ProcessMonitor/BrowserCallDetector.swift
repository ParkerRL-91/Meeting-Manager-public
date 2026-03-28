import AppKit
import Foundation
import os

/// Detects browser-based video calls (Google Meet, Zoom web, etc.) by polling
/// browser tab titles via AppleScript.
///
/// Posts `.callAppLaunched` when a meeting tab is found and `.callAppTerminated`
/// when no matching tabs remain.
///
/// Uses AppleScript (Automation permission) rather than CGWindowList (Screen Recording permission)
/// because Automation permission is easier to obtain and more reliably returns tab titles.
@MainActor
final class BrowserCallDetector {

    // MARK: - State

    private var pollTimer: Timer?
    private(set) var isInBrowserCall = false
    private(set) var detectedMeetingName: String?

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
        let result = detectBrowserCall()

        if result.inCall && !isInBrowserCall {
            isInBrowserCall = true
            detectedMeetingName = result.name
            Logger.general.info("BrowserCallDetector: meeting detected — \(result.name ?? "unknown")")
            postNotification(.callAppLaunched, meetingName: result.name)
        } else if !result.inCall && isInBrowserCall {
            isInBrowserCall = false
            Logger.general.info("BrowserCallDetector: meeting ended")
            postNotification(.callAppTerminated, meetingName: detectedMeetingName)
            detectedMeetingName = nil
        }
    }

    // MARK: - Detection Logic

    private struct DetectionResult {
        let inCall: Bool
        let name: String?
    }

    private func detectBrowserCall() -> DetectionResult {
        // Try Chrome first, then Safari
        if let match = checkChromeTabTitles() {
            return DetectionResult(inCall: true, name: match)
        }
        if let match = checkSafariTabTitles() {
            return DetectionResult(inCall: true, name: match)
        }
        return DetectionResult(inCall: false, name: nil)
    }

    /// Query Chrome tab titles via AppleScript. Returns the matched meeting name, or nil.
    private func checkChromeTabTitles() -> String? {
        guard NSWorkspace.shared.runningApplications.contains(where: {
            $0.bundleIdentifier == "com.google.Chrome"
        }) else { return nil }

        let script = """
        tell application "Google Chrome"
            set tabTitles to {}
            repeat with w in windows
                repeat with t in tabs of w
                    set end of tabTitles to title of t
                end repeat
            end repeat
            return tabTitles
        end tell
        """
        return runAppleScriptAndMatch(script)
    }

    /// Query Safari tab titles via AppleScript. Returns the matched meeting name, or nil.
    private func checkSafariTabTitles() -> String? {
        guard NSWorkspace.shared.runningApplications.contains(where: {
            $0.bundleIdentifier == "com.apple.Safari"
        }) else { return nil }

        let script = """
        tell application "Safari"
            set tabTitles to {}
            repeat with w in windows
                repeat with t in tabs of w
                    set end of tabTitles to name of t
                end repeat
            end repeat
            return tabTitles
        end tell
        """
        return runAppleScriptAndMatch(script)
    }

    /// Execute an AppleScript that returns a list of tab titles, then check for meeting keywords.
    private func runAppleScriptAndMatch(_ source: String) -> String? {
        guard let appleScript = NSAppleScript(source: source) else { return nil }

        var errorInfo: NSDictionary?
        let result = appleScript.executeAndReturnError(&errorInfo)

        if errorInfo != nil {
            // AppleScript failed — user may not have granted Automation permission.
            // This is expected on first run; macOS will prompt the user.
            return nil
        }

        // Result is an AEDescriptor list of strings
        let count = result.numberOfItems
        guard count > 0 else { return nil }

        for i in 1...count {
            guard let titleDescriptor = result.atIndex(i),
                  let title = titleDescriptor.stringValue,
                  !title.isEmpty else { continue }

            // Check against meeting keywords
            for keyword in CallAppRegistry.browserMeetingKeywords {
                if title.localizedCaseInsensitiveContains(keyword) {
                    return title
                }
            }

            // Also match Google Meet URL-style titles: "Meet - xxx-xxxx-xxx"
            if title.hasPrefix("Meet - ") || title.hasPrefix("Meet with ") {
                return title
            }
        }

        return nil
    }

    // MARK: - Notification

    private func postNotification(_ name: Notification.Name, meetingName: String? = nil) {
        let displayName = meetingName ?? "Google Meet"
        NotificationCenter.default.post(
            name: name,
            object: self,
            userInfo: [
                "appName": displayName,
                "bundleIdentifier": "browser.googleMeet",
            ]
        )
    }
}

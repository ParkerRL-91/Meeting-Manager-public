import AppKit
import CoreAudio
import Foundation
import os

/// Detects browser-based video calls (Google Meet, Zoom web, etc.)
///
/// Uses multiple detection strategies in order of reliability:
/// 1. AppleScript to read Chrome/Safari tab titles (needs Automation permission)
/// 2. CGWindowList to read window titles (needs Screen Recording permission)
/// 3. Check if a browser is using the microphone (needs no special permissions)
///
/// Posts `.callAppLaunched` / `.callAppTerminated` notifications.
@MainActor
final class BrowserCallDetector {

    // MARK: - State

    private var pollTimer: Timer?
    private(set) var isInBrowserCall = false
    private(set) var detectedMeetingName: String?
    private var pollCount = 0

    /// Number of consecutive "not in call" polls before we declare the call ended.
    /// At 5s intervals, 3 misses = 15 seconds of no-call before stop fires.
    /// This prevents false stops from transient detection glitches (tab switches,
    /// brief mic pauses, AppleScript timeouts, etc.).
    private let endedDebounceThreshold = 3
    private var consecutiveNotInCall = 0

    // MARK: - Lifecycle

    func start(interval: TimeInterval = 5) {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        pollTimer?.fire()
        fileLog("started (interval \(Int(interval))s, endDebounce=\(endedDebounceThreshold) polls)")
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        consecutiveNotInCall = 0
        if isInBrowserCall {
            isInBrowserCall = false
            postNotification(.callAppTerminated)
        }
    }

    // MARK: - Polling

    private func poll() {
        pollCount += 1
        let result = detectBrowserCall()

        if pollCount % 6 == 1 {
            fileLog("poll #\(pollCount) — inCall=\(result.inCall), name=\(result.name ?? "nil"), method=\(result.method)")
        }

        if result.inCall {
            // Reset the not-in-call counter whenever we see an active call
            consecutiveNotInCall = 0

            if !isInBrowserCall {
                // Transition: not in call → in call (immediate — no debounce on start)
                isInBrowserCall = true
                detectedMeetingName = result.name
                fileLog("DETECTED: \(result.name ?? "unknown") via \(result.method)")
                postNotification(.callAppLaunched, meetingName: result.name)
            }
        } else if isInBrowserCall {
            // Call was active but this poll says no call — increment debounce counter
            consecutiveNotInCall += 1

            if consecutiveNotInCall >= endedDebounceThreshold {
                // Confirmed: call has truly ended (N consecutive polls with no call)
                isInBrowserCall = false
                consecutiveNotInCall = 0
                fileLog("ENDED: \(detectedMeetingName ?? "unknown") (confirmed after \(endedDebounceThreshold) polls)")
                postNotification(.callAppTerminated, meetingName: detectedMeetingName)
                detectedMeetingName = nil
            } else {
                fileLog("Call may have ended — miss \(consecutiveNotInCall)/\(endedDebounceThreshold) (debouncing)")
            }
        }
    }

    // MARK: - Detection

    private struct DetectionResult {
        let inCall: Bool
        let name: String?
        let method: String
    }

    private func detectBrowserCall() -> DetectionResult {
        // Strategy 1: AppleScript (best — gives tab titles)
        if let match = checkChromeTabsViaAppleScript() {
            return DetectionResult(inCall: true, name: match, method: "AppleScript")
        }

        // Strategy 2: CGWindowList (needs Screen Recording permission)
        if let match = checkViaCGWindowList() {
            return DetectionResult(inCall: true, name: match, method: "CGWindowList")
        }

        // Strategy 3: Check if a browser is using the microphone (no permissions needed)
        if isBrowserUsingMicrophone() {
            return DetectionResult(inCall: true, name: "Browser Call", method: "MicUsage")
        }

        return DetectionResult(inCall: false, name: nil, method: "none")
    }

    // MARK: - Strategy 1: AppleScript

    private func checkChromeTabsViaAppleScript() -> String? {
        // Check Chrome
        if let match = checkBrowserTabsViaAppleScript(
            bundleID: "com.google.Chrome",
            script: """
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
        ) {
            return match
        }

        // Check Safari
        if let match = checkBrowserTabsViaAppleScript(
            bundleID: "com.apple.Safari",
            script: """
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
        ) {
            return match
        }

        return nil
    }

    /// Run an AppleScript to get tab titles from a browser and check for meeting keywords.
    private func checkBrowserTabsViaAppleScript(bundleID: String, script: String) -> String? {
        guard NSWorkspace.shared.runningApplications.contains(where: {
            $0.bundleIdentifier == bundleID
        }) else { return nil }

        guard let appleScript = NSAppleScript(source: script) else { return nil }
        var errorInfo: NSDictionary?
        let result = appleScript.executeAndReturnError(&errorInfo)
        if errorInfo != nil { return nil }

        let count = result.numberOfItems
        guard count > 0 else { return nil }

        for i in 1...count {
            guard let desc = result.atIndex(i), let title = desc.stringValue, !title.isEmpty else { continue }
            if matchesMeetingKeyword(title) { return title }
        }
        return nil
    }

    // MARK: - Strategy 2: CGWindowList

    private func checkViaCGWindowList() -> String? {
        let browserNames = Set(CallAppRegistry.knownBrowsers.values)
        let options = CGWindowListOption([.optionOnScreenOnly, .excludeDesktopElements])
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return nil }

        for w in list {
            guard let owner = w[kCGWindowOwnerName as String] as? String,
                  browserNames.contains(owner),
                  let title = w[kCGWindowName as String] as? String,
                  !title.isEmpty else { continue }
            if matchesMeetingKeyword(title) { return title }
        }
        return nil
    }

    // MARK: - Strategy 3: Browser Microphone Usage

    /// Set by AudioCaptureService when recording starts/stops, so this strategy
    /// can distinguish "we are using the mic" from "a browser is using the mic."
    static var appIsRecording = false

    /// Check if any browser process is currently using the microphone.
    /// This works without any special permissions — if Chrome/Safari has an active
    /// audio input stream, the user is likely in a call.
    ///
    /// **Important:** This heuristic only fires when Meeting Manager is NOT already
    /// recording. Once we're recording, our own mic usage makes
    /// `kAudioDevicePropertyDeviceIsRunningSomewhere` always true, which would
    /// falsely detect a "browser call" whenever any browser is open.
    private func isBrowserUsingMicrophone() -> Bool {
        // If we're already recording, our own mic usage makes this check unreliable.
        // Strategies 1 & 2 still work — they look at tab/window titles, not mic state.
        guard !Self.appIsRecording else { return false }

        let browserBundleIDs = Set(CallAppRegistry.knownBrowsers.keys)

        let browserIsRunning = NSWorkspace.shared.runningApplications.contains {
            guard let bid = $0.bundleIdentifier else { return false }
            return browserBundleIDs.contains(bid)
        }
        guard browserIsRunning else { return false }

        // Check if the default input device has active IO (someone is using the mic)
        var defaultDeviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0, nil,
            &size,
            &defaultDeviceID
        )
        guard status == noErr, defaultDeviceID != kAudioObjectUnknown else { return false }

        // Check if the device is running (has active IO)
        var isRunning: UInt32 = 0
        var runningSize = UInt32(MemoryLayout<UInt32>.size)
        var runningAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let runStatus = AudioObjectGetPropertyData(
            defaultDeviceID,
            &runningAddress,
            0, nil,
            &runningSize,
            &isRunning
        )
        return runStatus == noErr && isRunning != 0
    }

    // MARK: - Keyword Matching

    private func matchesMeetingKeyword(_ title: String) -> Bool {
        for keyword in CallAppRegistry.browserMeetingKeywords {
            if title.localizedCaseInsensitiveContains(keyword) { return true }
        }
        if title.hasPrefix("Meet - ") || title.hasPrefix("Meet with ") { return true }
        return false
    }

    // MARK: - Notification

    private func postNotification(_ name: Notification.Name, meetingName: String? = nil) {
        NotificationCenter.default.post(
            name: name,
            object: self,
            userInfo: [
                "appName": meetingName ?? "Google Meet",
                "bundleIdentifier": "browser.googleMeet",
            ]
        )
    }

    // MARK: - File Logging

    private func fileLog(_ message: String) {
        AppFileLogger.shared.log("BrowserDetector: \(message)")
    }
}

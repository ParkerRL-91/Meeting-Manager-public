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

    /// When Meeting Manager itself is recording, our own capture engine keeps
    /// the default input device active, so the mic-usage heuristic (strategy 1)
    /// reads "in call" forever and call-end detection can never fire. The owner
    /// wires this to AppState.isRecording; while true, strategy 1 is skipped
    /// and detection falls through to tab/window-title checks.
    var isRecordingProvider: (() -> Bool)?

    /// Number of consecutive "not in call" polls before we declare the call ended.
    /// At 5s intervals, 3 misses = 15 seconds of no-call before stop fires.
    /// This prevents false stops from transient detection glitches (tab switches,
    /// brief mic pauses, AppleScript timeouts, etc.).
    private let endedDebounceThreshold = 3
    private var consecutiveNotInCall = 0

    deinit {
        pollTimer?.invalidate()
    }

    // MARK: - Lifecycle

    func start(interval: TimeInterval = 10) {
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
        // Strategy 1: Check if a browser is using the microphone (cheapest, no
        // permissions needed). Suppressed while we're recording — our own
        // engine holds the input device, so the signal is always positive.
        if isRecordingProvider?() != true, isBrowserUsingMicrophone() {
            return DetectionResult(inCall: true, name: "Browser Call", method: "MicUsage")
        }

        // Strategy 2: AppleScript (gives tab titles — only runs if Chrome is actually running)
        let chromeRunning = NSWorkspace.shared.runningApplications
            .contains { $0.bundleIdentifier == "com.google.Chrome" }
        if chromeRunning, let match = checkChromeTabsViaAppleScript() {
            return DetectionResult(inCall: true, name: match, method: "AppleScript")
        }

        // Strategy 3: CGWindowList (last resort — requires Screen Recording permission)
        if let match = checkViaCGWindowList() {
            return DetectionResult(inCall: true, name: match, method: "CGWindowList")
        }

        return DetectionResult(inCall: false, name: nil, method: "none")
    }

    // MARK: - Strategy 1: AppleScript

    private func checkChromeTabsViaAppleScript() -> String? {
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
        guard let appleScript = NSAppleScript(source: script) else { return nil }
        var errorInfo: NSDictionary?
        let result = appleScript.executeAndReturnError(&errorInfo)
        if let errorInfo {
            // -1743 = errAEEventNotPermitted: Automation (Apple Events) permission
            // was denied. Browser tab-title detection is a fallback to calendar
            // (the primary participant source), so we degrade quietly to the
            // CGWindowList / mic-usage strategies rather than nagging — but log
            // it clearly so the cause is visible in diagnostics.
            if let code = errorInfo[NSAppleScript.errorNumber] as? Int, code == -1743 {
                Logger.general.info("BrowserCallDetector: Automation permission denied (errAEEventNotPermitted); falling back to window-title detection. Enable it in System Settings → Privacy & Security → Automation.")
            }
            return nil
        }

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
        let browserNames: Set<String> = ["Google Chrome", "Safari", "Firefox", "Microsoft Edge", "Brave Browser"]
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

    /// Check if any browser process is currently using the microphone.
    /// This works without any special permissions — if Chrome/Safari has an active
    /// audio input stream, the user is likely in a call.
    private func isBrowserUsingMicrophone() -> Bool {
        // Check if the default input device is being "hogged" or has active streams
        // from a browser process. A simpler heuristic: if a browser is running AND
        // the system's default input device is in use, the user is probably in a call.
        let browserBundleIDs: Set<String> = [
            "com.google.Chrome",
            "com.apple.Safari",
            "org.mozilla.firefox",
            "com.microsoft.edgemac",
            "com.brave.Browser",
        ]

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

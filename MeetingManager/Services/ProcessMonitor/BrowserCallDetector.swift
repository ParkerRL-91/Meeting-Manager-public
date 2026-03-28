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

    // MARK: - Lifecycle

    func start(interval: TimeInterval = 5) {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        pollTimer?.fire()
        fileLog("started (interval \(Int(interval))s)")
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
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

        if result.inCall && !isInBrowserCall {
            isInBrowserCall = true
            detectedMeetingName = result.name
            fileLog("DETECTED: \(result.name ?? "unknown") via \(result.method)")
            postNotification(.callAppLaunched, meetingName: result.name)
        } else if !result.inCall && isInBrowserCall {
            isInBrowserCall = false
            fileLog("ENDED: \(detectedMeetingName ?? "unknown")")
            postNotification(.callAppTerminated, meetingName: detectedMeetingName)
            detectedMeetingName = nil
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
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] BrowserDetector: \(message)\n"
        let logURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MeetingManager/app.log")
        if let data = line.data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: logURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        }
    }
}

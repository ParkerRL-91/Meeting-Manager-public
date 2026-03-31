import Foundation

/// Static registry of known video/voice call application bundle identifiers.
enum CallAppRegistry {
    /// Maps bundle identifiers to human-readable display names.
    /// Apps that are ONLY open during calls — detecting their launch means a call started.
    /// Slack and Discord are excluded because they run all the time, not just during calls.
    static let knownApps: [String: String] = [
        // Zoom (multiple bundle IDs across versions)
        "us.zoom.xos": "Zoom",
        "us.zoom.videomeetings": "Zoom",
        "us.zoom.CptHost": "Zoom",
        // Microsoft Teams
        "com.microsoft.teams": "Microsoft Teams",
        "com.microsoft.teams2": "Microsoft Teams",
        "MSTeams": "Microsoft Teams",
        // Apple
        "com.apple.FaceTime": "FaceTime",
        // Cisco
        "com.cisco.webexmeetingsapp": "Webex",
        "com.cisco.webex.meetings": "Webex",
        // Others
        "com.skype.skype": "Skype",
        "com.loom.desktop": "Loom",
        "com.ringcentral.glip": "RingCentral",
        "com.bluejeans.BlueJeans": "BlueJeans",
        "com.goto.GoToMeeting": "GoToMeeting",
        "com.pop.pop.app": "Pop",
        "com.around.around": "Around",
    ]

    /// Bundle IDs of browsers we scan for browser-based meeting windows (Google Meet, etc.).
    static let knownBrowsers: [String: String] = [
        "com.google.Chrome": "Google Chrome",
        "com.apple.Safari": "Safari",
        "com.microsoft.edgemac": "Microsoft Edge",
        "org.mozilla.firefox": "Firefox",
        "com.brave.Browser": "Brave Browser",
        "com.operasoftware.Opera": "Opera",
        "com.google.Chrome.canary": "Google Chrome Canary",
        "company.thebrowser.Browser": "Arc",
        "com.vivaldi.Vivaldi": "Vivaldi",
    ]

    /// Window title substrings that indicate an active browser-based meeting.
    static let browserMeetingKeywords: [String] = [
        "Google Meet",
        "meet.google.com",
        "Zoom Meeting",
        "Zoom - ",
        "Microsoft Teams",
        "Webex Meeting",
        "BlueJeans",
        "GoToMeeting",
        "Whereby",
        "Around ",
        "Jitsi Meet",
    ]

    /// Returns `true` if the given bundle identifier belongs to a known call app.
    static func isCallApp(bundleIdentifier: String) -> Bool {
        knownApps[bundleIdentifier] != nil
    }

    /// Returns the human-readable display name for a known call app, or `nil` if unrecognized.
    static func displayName(for bundleIdentifier: String) -> String? {
        knownApps[bundleIdentifier]
    }
}

import Foundation

/// Static registry of known video/voice call application bundle identifiers.
enum CallAppRegistry {
    /// Maps bundle identifiers to human-readable display names.
    static let knownApps: [String: String] = [
        "us.zoom.xos": "Zoom",
        "com.microsoft.teams": "Microsoft Teams",
        "com.microsoft.teams2": "Microsoft Teams",
        "com.apple.FaceTime": "FaceTime",
        "com.cisco.webexmeetingsapp": "Webex",
        "com.tinyspeck.slackmacgap": "Slack"
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

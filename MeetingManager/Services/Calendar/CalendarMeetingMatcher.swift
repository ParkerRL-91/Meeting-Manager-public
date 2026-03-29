import Foundation
import os

/// Matches a detected meeting to a Google Calendar event to pull the meeting title and participant names.
///
/// This doesn't use the Google Calendar API directly (that requires OAuth). Instead, it reads
/// the local macOS Calendar store or relies on the meeting title detected from the browser tab.
///
/// The matching is done by the host (Claude/MCP) when available, and the results are stored
/// in the Meeting model's `title` and `participants` fields.
@MainActor
final class CalendarMeetingMatcher {

    /// Try to enrich a meeting with calendar data: title and participant names.
    /// Returns the enriched title and comma-separated participants, or nil if no match.
    static func enrichFromBrowserTitle(_ browserTitle: String?) -> (title: String, participants: String?)? {
        guard let browserTitle, !browserTitle.isEmpty else { return nil }

        // Browser tab titles from Google Meet look like:
        //   "Meet with Parker"
        //   "Meet - pfi-qvby-nnt"
        //   "Weekly 1:1 - Google Meet"
        //   "Team Standup"

        var title = browserTitle

        // Clean up common prefixes/suffixes
        if title.hasPrefix("Meet with ") {
            // "Meet with Parker" → keep the name, use as participant hint
            let name = String(title.dropFirst("Meet with ".count))
            return (title: "\(name) Meeting", participants: name)
        }

        if title.hasPrefix("Meet - ") {
            // "Meet - pfi-qvby-nnt" → generic meeting code, not useful as title
            return nil
        }

        // Remove " - Google Meet" suffix
        if title.hasSuffix(" - Google Meet") {
            title = String(title.dropLast(" - Google Meet".count))
        }

        // If we got a meaningful title, use it
        if !title.isEmpty && title.count > 2 {
            return (title: title, participants: nil)
        }

        return nil
    }

    /// Format participant names for display.
    /// Input: ["parker@acme.com", "morgan@acme.com"]
    /// Output: "Parker, Morgan"
    static func formatParticipants(_ emails: [String]) -> String {
        emails.compactMap { email in
            // Extract name from email: "parker@acme.com" → "Parker"
            let local = email.components(separatedBy: "@").first ?? email
            return local.prefix(1).uppercased() + local.dropFirst()
        }.joined(separator: ", ")
    }
}

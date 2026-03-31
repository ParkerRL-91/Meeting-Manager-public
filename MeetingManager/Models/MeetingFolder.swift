import Foundation

/// A virtual grouping of meetings that share the same recurring base title.
/// Folders are computed on-the-fly — not persisted in the database.
struct MeetingFolder: Identifiable {
    /// Stable key derived from the normalised title — used as folder identifier.
    let key: String
    /// Human-readable title shown in the UI.
    let displayName: String
    /// All meetings in this series, sorted newest-first.
    let meetings: [Meeting]

    var id: String { key }
    var meetingCount: Int { meetings.count }
    var lastMeetingDate: Date? { meetings.first?.effectiveDate }
    var participants: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for m in meetings {
            for p in m.participantList {
                if seen.insert(p).inserted { result.append(p) }
            }
        }
        return result
    }

    // MARK: - Title Normalisation

    /// Strips dates, numbers, and common suffixes so "Weekly Standup 1/15" and
    /// "Weekly Standup 1/22" both collapse to the key "weekly standup".
    static func normaliseTitle(_ title: String) -> String {
        var s = title.lowercased()
        // Remove ISO dates: 2024-01-15
        s = s.replacingOccurrences(of: #"\d{4}-\d{2}-\d{2}"#, with: "", options: .regularExpression)
        // Remove slash dates: 1/15, 01/22
        s = s.replacingOccurrences(of: #"\b\d{1,2}/\d{1,2}(/\d{2,4})?\b"#, with: "", options: .regularExpression)
        // Remove trailing parenthetical: (Q1), (Week 3)
        s = s.replacingOccurrences(of: #"\s*\([^)]*\)\s*$"#, with: "", options: .regularExpression)
        // Remove trailing "- date" patterns
        s = s.replacingOccurrences(of: #"\s*[-–]\s*\d.*$"#, with: "", options: .regularExpression)
        // Remove leading/trailing punctuation and whitespace
        s = s.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return s.isEmpty ? title.lowercased() : s
    }

    /// Returns a display-friendly version of the title (original capitalisation, stripped suffixes).
    static func displayName(for title: String) -> String {
        var s = title
        s = s.replacingOccurrences(of: #"\d{4}-\d{2}-\d{2}"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\b\d{1,2}/\d{1,2}(/\d{2,4})?\b"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s*\([^)]*\)\s*$"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s*[-–]\s*\d.*$"#, with: "", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return s.isEmpty ? title : s
    }
}

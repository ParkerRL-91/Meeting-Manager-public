import Foundation
import os

/// Heuristic detector for meeting series — surfaces previous sessions that
/// share the same group, so MeetingDetailView can show "Previous sessions"
/// and the summary prompt can carry forward unfinished action items.
///
/// Two meetings are considered part of the same series when at least two of
/// the following match: normalized title, participant set (±1 person), and
/// regular weekly/biweekly cadence. Cadence inference is implicit — we sort
/// candidates by date so the caller can read the deltas.
@MainActor
final class MeetingSeriesService {
    static let shared = MeetingSeriesService()
    private let logger = Logger(subsystem: "com.meetingmanager.app", category: "MeetingSeries")
    private init() {}

    /// Returns prior sessions in the same series, most recent first.
    /// Excludes the meeting itself and any future occurrences.
    func detectSeries(for meeting: Meeting, in candidates: [Meeting]) -> [Meeting] {
        let anchorDate = meeting.scheduledStartDate ?? meeting.startDate ?? meeting.createdAt
        let pairs = candidates.filter { other in
            guard other.id != meeting.id else { return false }
            let otherDate = other.scheduledStartDate ?? other.startDate ?? other.createdAt
            // Only past sessions
            guard otherDate < anchorDate else { return false }
            var matchCount = 0
            if titlesMatch(meeting.title, other.title) { matchCount += 1 }
            if participantSetsMatch(meeting.participantList, other.participantList) { matchCount += 1 }
            return matchCount >= 2
        }
        return pairs.sorted {
            ($0.scheduledStartDate ?? $0.startDate ?? .distantPast)
                > ($1.scheduledStartDate ?? $1.startDate ?? .distantPast)
        }
    }

    /// Series display name — capitalized normalized title, or a participant-based fallback.
    func seriesName(for meeting: Meeting, in series: [Meeting]) -> String {
        let normalized = normalize(meeting.title)
        if !normalized.isEmpty { return normalized.capitalized }
        let participants = meeting.participantList.prefix(2).joined(separator: ", ")
        return participants.isEmpty ? "Recurring meeting" : "Recurring with \(participants)"
    }

    // MARK: - Heuristics

    private func titlesMatch(_ a: String, _ b: String) -> Bool {
        let an = normalize(a)
        let bn = normalize(b)
        guard !an.isEmpty, !bn.isEmpty else { return false }
        return an == bn
    }

    /// Lowercase, strip ordinal/date suffixes that recurring calendar series often append.
    private func normalize(_ title: String) -> String {
        var t = title.lowercased()
        let patterns = [
            "\\s*\\(\\d+\\)$",                  // "(1)", "(2)"
            "\\s*#\\d+$",                       // "#3"
            "\\s*-\\s*\\w+\\s+\\d+$",           // "- April 27"
            "\\s*/\\s*\\w+\\s+\\d+$",           // "/ Apr 27"
            "\\s*\\d{1,2}/\\d{1,2}(/\\d{2,4})?$" // "4/27", "4/27/2026"
        ]
        for p in patterns {
            if let r = try? NSRegularExpression(pattern: p) {
                t = r.stringByReplacingMatches(
                    in: t,
                    range: NSRange(t.startIndex..., in: t),
                    withTemplate: ""
                )
            }
        }
        let trimSet = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        return t.trimmingCharacters(in: trimSet)
    }

    private func participantSetsMatch(_ a: [String], _ b: [String]) -> Bool {
        let setA = Set(a.map { $0.lowercased().trimmingCharacters(in: .whitespaces) })
        let setB = Set(b.map { $0.lowercased().trimmingCharacters(in: .whitespaces) })
        guard !setA.isEmpty, !setB.isEmpty else { return false }
        let symDiff = setA.symmetricDifference(setB)
        return symDiff.count <= 1
    }
}

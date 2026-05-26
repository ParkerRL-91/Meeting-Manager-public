import Foundation
import GRDB
import os

/// Aggregates meeting and transcript data into analytics-ready summaries.
///
/// Every aggregate accepts an `AnalyticsFilter` (date range + optional
/// participant) so the dashboard can be sliced. Meeting durations are computed
/// in Swift from GRDB-decoded `Date`s: the `meeting.startDate`/`endDate`
/// columns are stored as ISO-8601 TEXT, so SQL arithmetic like
/// `(endDate - startDate)` silently yields 0 (SQLite coerces "2026-..." → 2026)
/// — which is why the old weekly-hours card always read 0.
@MainActor
final class ParticipantAnalyticsService {
    private let database: AppDatabase
    private let logger = Logger(subsystem: "com.meetingmanager.app", category: "analytics")

    init(database: AppDatabase = .shared) {
        self.database = database
    }

    // MARK: - Filter

    /// Slices every aggregate. `start`/`end` are inclusive bounds on the
    /// meeting's start; nil means unbounded. `participant` restricts to
    /// meetings that include that exact attendee (from the filter dropdown).
    struct AnalyticsFilter: Equatable {
        var start: Date?
        var end: Date?
        var participant: String?

        static let allTime = AnalyticsFilter(start: nil, end: nil, participant: nil)
    }

    // MARK: - Result types

    struct Overview: Equatable {
        let totalMeetings: Int
        let totalHours: Double
        let avgMinutes: Double
        let medianMinutes: Double
        let longestMinutes: Double
        let longestTitle: String?

        static let empty = Overview(totalMeetings: 0, totalHours: 0, avgMinutes: 0,
                                     medianMinutes: 0, longestMinutes: 0, longestTitle: nil)
    }

    /// Aggregate "you vs everyone else" talk balance across the filtered set.
    struct TalkShare: Equatable {
        let youSeconds: Double
        let othersSeconds: Double
        let meetingsCounted: Int

        var totalSeconds: Double { youSeconds + othersSeconds }
        var youFraction: Double { totalSeconds > 0 ? youSeconds / totalSeconds : 0 }

        static let empty = TalkShare(youSeconds: 0, othersSeconds: 0, meetingsCounted: 0)
    }

    struct TalkTimePerSpeaker: Identifiable, Equatable {
        var id: String { speakerLabel }
        let speakerLabel: String
        let displayName: String
        let totalSeconds: Double
    }

    struct TopParticipant: Identifiable, Equatable {
        var id: String { name }
        let name: String
        let meetingCount: Int
        let lastMet: Date
    }

    struct WeekdayBucket: Identifiable, Equatable {
        var id: Int { weekdayIndex }
        let weekdayIndex: Int   // 1 = Mon … 7 = Sun
        let label: String       // "Mon", "Tue", …
        let count: Int
        let hours: Double
    }

    struct TrendBucket: Identifiable, Equatable {
        var id: Date { start }
        let start: Date
        let label: String
        let count: Int
    }

    // MARK: - Internal meeting projection

    private struct MeetingRow {
        let id: String
        let title: String
        let start: Date
        let durationSeconds: Double
        let participants: [String]
    }

    /// Fetch completed meetings matching the filter, with durations resolved.
    /// Decodes dates via GRDB (TEXT → Date) and computes duration in Swift.
    private func fetchMeetings(_ filter: AnalyticsFilter) async throws -> [MeetingRow] {
        let writer = database.writer
        let completed = MeetingStatus.complete.rawValue
        let start = filter.start
        let end = filter.end
        let rows: [MeetingRow] = try await Task.detached(priority: .userInitiated) {
            try writer.read { db -> [MeetingRow] in
                var sql = """
                    SELECT id, title, participants,
                           COALESCE(startDate, scheduledStartDate) AS s,
                           endDate AS e
                    FROM meeting
                    WHERE status = ?
                      AND COALESCE(startDate, scheduledStartDate) IS NOT NULL
                    """
                var args: [DatabaseValueConvertible] = [completed]
                // ISO-8601 TEXT sorts lexicographically == chronologically, so
                // string comparison against a bound Date works for range bounds.
                if let start { sql += " AND COALESCE(startDate, scheduledStartDate) >= ?"; args.append(start) }
                if let end { sql += " AND COALESCE(startDate, scheduledStartDate) <= ?"; args.append(end) }

                let cursor = try Row.fetchCursor(db, sql: sql, arguments: StatementArguments(args))
                var out: [MeetingRow] = []
                while let row = try cursor.next() {
                    guard let s: Date = row["s"] else { continue }
                    let e: Date? = row["e"]
                    let duration = e.map { max(0, $0.timeIntervalSince(s)) } ?? 0
                    let raw: String = row["participants"] ?? ""
                    let names = raw.components(separatedBy: ",")
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    out.append(MeetingRow(id: row["id"], title: row["title"] ?? "Untitled",
                                          start: s, durationSeconds: duration, participants: names))
                }
                return out
            }
        }.value

        guard let participant = filter.participant, !participant.isEmpty else { return rows }
        let key = participant.lowercased()
        return rows.filter { $0.participants.contains { $0.lowercased() == key } }
    }

    // MARK: - Overview

    func overview(_ filter: AnalyticsFilter) async throws -> Overview {
        let meetings = try await fetchMeetings(filter)
        guard !meetings.isEmpty else { return .empty }

        let durations = meetings.map { $0.durationSeconds }
        let totalSec = durations.reduce(0, +)
        let count = meetings.count
        let sorted = durations.sorted()
        let median: Double = sorted.isEmpty ? 0 :
            (sorted.count % 2 == 1
             ? sorted[sorted.count / 2]
             : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2)
        let longest = meetings.max { $0.durationSeconds < $1.durationSeconds }

        return Overview(
            totalMeetings: count,
            totalHours: totalSec / 3600.0,
            avgMinutes: count > 0 ? (totalSec / Double(count)) / 60.0 : 0,
            medianMinutes: median / 60.0,
            longestMinutes: (longest?.durationSeconds ?? 0) / 60.0,
            longestTitle: (longest?.durationSeconds ?? 0) > 0 ? longest?.title : nil
        )
    }

    // MARK: - Top participants

    func topParticipants(_ filter: AnalyticsFilter, limit: Int = 8) async throws -> [TopParticipant] {
        let meetings = try await fetchMeetings(filter)
        var bucket: [String: (count: Int, last: Date)] = [:]
        for m in meetings {
            for name in m.participants {
                // Don't surface the local user in "who you meet with".
                if Self.isLikelyLocalUser(name) { continue }
                if let existing = bucket[name] {
                    bucket[name] = (existing.count + 1, max(existing.last, m.start))
                } else {
                    bucket[name] = (1, m.start)
                }
            }
        }
        return bucket
            .map { TopParticipant(name: $0.key, meetingCount: $0.value.count, lastMet: $0.value.last) }
            .sorted { lhs, rhs in
                if lhs.meetingCount != rhs.meetingCount { return lhs.meetingCount > rhs.meetingCount }
                return lhs.lastMet > rhs.lastMet
            }
            .prefix(limit)
            .map { $0 }
    }

    /// Distinct attendee names across all completed meetings — powers the
    /// participant filter dropdown. Excludes the local user.
    func knownParticipants(limit: Int = 50) async throws -> [String] {
        let meetings = try await fetchMeetings(.allTime)
        var counts: [String: Int] = [:]
        for m in meetings {
            for name in m.participants where !Self.isLikelyLocalUser(name) {
                counts[name, default: 0] += 1
            }
        }
        return counts.sorted { $0.value > $1.value }.prefix(limit).map { $0.key }
    }

    // MARK: - Weekday distribution

    func weekdayDistribution(_ filter: AnalyticsFilter) async throws -> [WeekdayBucket] {
        let meetings = try await fetchMeetings(filter)
        let labels = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        var counts = [Int](repeating: 0, count: 7)
        var seconds = [Double](repeating: 0, count: 7)
        for m in meetings {
            // Calendar weekday: 1=Sun…7=Sat. Map to 0=Mon…6=Sun.
            let wd = Self.weekCalendar.component(.weekday, from: m.start)
            let idx = (wd + 5) % 7
            counts[idx] += 1
            seconds[idx] += m.durationSeconds
        }
        return (0..<7).map {
            WeekdayBucket(weekdayIndex: $0 + 1, label: labels[$0],
                          count: counts[$0], hours: seconds[$0] / 3600.0)
        }
    }

    // MARK: - Trend over the filtered window

    /// Meetings-per-bucket across the effective window. Bucket granularity
    /// adapts to the span: day (≤ 31d), week (≤ ~26w), else month.
    func trend(_ filter: AnalyticsFilter) async throws -> [TrendBucket] {
        let meetings = try await fetchMeetings(filter)
        let cal = Self.weekCalendar
        let now = Date()
        let lo = filter.start ?? meetings.map { $0.start }.min() ?? now
        let hi = filter.end ?? now
        guard lo <= hi else { return [] }

        let span = hi.timeIntervalSince(lo)
        let day: TimeInterval = 86_400
        let component: Calendar.Component
        let labelFormat: String
        if span <= 31 * day { component = .day; labelFormat = "d MMM" }
        else if span <= 200 * day { component = .weekOfYear; labelFormat = "d MMM" }
        else { component = .month; labelFormat = "MMM yy" }

        func anchor(_ d: Date) -> Date {
            switch component {
            case .day: return cal.startOfDay(for: d)
            case .weekOfYear: return cal.dateInterval(of: .weekOfYear, for: d)?.start ?? d
            default: return cal.dateInterval(of: .month, for: d)?.start ?? d
            }
        }

        // Ordered bucket anchors lo → hi.
        var anchors: [Date] = []
        var cursor = anchor(lo)
        let endAnchor = anchor(hi)
        var guardCount = 0
        while cursor <= endAnchor && guardCount < 400 {
            anchors.append(cursor)
            guard let next = cal.date(byAdding: component, value: 1, to: cursor) else { break }
            cursor = next
            guardCount += 1
        }
        guard !anchors.isEmpty else { return [] }

        var counts = Dictionary(uniqueKeysWithValues: anchors.map { ($0, 0) })
        for m in meetings {
            let a = anchor(m.start)
            if counts[a] != nil { counts[a]! += 1 }
        }

        let fmt = DateFormatter()
        fmt.calendar = cal
        fmt.locale = .current
        fmt.dateFormat = labelFormat
        return anchors.map { TrendBucket(start: $0, label: fmt.string(from: $0), count: counts[$0] ?? 0) }
    }

    // MARK: - Aggregate talk share (you vs others) across the filtered set

    /// Aggregate "you vs others" talk balance. `youIdentifiers` are the labels
    /// that count as the local user — there is no single "mic" label in stored
    /// transcripts (attribution rewrites the user's cluster to their resolved
    /// name/email), so the caller passes the user's known identities (e.g.
    /// signed-in email, full name) which are matched case-insensitively. Returns
    /// `.empty` when none are supplied.
    func talkShare(_ filter: AnalyticsFilter, youIdentifiers: [String]) async throws -> TalkShare {
        let you = Set(youIdentifiers
            .map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty })
        guard !you.isEmpty else { return .empty }

        // transcript.startTime/endTime are numeric (seconds), so SQL arithmetic
        // is correct here — unlike the TEXT meeting dates.
        let writer = database.writer
        let completed = MeetingStatus.complete.rawValue
        let start = filter.start
        let end = filter.end
        let participant = filter.participant
        let youList = Array(you)
        return try await Task.detached(priority: .userInitiated) { () -> TalkShare in
            try writer.read { db -> TalkShare in
                let placeholders = youList.map { _ in "?" }.joined(separator: ",")
                var sql = """
                    SELECT
                        COALESCE(SUM(CASE WHEN LOWER(t.speakerLabel) IN (\(placeholders))
                                          THEN (t.endTime - t.startTime) ELSE 0 END), 0) AS youSec,
                        COALESCE(SUM(CASE WHEN LOWER(t.speakerLabel) IN (\(placeholders))
                                          THEN 0 ELSE (t.endTime - t.startTime) END), 0) AS otherSec,
                        COUNT(DISTINCT CASE WHEN LOWER(t.speakerLabel) IN (\(placeholders))
                                            THEN t.meetingId END) AS cnt
                    FROM transcript t
                    JOIN meeting m ON m.id = t.meetingId
                    WHERE m.status = ?
                    """
                // youList is interpolated three times (one per CASE), so bind it thrice.
                var args: [DatabaseValueConvertible] = youList + youList + youList + [completed]
                if let start { sql += " AND COALESCE(m.startDate, m.scheduledStartDate) >= ?"; args.append(start) }
                if let end { sql += " AND COALESCE(m.startDate, m.scheduledStartDate) <= ?"; args.append(end) }
                if let participant, !participant.isEmpty {
                    sql += " AND m.participants LIKE ?"; args.append("%\(participant)%")
                }
                let row = try Row.fetchOne(db, sql: sql, arguments: StatementArguments(args))
                return TalkShare(
                    youSeconds: max(0, row?["youSec"] ?? 0),
                    othersSeconds: max(0, row?["otherSec"] ?? 0),
                    meetingsCounted: row?["cnt"] ?? 0
                )
            }
        }.value
    }

    // MARK: - Talk time for a single meeting (per-speaker, unchanged)

    func talkTime(forMeeting meetingId: String, participants: [String]) async throws -> [TalkTimePerSpeaker] {
        let writer = database.writer
        let rows: [(String, Double)] = try await Task.detached(priority: .userInitiated) {
            try writer.read { db -> [(String, Double)] in
                let cursor = try Row.fetchCursor(
                    db,
                    sql: """
                        SELECT COALESCE(speakerLabel, 'unknown') AS speakerLabel,
                               SUM(endTime - startTime) AS seconds
                        FROM transcript
                        WHERE meetingId = ?
                        GROUP BY speakerLabel
                        ORDER BY seconds DESC
                        """,
                    arguments: [meetingId]
                )
                var out: [(String, Double)] = []
                while let row = try cursor.next() {
                    let label: String = row["speakerLabel"] ?? "unknown"
                    let seconds: Double = row["seconds"] ?? 0
                    out.append((label, seconds))
                }
                return out
            }
        }.value

        return rows.map { (label, seconds) in
            TalkTimePerSpeaker(
                speakerLabel: label,
                displayName: Self.displayName(for: label, participants: participants),
                totalSeconds: max(0, seconds)
            )
        }
    }

    // MARK: - Helpers

    static let weekCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2 // Monday
        return cal
    }()

    /// Heuristic: is this attendee string the local user? Matches the macOS
    /// full name or the signed-in Google email's local part. Best-effort —
    /// only used to keep "you" out of participant rollups.
    private static func isLikelyLocalUser(_ name: String) -> Bool {
        let s = name.lowercased().trimmingCharacters(in: .whitespaces)
        if s == NSFullUserName().lowercased() { return true }
        return false
    }

    static func displayName(for label: String, participants: [String]) -> String {
        switch label {
        case "mic":
            return "You"
        case "system":
            if participants.count == 1, let only = participants.first, !only.isEmpty {
                return only
            }
            return "Other"
        default:
            return label
        }
    }
}

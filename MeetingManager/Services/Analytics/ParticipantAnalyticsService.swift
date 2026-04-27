import Foundation
import GRDB
import os

/// Aggregates meeting and transcript data into analytics-ready summaries.
///
/// All queries run on the shared `AppDatabase` writer's read-pool. Aggregates that
/// don't translate cleanly into SQL (e.g. parsing the comma-separated `participants`
/// column on the `meeting` table) are computed in Swift after fetching the rows.
@MainActor
final class ParticipantAnalyticsService {
    private let database: AppDatabase
    private let logger = Logger(subsystem: "com.meetingmanager.app", category: "analytics")

    init(database: AppDatabase = .shared) {
        self.database = database
    }

    // MARK: - Result types

    struct WeeklyStats: Equatable {
        let totalHours: Double
        let count: Int
        let avgMinutes: Double

        static let empty = WeeklyStats(totalHours: 0, count: 0, avgMinutes: 0)
    }

    struct TalkTimePerSpeaker: Identifiable, Equatable {
        var id: String { speakerLabel }
        let speakerLabel: String   // raw label from transcript ("mic", "system", future "Speaker N")
        let displayName: String    // resolved label for UI ("You", participant name, "Other")
        let totalSeconds: Double
    }

    struct TopParticipant: Identifiable, Equatable {
        var id: String { name }
        let name: String
        let meetingCount: Int
        let lastMet: Date
    }

    struct MeetingTrendBucket: Identifiable, Equatable {
        var id: Date { weekStart }
        let weekStart: Date
        let count: Int
    }

    // MARK: - Weekly stats (this week, Mon-Sun)

    func weeklyStats() async throws -> WeeklyStats {
        let weekStart = Self.startOfCurrentWeek()
        let writer = database.writer
        return try await Task.detached(priority: .userInitiated) { () -> WeeklyStats in
            try writer.read { db -> WeeklyStats in
                // Sum (endDate - startDate) in seconds for completed meetings since weekStart.
                let row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT
                            COUNT(*) AS cnt,
                            COALESCE(SUM(CASE
                                WHEN startDate IS NOT NULL AND endDate IS NOT NULL
                                THEN (endDate - startDate)
                                ELSE 0
                            END), 0) AS totalSec
                        FROM meeting
                        WHERE status = ?
                          AND startDate IS NOT NULL
                          AND startDate >= ?
                        """,
                    arguments: [MeetingStatus.complete.rawValue, weekStart]
                )
                let count: Int = row?["cnt"] ?? 0
                let totalSec: Double = row?["totalSec"] ?? 0
                let totalHours = totalSec / 3600.0
                let avgMinutes: Double = count > 0 ? (totalSec / Double(count)) / 60.0 : 0
                return WeeklyStats(totalHours: totalHours, count: count, avgMinutes: avgMinutes)
            }
        }.value
    }

    // MARK: - Talk time for a single meeting

    func talkTime(forMeeting meetingId: String, participants: [String]) async throws -> [TalkTimePerSpeaker] {
        let writer = database.writer
        let rows: [(String, Double)] = try await Task.detached(priority: .userInitiated) {
            try writer.read { db -> [(String, Double)] in
                let cursor = try Row.fetchCursor(
                    db,
                    sql: """
                        SELECT
                            COALESCE(speakerLabel, 'unknown') AS speakerLabel,
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

    // MARK: - Top participants (parses participants column client-side)

    func topParticipants(limit: Int = 8) async throws -> [TopParticipant] {
        let writer = database.writer
        let pairs: [(String, Date)] = try await Task.detached(priority: .userInitiated) {
            try writer.read { db -> [(String, Date)] in
                let cursor = try Row.fetchCursor(
                    db,
                    sql: """
                        SELECT participants, COALESCE(endDate, startDate, scheduledStartDate) AS metAt
                        FROM meeting
                        WHERE status = ?
                          AND participants IS NOT NULL
                          AND participants <> ''
                          AND COALESCE(endDate, startDate, scheduledStartDate) IS NOT NULL
                        """,
                    arguments: [MeetingStatus.complete.rawValue]
                )
                var out: [(String, Date)] = []
                while let row = try cursor.next() {
                    let raw: String = row["participants"] ?? ""
                    guard let metAt: Date = row["metAt"] else { continue }
                    out.append((raw, metAt))
                }
                return out
            }
        }.value

        // Aggregate in Swift: split comma-separated names, count occurrences, track last-met.
        var bucket: [String: (count: Int, last: Date)] = [:]
        for (raw, metAt) in pairs {
            let names = raw
                .components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            for name in names {
                if let existing = bucket[name] {
                    bucket[name] = (existing.count + 1, max(existing.last, metAt))
                } else {
                    bucket[name] = (1, metAt)
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

    // MARK: - Meeting trend (count per week, last N weeks)

    func meetingTrend(weeksBack: Int = 8) async throws -> [MeetingTrendBucket] {
        let calendar = Self.weekCalendar
        let now = Date()
        // Build ordered list of week-start anchors, oldest -> newest.
        var weekStarts: [Date] = []
        guard let currentWeekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start else {
            return []
        }
        for offset in stride(from: weeksBack - 1, through: 0, by: -1) {
            if let d = calendar.date(byAdding: .weekOfYear, value: -offset, to: currentWeekStart) {
                weekStarts.append(d)
            }
        }
        guard let earliest = weekStarts.first else { return [] }

        let writer = database.writer
        let dates: [Date] = try await Task.detached(priority: .userInitiated) {
            try writer.read { db -> [Date] in
                let cursor = try Row.fetchCursor(
                    db,
                    sql: """
                        SELECT COALESCE(startDate, scheduledStartDate) AS d
                        FROM meeting
                        WHERE status = ?
                          AND COALESCE(startDate, scheduledStartDate) IS NOT NULL
                          AND COALESCE(startDate, scheduledStartDate) >= ?
                        """,
                    arguments: [MeetingStatus.complete.rawValue, earliest]
                )
                var out: [Date] = []
                while let row = try cursor.next() {
                    if let d: Date = row["d"] { out.append(d) }
                }
                return out
            }
        }.value

        var counts: [Date: Int] = Dictionary(uniqueKeysWithValues: weekStarts.map { ($0, 0) })
        for date in dates {
            if let bucketStart = calendar.dateInterval(of: .weekOfYear, for: date)?.start,
               counts[bucketStart] != nil {
                counts[bucketStart, default: 0] += 1
            }
        }
        return weekStarts.map { MeetingTrendBucket(weekStart: $0, count: counts[$0] ?? 0) }
    }

    // MARK: - Helpers

    private static let weekCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2 // Monday
        return cal
    }()

    private static func startOfCurrentWeek() -> Date {
        weekCalendar.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()
    }

    /// Maps a raw transcript speakerLabel to a friendly display name.
    /// - "mic" → "You"
    /// - "system" → the single participant name when known, else "Other"
    /// - anything else → returned as-is (future "Speaker 1" etc.)
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

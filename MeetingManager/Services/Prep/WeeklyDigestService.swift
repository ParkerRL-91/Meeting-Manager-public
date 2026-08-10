import Foundation
import GRDB
import os

// MARK: - Weekly digest (TASK-051, migration v49)

/// One generated digest per ISO week, persisted so Home can render it
/// without the KB write-back setting being on (review M5).
struct WeeklyDigestRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "weeklyDigest"
    var isoWeek: String        // "2026-W24"
    var content: String
    var createdAt: Date
}

final class WeeklyDigestRepository {
    private let database: AppDatabase
    init(database: AppDatabase) { self.database = database }

    func digest(isoWeek: String) async throws -> WeeklyDigestRecord? {
        try await database.writer.read { db in try WeeklyDigestRecord.fetchOne(db, key: isoWeek) }
    }

    func latest() async throws -> WeeklyDigestRecord? {
        try await database.writer.read { db in
            try WeeklyDigestRecord.order(Column("createdAt").desc).fetchOne(db)
        }
    }

    /// The review for the most recent WEEK — distinct from `latest()`, which
    /// orders by `createdAt` and so ranks a just-refreshed old week above a
    /// newer one. ISO week ids ("2026-W31") sort chronologically as strings.
    func newest() async throws -> WeeklyDigestRecord? {
        try await database.writer.read { db in
            try WeeklyDigestRecord.order(Column("isoWeek").desc).fetchOne(db)
        }
    }

    func save(_ record: WeeklyDigestRecord) async throws {
        try await database.writer.write { db in try record.save(db) }
    }
}

enum WeeklyDigest {
    /// ISO week id ("2026-W24") for a date.
    static func isoWeek(for date: Date = Date()) -> String {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = .current
        let week = cal.component(.weekOfYear, from: date)
        let year = cal.component(.yearForWeekOfYear, from: date)
        return String(format: "%d-W%02d", year, week)
    }

    /// The Monday 00:00 of the PREVIOUS ISO week and the following Monday —
    /// the digest covers the completed week, generated any time after it
    /// ends (launch/hourly catch-up; the Mac may be asleep Monday morning).
    static func previousWeekRange(now: Date = Date()) -> (start: Date, end: Date, isoWeek: String) {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = .current
        let thisWeekStart = cal.dateInterval(of: .weekOfYear, for: now)!.start
        let prevStart = cal.date(byAdding: .day, value: -7, to: thisWeekStart)!
        return (prevStart, thisWeekStart, isoWeek(for: prevStart))
    }

    /// The [Monday 00:00, next Monday 00:00) range containing an ISO week id
    /// ("2026-W27"). Used by on-demand and Friday-cadence generation to target
    /// an arbitrary week. Returns nil for a malformed id.
    static func range(forISOWeek id: String) -> (start: Date, end: Date)? {
        let parts = id.split(separator: "-W")
        guard parts.count == 2, let year = Int(parts[0]), let week = Int(parts[1]) else { return nil }
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = .current
        var comps = DateComponents()
        comps.weekOfYear = week
        comps.yearForWeekOfYear = year
        comps.weekday = cal.firstWeekday   // Monday for iso8601
        guard let start = cal.date(from: comps),
              let end = cal.date(byAdding: .day, value: 7, to: start) else { return nil }
        return (start, end)
    }

    /// PRJ-017 F2: the ISO week the weekly review should target right now,
    /// honoring the "first run after Friday 00:00" cadence with catch-up. On
    /// Fri/Sat/Sun this is the current week (the week so far); Mon–Thu it's the
    /// previous week (whose Friday has already passed), so a skipped Friday is
    /// caught up on the next launch.
    static func targetReviewWeek(now: Date = Date()) -> String {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = .current
        let weekStart = cal.dateInterval(of: .weekOfYear, for: now)!.start
        let friday = cal.date(byAdding: .day, value: 4, to: weekStart)!   // Mon+4 = Fri 00:00
        if now >= friday { return isoWeek(for: weekStart) }
        let prevStart = cal.date(byAdding: .day, value: -7, to: weekStart)!
        return isoWeek(for: prevStart)
    }

    static let systemPrompt = """
    You write a one-page weekly review for one person from structured \
    meeting data. Output Markdown with EXACTLY these sections: \
    "## The week in brief" (3-4 sentences), "## Decisions" (bullets), \
    "## People" (one line: who they met and how often), \
    "## Worth revisiting" (open questions and stale action items). \
    The open action items in the data are context for judging staleness, \
    not a list to reproduce — the app shows live open items elsewhere. \
    Use only the data provided — never invent. Stay under 350 words. \
    Skip a section with a single line "Nothing this week." when empty.
    """
}

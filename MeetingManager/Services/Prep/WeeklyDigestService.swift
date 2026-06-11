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

    static let systemPrompt = """
    You write a one-page weekly review for one person from structured \
    meeting data. Output Markdown with EXACTLY these sections: \
    "## The week in brief" (3-4 sentences), "## Decisions" (bullets), \
    "## Commitments" (bullets, owner first, flag anything past due), \
    "## People" (one line: who they met and how often), \
    "## Worth revisiting" (open questions and stale action items). \
    Use only the data provided — never invent. Stay under 400 words. \
    Skip a section with a single line "Nothing this week." when empty.
    """
}

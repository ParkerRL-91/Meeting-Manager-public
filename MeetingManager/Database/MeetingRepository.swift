import Foundation
import GRDB
import os

final class MeetingRepository {
    private let database: AppDatabase

    init(database: AppDatabase) {
        self.database = database
    }

    func save(_ meeting: inout Meeting) async throws {
        var copy = meeting
        try await database.writer.write { db in
            try copy.save(db)
        }
        meeting = copy
    }

    func delete(_ meeting: Meeting) async throws {
        // Snapshot the on-disk audio paths before the DB cascade runs so we don't lose
        // the reference. SQL foreign-key cascades drop transcript/notes/summary rows,
        // but audio files live on the filesystem and must be cleaned up explicitly —
        // otherwise ~/Library/Application Support/MeetingManager/Audio grows unbounded.
        let audioPaths = meeting.audioFilePaths
        try await database.writer.write { db in
            _ = try meeting.delete(db)
        }
        let fm = FileManager.default
        for path in audioPaths {
            do {
                if fm.fileExists(atPath: path) {
                    try fm.removeItem(atPath: path)
                }
            } catch {
                Logger.database.warning("Failed to remove audio file '\(path, privacy: .public)': \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func find(id: String) async throws -> Meeting? {
        try await database.writer.read { db in
            try Meeting.fetchOne(db, key: id)
        }
    }

    func findByCalendarEventId(_ eventId: String) async throws -> Meeting? {
        try await database.writer.read { db in
            try Meeting
                .filter(Meeting.Columns.calendarEventId == eventId)
                .fetchOne(db)
        }
    }

    func upcomingMeetings() async throws -> [Meeting] {
        try await database.writer.read { db in
            try Meeting
                .filter(
                    Meeting.Columns.status == MeetingStatus.scheduled.rawValue
                    || Meeting.Columns.status == MeetingStatus.notified.rawValue
                    || Meeting.Columns.status == MeetingStatus.recording.rawValue
                    || Meeting.Columns.status == MeetingStatus.transcribing.rawValue
                    || Meeting.Columns.status == MeetingStatus.summarizing.rawValue
                )
                .order(Meeting.Columns.scheduledStartDate.asc)
                .limit(100)
                .fetchAll(db)
        }
    }

    func pastMeetings(limit: Int = 50, offset: Int = 0) async throws -> [Meeting] {
        try await database.writer.read { db in
            try Meeting
                .filter(
                    Meeting.Columns.status == MeetingStatus.complete.rawValue
                    || Meeting.Columns.status == MeetingStatus.cancelled.rawValue
                    || Meeting.Columns.status == MeetingStatus.transcribing.rawValue
                    || Meeting.Columns.status == MeetingStatus.summarizing.rawValue
                )
                .order(sql: "COALESCE(endDate, startDate, scheduledStartDate) DESC")
                .limit(limit, offset: offset)
                .fetchAll(db)
        }
    }

    /// Find scheduled/notified meetings near a date.
    ///
    /// Matches meetings whose scheduledStartDate is within ±windowMinutes of `date`,
    /// OR meetings that are "currently running" — i.e. scheduledStartDate is in the past
    /// but scheduledEndDate is still in the future (the meeting hasn't ended yet).
    /// This ensures that clicking "New Meeting" during an ongoing scheduled meeting
    /// correctly matches it rather than creating an ad-hoc duplicate.
    ///
    /// All-day events (duration ≥ 23 hours) are excluded — they're calendar blocks
    /// like "Home", "Vacation", etc., not actual meetings you'd record.
    func meetingsNearDate(_ date: Date, windowMinutes: Int = 10) async throws -> [Meeting] {
        let windowStart = date.addingTimeInterval(-Double(windowMinutes * 60))
        let windowEnd = date.addingTimeInterval(Double(windowMinutes * 60))

        // 23 hours in seconds — all-day events are 24h, use 23h as threshold
        // to avoid matching them while still catching very long meetings (up to ~22h).
        let allDayThreshold: Double = 23 * 3600

        return try await database.writer.read { db in
            let results = try Meeting
                .filter(
                    (Meeting.Columns.status == MeetingStatus.scheduled.rawValue
                     || Meeting.Columns.status == MeetingStatus.notified.rawValue)
                    && (
                        // Case 1: starts within ±windowMinutes
                        (Meeting.Columns.scheduledStartDate >= windowStart
                         && Meeting.Columns.scheduledStartDate <= windowEnd)
                        // Case 2: currently running (started in the past, ends in the future)
                        || (Meeting.Columns.scheduledStartDate <= date
                            && Meeting.Columns.scheduledEndDate != nil
                            && Meeting.Columns.scheduledEndDate >= date)
                    )
                )
                .fetchAll(db)

            // Filter out all-day events in Swift (GRDB doesn't support date arithmetic in filters)
            return results.filter { meeting in
                guard let start = meeting.scheduledStartDate,
                      let end = meeting.scheduledEndDate else { return true }
                let duration = end.timeIntervalSince(start)
                return duration < allDayThreshold
            }
        }
    }

    // MARK: - Prep Queries

    /// Returns the next upcoming meeting (by scheduledStartDate) that is not the given meeting.
    /// Only considers scheduled or notified meetings that haven't been cancelled/archived.
    func nextMeeting(excluding meetingId: String? = nil) async throws -> Meeting? {
        let now = Date()
        return try await database.writer.read { db in
            var request = Meeting
                .filter(
                    Meeting.Columns.status == MeetingStatus.scheduled.rawValue
                    || Meeting.Columns.status == MeetingStatus.notified.rawValue
                )
                .filter(Meeting.Columns.scheduledStartDate != nil)
                .filter(Meeting.Columns.scheduledStartDate > now)
                .filter(Meeting.Columns.isAllDay == false)
                .order(Meeting.Columns.scheduledStartDate.asc)
                .limit(1)

            if let excludeId = meetingId {
                request = request.filter(Meeting.Columns.id != excludeId)
            }

            return try request.fetchOne(db)
        }
    }

    /// Returns meetings starting within the given number of minutes from now.
    /// Used by the prep pre-computation timer to proactively enrich context.
    func meetingsStartingWithin(minutes: Int) async throws -> [Meeting] {
        let now = Date()
        let cutoff = now.addingTimeInterval(Double(minutes * 60))
        return try await database.writer.read { db in
            try Meeting
                .filter(
                    Meeting.Columns.status == MeetingStatus.scheduled.rawValue
                    || Meeting.Columns.status == MeetingStatus.notified.rawValue
                )
                .filter(Meeting.Columns.scheduledStartDate != nil)
                .filter(Meeting.Columns.scheduledStartDate > now)
                .filter(Meeting.Columns.scheduledStartDate <= cutoff)
                .filter(Meeting.Columns.isAllDay == false)
                .order(Meeting.Columns.scheduledStartDate.asc)
                .fetchAll(db)
        }
    }

    /// Search meetings by title query and/or date. Returns up to 50 results sorted by date descending.
    func search(query: String? = nil, date: Date? = nil) async throws -> [Meeting] {
        return try await database.writer.read { db in
            var request = Meeting.all()

            if let query, !query.isEmpty {
                // Escape LIKE wildcards in the user query (the whole thing is still passed
                // as a bound parameter, so SQL-syntax injection is impossible; escaping
                // here only prevents '%' and '_' inside the query from behaving as wildcards).
                let escaped = query
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "%", with: "\\%")
                    .replacingOccurrences(of: "_", with: "\\_")
                request = request.filter(sql: "title LIKE ? ESCAPE '\\'",
                                         arguments: ["%\(escaped)%"])
            }

            if let date {
                let calendar = Calendar.current
                let dayStart = calendar.startOfDay(for: date)
                let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)!
                let scheduledFilter = Meeting.Columns.scheduledStartDate >= dayStart && Meeting.Columns.scheduledStartDate < dayEnd
                let actualFilter = Meeting.Columns.startDate >= dayStart && Meeting.Columns.startDate < dayEnd
                request = request.filter(scheduledFilter || actualFilter)
            }

            return try request
                .order(Meeting.Columns.startDate.desc)
                .limit(50)
                .fetchAll(db)
        }
    }

    func allMeetingsForDate(_ date: Date) async throws -> [Meeting] {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)!

        return try await database.writer.read { db in
            try Meeting
                .filter(
                    (Meeting.Columns.scheduledStartDate >= dayStart && Meeting.Columns.scheduledStartDate < dayEnd)
                    || (Meeting.Columns.startDate >= dayStart && Meeting.Columns.startDate < dayEnd)
                )
                .order(Meeting.Columns.scheduledStartDate.asc)
                .fetchAll(db)
        }
    }

    func update(_ meeting: Meeting) async throws {
        try await database.writer.write { db in
            try meeting.update(db)
        }
    }

    func archive(id: String) async throws {
        try await database.writer.write { db in
            if var meeting = try Meeting.fetchOne(db, key: id) {
                meeting.status = .archived
                try meeting.update(db)
            }
        }
    }

    func unarchive(id: String) async throws {
        try await database.writer.write { db in
            if var meeting = try Meeting.fetchOne(db, key: id) {
                meeting.status = .complete
                try meeting.update(db)
            }
        }
    }

    /// Returns the templateId from the most recent completed meeting with the same title
    /// that has a non-nil templateId. Used to inherit templates for recurring meetings.
    func templateIdForSeries(title: String) async throws -> String? {
        try await database.writer.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT templateId FROM meeting
                    WHERE title = ?
                      AND templateId IS NOT NULL
                    ORDER BY COALESCE(startDate, scheduledStartDate, createdAt) DESC
                    LIMIT 1
                    """,
                arguments: [title]
            )
            return row?["templateId"]
        }
    }

    /// Observe meetings list for real-time UI updates
    func observeUpcoming(
        onChange: @escaping ([Meeting]) -> Void
    ) -> DatabaseCancellable {
        ValueObservation
            .tracking { db in
                try Meeting
                    .filter(
                        Meeting.Columns.status == MeetingStatus.scheduled.rawValue
                        || Meeting.Columns.status == MeetingStatus.notified.rawValue
                        || Meeting.Columns.status == MeetingStatus.recording.rawValue
                    )
                    .order(Meeting.Columns.scheduledStartDate.asc)
                    .fetchAll(db)
            }
            .start(in: database.writer, onError: { error in
                print("Meeting observation error: \(error)")
            }, onChange: onChange)
    }
}

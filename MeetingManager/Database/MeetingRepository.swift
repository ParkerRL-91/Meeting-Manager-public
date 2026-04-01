import Foundation
import GRDB

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
        try await database.writer.write { db in
            _ = try meeting.delete(db)
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
                )
                .order(Meeting.Columns.endDate.desc)
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

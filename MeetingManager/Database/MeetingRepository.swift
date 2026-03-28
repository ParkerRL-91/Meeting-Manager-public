import Foundation
import GRDB

final class MeetingRepository {
    private let database: AppDatabase

    init(database: AppDatabase) {
        self.database = database
    }

    func save(_ meeting: inout Meeting) async throws {
        try await database.writer.write { db in
            try meeting.save(db)
        }
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

    func meetingsNearDate(_ date: Date, windowMinutes: Int = 10) async throws -> [Meeting] {
        let windowStart = date.addingTimeInterval(-Double(windowMinutes * 60))
        let windowEnd = date.addingTimeInterval(Double(windowMinutes * 60))

        return try await database.writer.read { db in
            try Meeting
                .filter(
                    Meeting.Columns.scheduledStartDate >= windowStart
                    && Meeting.Columns.scheduledStartDate <= windowEnd
                    && Meeting.Columns.status == MeetingStatus.scheduled.rawValue
                )
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

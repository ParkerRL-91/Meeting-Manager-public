import Foundation

struct CalendarEvent: Identifiable, Codable {
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
    let attendees: [String]
    /// v3.10 RSVP gate: subset of `attendees` who explicitly declined the
    /// invite. Used to filter the speaker-attribution candidate pool and
    /// tighten the diarization speaker-count hint.
    let declinedAttendees: [String]
    let meetLink: String?
    let description: String?
    let calendarId: String

    init(
        id: String,
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool,
        attendees: [String],
        declinedAttendees: [String] = [],
        meetLink: String?,
        description: String?,
        calendarId: String
    ) {
        self.id = id
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.isAllDay = isAllDay
        self.attendees = attendees
        self.declinedAttendees = declinedAttendees
        self.meetLink = meetLink
        self.description = description
        self.calendarId = calendarId
    }

    var isUpcoming: Bool {
        startDate > Date()
    }

    var isHappeningNow: Bool {
        let now = Date()
        return startDate <= now && endDate >= now
    }

    var durationMinutes: Int {
        Int(endDate.timeIntervalSince(startDate) / 60)
    }
}

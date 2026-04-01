import Foundation

struct CalendarEvent: Identifiable, Codable {
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
    let attendees: [String]
    let meetLink: String?
    let description: String?
    let calendarId: String

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

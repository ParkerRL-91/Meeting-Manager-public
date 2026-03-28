import Foundation

extension Date {

    // MARK: - Calendar Checks

    /// Whether the date falls within today.
    var isToday: Bool {
        Calendar.current.isDateInToday(self)
    }

    /// Whether the date falls within yesterday.
    var isYesterday: Bool {
        Calendar.current.isDateInYesterday(self)
    }

    /// Whether the date is in the future.
    var isUpcoming: Bool {
        self > Date()
    }

    /// Whether the date falls within the current week.
    var isThisWeek: Bool {
        Calendar.current.isDate(self, equalTo: Date(), toGranularity: .weekOfYear)
    }

    // MARK: - Day Boundaries

    /// The start of the day (00:00:00) for this date.
    var startOfDay: Date {
        Calendar.current.startOfDay(for: self)
    }

    /// The end of the day (23:59:59) for this date.
    var endOfDay: Date {
        var components = DateComponents()
        components.day = 1
        components.second = -1
        return Calendar.current.date(byAdding: components, to: startOfDay) ?? self
    }

    // MARK: - Relative Descriptions

    /// Returns a human-readable relative time string such as
    /// "just now", "5 minutes ago", "2 hours ago", "yesterday", or a formatted date.
    var timeAgo: String {
        let now = Date()
        let interval = now.timeIntervalSince(self)

        // Future dates
        if interval < 0 {
            return timeUntil
        }

        switch interval {
        case 0..<60:
            return "just now"
        case 60..<3600:
            let minutes = Int(interval / 60)
            return minutes == 1 ? "1 minute ago" : "\(minutes) minutes ago"
        case 3600..<86400:
            let hours = Int(interval / 3600)
            return hours == 1 ? "1 hour ago" : "\(hours) hours ago"
        default:
            if isYesterday {
                return "yesterday"
            }
            return DateFormatting.relativeDate(from: self)
        }
    }

    /// Returns a human-readable string for a future date, e.g. "in 5 minutes".
    private var timeUntil: String {
        let interval = timeIntervalSince(Date())

        switch interval {
        case 0..<60:
            return "in a moment"
        case 60..<3600:
            let minutes = Int(interval / 60)
            return minutes == 1 ? "in 1 minute" : "in \(minutes) minutes"
        case 3600..<86400:
            let hours = Int(interval / 3600)
            return hours == 1 ? "in 1 hour" : "in \(hours) hours"
        default:
            return DateFormatting.relativeDate(from: self)
        }
    }

    // MARK: - Arithmetic

    /// Returns a new date by adding the given number of days.
    func adding(days: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: days, to: self) ?? self
    }

    /// Returns a new date by adding the given number of hours.
    func adding(hours: Int) -> Date {
        Calendar.current.date(byAdding: .hour, value: hours, to: self) ?? self
    }

    /// Returns a new date by adding the given number of minutes.
    func adding(minutes: Int) -> Date {
        Calendar.current.date(byAdding: .minute, value: minutes, to: self) ?? self
    }
}

import Foundation

/// Centralized date formatting with reusable, thread-safe formatter instances.
enum DateFormatting {

    // MARK: - Formatters

    /// Displays relative dates: "Today", "Yesterday", or a short date like "Mar 28, 2026".
    static let relativeDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    /// Displays time only, e.g. "14:30".
    static let timeOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    /// Displays full date and time, e.g. "Mar 28, 2026 at 2:30 PM".
    static let fullDateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    /// Formats a duration in seconds into a meeting-friendly string like "1h 25m" or "45m".
    static let meetingDurationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = .dropLeading
        return formatter
    }()

    /// ISO 8601 formatter for API interchange.
    static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    // MARK: - Convenience Methods

    /// Returns a relative date string such as "Today", "Yesterday", or "Mar 28, 2026".
    static func relativeDate(from date: Date) -> String {
        relativeDateFormatter.string(from: date)
    }

    /// Returns time-only string, e.g. "14:30".
    static func timeOnly(from date: Date) -> String {
        timeOnlyFormatter.string(from: date)
    }

    /// Returns full date-time string, e.g. "Mar 28, 2026 at 2:30 PM".
    static func fullDateTime(from date: Date) -> String {
        fullDateTimeFormatter.string(from: date)
    }

    /// Formats a time interval as a meeting duration, e.g. "1h 25m".
    /// Returns "--" if the interval is nil or zero.
    static func meetingDuration(from interval: TimeInterval?) -> String {
        guard let interval, interval > 0 else { return "--" }
        return meetingDurationFormatter.string(from: interval) ?? "--"
    }

    /// Returns a time range string like "14:00 - 15:30".
    static func timeRange(from start: Date, to end: Date) -> String {
        "\(timeOnly(from: start)) - \(timeOnly(from: end))"
    }
}

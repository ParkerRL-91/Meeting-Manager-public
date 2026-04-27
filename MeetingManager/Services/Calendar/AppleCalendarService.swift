import EventKit
import Foundation
import os

/// EventKit-backed calendar source. Sibling to `GoogleCalendarService`,
/// surfaced via `CalendarSource.appleCalendar`. No third-party dep.
///
/// Note: Outlook for macOS publishes its events into the system calendar
/// store, so this service transparently covers Outlook users on macOS.
@MainActor
final class AppleCalendarService {
    static let shared = AppleCalendarService()

    private let store = EKEventStore()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.meetingmanager", category: "calendar")

    private init() {}

    // MARK: - Authorization

    var isAuthorized: Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(macOS 14.0, *) {
            return status == .fullAccess
        }
        return status == .authorized
    }

    @discardableResult
    func requestAccess() async -> Bool {
        do {
            if #available(macOS 14.0, *) {
                return try await store.requestFullAccessToEvents()
            } else {
                return try await store.requestAccess(to: .event)
            }
        } catch {
            logger.error("Calendar access request failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - Fetch

    /// Returns events spanning `[now, now + daysAhead]` from all readable calendars,
    /// sorted ascending by start date.
    func fetchUpcomingEvents(daysAhead: Int = 7) async -> [EKEvent] {
        guard isAuthorized else {
            logger.debug("Skipping Apple Calendar fetch — not authorized")
            return []
        }
        let cals = store.calendars(for: .event)
        guard !cals.isEmpty else { return [] }

        let now = Date()
        let end = Calendar.current.date(byAdding: .day, value: daysAhead, to: now) ?? now
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: cals)
        return store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
    }

    // MARK: - Mapping

    /// Maps an EKEvent into a Meeting record. The id is namespaced with an
    /// `applecal-` prefix to avoid collisions with Google calendar ids.
    func meeting(from event: EKEvent) -> Meeting {
        let attendees: [String] = (event.attendees ?? []).compactMap { participant in
            if let name = participant.name, !name.isEmpty { return name }
            // Fall back to a derived URL component when the OS only exposes the URL.
            let urlString = participant.url.absoluteString
            return urlString.hasPrefix("mailto:") ? String(urlString.dropFirst("mailto:".count)) : urlString
        }
        let participantsString = attendees.isEmpty ? nil : attendees.joined(separator: ", ")

        // Apple Calendar exposes the meeting URL via `notes` for Outlook events,
        // and via `url` for native invites. Prefer `url` when available.
        let meetLink: String? = {
            if let url = event.url?.absoluteString, !url.isEmpty {
                return url
            }
            if let notes = event.notes, let firstURL = Self.firstURL(in: notes) {
                return firstURL
            }
            return nil
        }()

        let identifier = event.eventIdentifier ?? UUID().uuidString
        return Meeting(
            id: "applecal-\(identifier)",
            title: event.title ?? "Untitled",
            scheduledStartDate: event.startDate,
            scheduledEndDate: event.endDate,
            status: .scheduled,
            calendarEventId: identifier,
            isAllDay: event.isAllDay,
            participants: participantsString,
            meetLink: meetLink
        )
    }

    /// Crude URL extractor used to pull a meeting link out of the notes body.
    private static func firstURL(in text: String) -> String? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..., in: text)
        guard let match = detector?.firstMatch(in: text, options: [], range: range),
              let url = match.url else { return nil }
        return url.absoluteString
    }
}

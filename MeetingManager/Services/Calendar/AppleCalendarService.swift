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

    /// Exposed so observers (e.g. `CalendarSyncManager`) can subscribe to
    /// EventKit's change firehose without needing a reference to the store.
    let store = EKEventStore()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.meetingmanager", category: "calendar")

    private init() {}

    // MARK: - Authorization

    /// Permission states surfaced to the UI. EventKit on macOS 14+ has
    /// `.writeOnly` which is *not* enough for our reads — we treat it the
    /// same as denied for sync purposes but expose it distinctly so the
    /// settings UI can guide the user to upgrade.
    enum AuthorizationState {
        case notDetermined
        case denied
        case writeOnly
        case authorized
    }

    var authorizationState: AuthorizationState {
        // Deployment target is macOS 14.4 (see Package.swift / Info.plist), so
        // the legacy `.authorized` case is unreachable in practice but still
        // listed for exhaustiveness.
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined: return .notDetermined
        case .denied, .restricted: return .denied
        case .writeOnly: return .writeOnly
        case .fullAccess, .authorized: return .authorized
        @unknown default: return .denied
        }
    }

    var isAuthorized: Bool { authorizationState == .authorized }

    /// Asks EventKit for full read access. Returns true on a successful grant.
    ///
    /// Logging is intentionally verbose so a bounced-back-to-not-connected
    /// report can be diagnosed from the unified log alone (filter by
    /// subsystem `com.meetingmanager.app`, category `calendar`).
    @discardableResult
    func requestAccess() async -> Bool {
        let priorStatus = EKEventStore.authorizationStatus(for: .event)
        logger.info("Apple Calendar requestAccess() called — prior TCC status=\(priorStatus.rawValue, privacy: .public) (\(self.priorStatusDescription(priorStatus), privacy: .public))")
        do {
            let granted = try await store.requestFullAccessToEvents()
            let postStatus = EKEventStore.authorizationStatus(for: .event)
            logger.info("requestFullAccessToEvents returned granted=\(granted, privacy: .public); post-call TCC status=\(postStatus.rawValue, privacy: .public) (\(self.priorStatusDescription(postStatus), privacy: .public))")
            return granted
        } catch {
            logger.error("Apple Calendar access request threw: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Map raw EKAuthorizationStatus to a readable string for logs.
    private func priorStatusDescription(_ s: EKAuthorizationStatus) -> String {
        switch s {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorized: return "authorized(legacy)"
        case .writeOnly: return "writeOnly"
        case .fullAccess: return "fullAccess"
        @unknown default: return "unknown(\(s.rawValue))"
        }
    }

    // MARK: - Fetch

    /// Returns events spanning `[now - daysBehind, now + daysAhead]` from all
    /// readable calendars, sorted ascending by start date.
    ///
    /// `daysBehind` defaults to 1 so an in-progress meeting that started a
    /// few minutes before launch is still picked up — matching the Google
    /// path's behavior.
    func fetchEvents(daysBehind: Int = 1, daysAhead: Int = 7) async -> [EKEvent] {
        guard isAuthorized else {
            logger.warning("Apple Calendar fetch skipped — not authorized (state=\(String(describing: self.authorizationState), privacy: .public))")
            return []
        }
        let cals = store.calendars(for: .event)
        guard !cals.isEmpty else {
            logger.warning("Apple Calendar fetch returned 0 events — store reports zero readable calendars (TCC may have granted writeOnly or the user has no enabled calendars in Calendar.app)")
            return []
        }

        let cal = Calendar.current
        let now = Date()
        let start = cal.date(byAdding: .day, value: -max(0, daysBehind), to: now) ?? now
        let end = cal.date(byAdding: .day, value: max(1, daysAhead), to: now) ?? now
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: cals)
        let events = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
        logger.info("Apple Calendar fetch: \(events.count, privacy: .public) events from \(cals.count, privacy: .public) calendar(s) over -\(daysBehind, privacy: .public)d / +\(daysAhead, privacy: .public)d")
        return events
    }

    /// Backwards-compatible alias kept for older call sites that only need
    /// the forward-looking window.
    func fetchUpcomingEvents(daysAhead: Int = 7) async -> [EKEvent] {
        await fetchEvents(daysBehind: 0, daysAhead: daysAhead)
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

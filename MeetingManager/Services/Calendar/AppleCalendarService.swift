import EventKit
import Foundation
import AppKit
import os

/// EventKit-backed calendar source. Sibling to `GoogleCalendarService`,
/// surfaced via `CalendarSource.appleCalendar`. No third-party dep.
///
/// Note: Outlook for macOS publishes its events into the system calendar
/// store, so this service transparently covers Outlook users on macOS.
///
/// ## Reliability model
///
/// EventKit on macOS has several edge cases that historically caused the
/// app to look "permanently disconnected" even when TCC reported access
/// granted. This service guards against all of them:
///
/// 1. The `EKEventStore` is recreated whenever auth state transitions to
///    `.authorized` — a store created in an unauthorized state can return
///    empty calendar lists even after the user later grants access.
/// 2. `EKEventStoreChanged` is observed to detect external grants (user
///    toggles permission in System Settings).
/// 3. `NSApplication.didBecomeActive` is observed so the app re-validates
///    the store every time it comes to the foreground — catches the case
///    where the user grants in System Settings without quitting the app.
/// 4. Auth state is "sticky": once we observe `.authorized`, a transient
///    `.notDetermined` from the static API is treated as a stall, not a
///    revocation. Real revocations come through as `.denied`.
/// 5. `verifyAndRefresh()` is called before every read; if the store is
///    in a bad state, it's rebuilt before returning.
@MainActor
final class AppleCalendarService {
    static let shared = AppleCalendarService()

    /// EventKit handle. `private(set)` because it gets replaced when we
    /// recreate the store after an auth transition; callers must always
    /// read it fresh and never cache the reference.
    ///
    /// Subscribe to `Notification.Name.appleCalendarStoreReplaced` to
    /// re-register any `EKEventStoreChanged` observers when the store
    /// is rebuilt.
    private(set) var store = EKEventStore()

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.meetingmanager", category: "calendar")

    /// Last auth state we *observed* — used to detect transitions and to
    /// implement the sticky-authorized rule (so a transient `.notDetermined`
    /// from EventKit's static query doesn't make the UI bounce).
    private var lastObservedState: AuthorizationState = .notDetermined

    /// Set when we last saw `.authorized`. Used by the sticky rule.
    private var lastAuthorizedAt: Date?

    /// External-change observers we install once at first access.
    private var didBecomeActiveObserver: NSObjectProtocol?
    private var eventStoreChangedObserver: NSObjectProtocol?

    private init() {
        installSystemObservers()
        // Snapshot initial state so transitions are detectable.
        lastObservedState = currentAuthorizationStateRaw()
        if lastObservedState == .authorized { lastAuthorizedAt = Date() }
    }

    deinit {
        if let o = didBecomeActiveObserver { NotificationCenter.default.removeObserver(o) }
        if let o = eventStoreChangedObserver { NotificationCenter.default.removeObserver(o) }
    }

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

    /// Public auth state. Applies the sticky-authorized rule: once we've
    /// successfully observed `.authorized`, a follow-up `.notDetermined`
    /// (which EventKit can transiently return) is reported as `.authorized`
    /// for a 5-second grace window before bouncing.
    var authorizationState: AuthorizationState {
        let raw = currentAuthorizationStateRaw()
        if raw == .notDetermined,
           let lastAuth = lastAuthorizedAt,
           Date().timeIntervalSince(lastAuth) < 5.0 {
            logger.debug("Auth state stickied: raw=.notDetermined but lastAuthorizedAt=\(lastAuth)")
            return .authorized
        }
        return raw
    }

    var isAuthorized: Bool { authorizationState == .authorized }

    /// Raw state without the sticky rule.
    private func currentAuthorizationStateRaw() -> AuthorizationState {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined: return .notDetermined
        case .denied, .restricted: return .denied
        case .writeOnly: return .writeOnly
        case .fullAccess, .authorized: return .authorized
        @unknown default: return .denied
        }
    }

    /// Asks EventKit for full read access. Returns true on a successful grant.
    ///
    /// On success, the underlying `EKEventStore` is recreated to ensure
    /// EventKit's internal auth cache is fresh — without this step, the
    /// pre-grant store can stay stuck returning empty calendar lists.
    @discardableResult
    func requestAccess() async -> Bool {
        let priorStatus = EKEventStore.authorizationStatus(for: .event)
        logger.info("Apple Calendar requestAccess() — prior TCC status=\(self.statusDescription(priorStatus), privacy: .public)")
        do {
            let granted = try await store.requestFullAccessToEvents()
            // Give TCC a beat to commit the grant before re-querying.
            try? await Task.sleep(for: .milliseconds(150))
            let postStatus = EKEventStore.authorizationStatus(for: .event)
            logger.info("requestFullAccessToEvents granted=\(granted, privacy: .public); post TCC status=\(self.statusDescription(postStatus), privacy: .public)")

            if granted {
                lastAuthorizedAt = Date()
                lastObservedState = .authorized
                rebuildStore(reason: "post-grant")
            }
            return granted
        } catch {
            logger.error("Apple Calendar access request threw: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Verify the store is in a usable state. Detects and recovers from:
    /// - Auth-state drift since last observation
    /// - Store instance returning 0 calendars while auth says authorized
    ///   (the classic "stuck instance" failure mode)
    ///
    /// Call this before every read path. Cheap when nothing's wrong.
    @discardableResult
    func verifyAndRefresh() -> Bool {
        let raw = currentAuthorizationStateRaw()

        // Detect transition into authorized — recreate the store to flush
        // any cached unauthorized state.
        if raw == .authorized && lastObservedState != .authorized {
            logger.info("Auth transition: \(self.stateDescription(self.lastObservedState), privacy: .public) -> .authorized — rebuilding store")
            lastObservedState = .authorized
            lastAuthorizedAt = Date()
            rebuildStore(reason: "auth-transition")
            return true
        }

        // Update sticky timestamp on every observed-authorized hit.
        if raw == .authorized {
            lastAuthorizedAt = Date()
            lastObservedState = .authorized
            // Detect "stuck instance" — authorized but no calendars visible.
            // EventKit will sometimes return [] from a store that was created
            // in the unauthorized window. Rebuild and retry on this signal.
            if store.calendars(for: .event).isEmpty {
                logger.warning("Store reports 0 calendars while authorized — rebuilding (likely stale instance)")
                rebuildStore(reason: "stuck-instance")
            }
            return true
        }

        lastObservedState = raw
        return raw == .authorized
    }

    /// Rebuild the underlying `EKEventStore`. Posts a notification so any
    /// observers re-register their `EKEventStoreChanged` observer against
    /// the new instance.
    private func rebuildStore(reason: String) {
        store = EKEventStore()
        logger.info("EKEventStore rebuilt — reason=\(reason, privacy: .public)")
        NotificationCenter.default.post(name: .appleCalendarStoreReplaced, object: nil)
    }

    // MARK: - System observers

    private func installSystemObservers() {
        // Re-validate on app foreground. Catches the case where the user
        // grants permission in System Settings while the app is running.
        didBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                AppleCalendarService.shared.verifyAndRefresh()
            }
        }

        // EventKit fires this when the calendar database changes — and
        // empirically, when permission state changes too. Use it as a
        // second signal alongside foregrounding.
        eventStoreChangedObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                AppleCalendarService.shared.verifyAndRefresh()
            }
        }
    }

    // MARK: - Calendar list (for multi-select UI)

    struct CalendarInfo: Identifiable, Hashable {
        let id: String        // EKCalendar.calendarIdentifier
        let title: String     // user-visible name, e.g. "Work"
        let sourceTitle: String // e.g. "iCloud", "Exchange", "Google" — useful in groupings
        let allowsContentModifications: Bool
        let isSubscription: Bool // birthdays, holidays, sports schedules, etc.

        var displayLabel: String { "\(title) — \(sourceTitle)" }
    }

    /// All calendars the user can read. Empty array means either no access
    /// or no calendars are enabled in Calendar.app. Caller can disambiguate
    /// by checking `authorizationState` first.
    func availableCalendars() -> [CalendarInfo] {
        verifyAndRefresh()
        guard isAuthorized else { return [] }
        let cals = store.calendars(for: .event)
        return cals.map { c in
            CalendarInfo(
                id: c.calendarIdentifier,
                title: c.title,
                sourceTitle: c.source?.title ?? "Unknown",
                allowsContentModifications: c.allowsContentModifications,
                isSubscription: c.type == .subscription || c.type == .birthday
            )
        }.sorted { lhs, rhs in
            if lhs.sourceTitle == rhs.sourceTitle { return lhs.title < rhs.title }
            return lhs.sourceTitle < rhs.sourceTitle
        }
    }

    // MARK: - Fetch

    /// Returns events spanning `[now - daysBehind, now + daysAhead]`.
    ///
    /// - Parameter calendarIds: When non-nil, restrict the read to these
    ///   `EKCalendar.calendarIdentifier`s. Nil = all readable calendars.
    func fetchEvents(
        daysBehind: Int = 1,
        daysAhead: Int = 7,
        calendarIds: Set<String>? = nil
    ) async -> [EKEvent] {
        verifyAndRefresh()
        guard isAuthorized else {
            logger.warning("Apple Calendar fetch skipped — not authorized (state=\(self.stateDescription(self.authorizationState), privacy: .public))")
            return []
        }
        let allCals = store.calendars(for: .event)
        let cals: [EKCalendar]
        if let calendarIds {
            cals = allCals.filter { calendarIds.contains($0.calendarIdentifier) }
            if cals.isEmpty && !allCals.isEmpty {
                logger.warning("Selected calendar IDs don't match any current calendars — falling back to all (\(allCals.count, privacy: .public))")
                return await fetchEvents(daysBehind: daysBehind, daysAhead: daysAhead, calendarIds: nil)
            }
        } else {
            cals = allCals
        }
        guard !cals.isEmpty else {
            logger.warning("Apple Calendar fetch returned 0 events — 0 readable calendars (no calendars enabled in Calendar.app, or writeOnly grant)")
            return []
        }

        let cal = Calendar.current
        let now = Date()
        let start = cal.date(byAdding: .day, value: -max(0, daysBehind), to: now) ?? now
        let end = cal.date(byAdding: .day, value: max(1, daysAhead), to: now) ?? now
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: cals)
        let events = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
        logger.info("Apple Calendar fetch: \(events.count, privacy: .public) events from \(cals.count, privacy: .public)/\(allCals.count, privacy: .public) calendar(s) over -\(daysBehind, privacy: .public)d/+\(daysAhead, privacy: .public)d")
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

        // Apple Calendar exposes the meeting URL in several places depending
        // on the source:
        //   - `event.url` for native invites (Apple Calendar, native iCloud)
        //   - `event.notes` for Outlook-on-macOS events
        //   - `event.location` for Outlook + many third-party apps that
        //     stuff the Zoom/Meet/Teams URL into the location field
        //     instead of notes
        // Prefer in this order. Within notes/location, prefer a known
        // conferencing URL pattern over the first URL found.
        let meetLink: String? = {
            if let url = event.url?.absoluteString, !url.isEmpty {
                Logger.notifications.debug("[meetLink] '\(event.title ?? "untitled", privacy: .public)' from event.url")
                return url
            }
            // Combined search corpus — location first because it's the
            // most common spot for Outlook/work-domain calendars.
            let candidates = [event.location, event.notes].compactMap { $0 }
            for text in candidates {
                if let conf = Self.conferencingURL(in: text) {
                    Logger.notifications.debug("[meetLink] '\(event.title ?? "untitled", privacy: .public)' from conferencing URL match")
                    return conf
                }
            }
            for text in candidates {
                if let any = Self.firstURL(in: text) {
                    Logger.notifications.debug("[meetLink] '\(event.title ?? "untitled", privacy: .public)' from first-URL fallback")
                    return any
                }
            }
            Logger.notifications.debug("[meetLink] '\(event.title ?? "untitled", privacy: .public)' — no link found in event.url/location/notes")
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

    /// Find a conferencing-platform URL specifically. Used to disambiguate
    /// when the notes/location field has multiple URLs and we want the
    /// "join the call" one rather than e.g. a docs link.
    private static let conferencingHostPatterns: [String] = [
        "zoom.us", "zoom.com",
        "meet.google.com", "g.co/meet",
        "teams.microsoft.com", "teams.live.com",
        "webex.com",
        "gotomeeting.com", "gotomeet.me",
        "whereby.com",
        "bluejeans.com",
        "ringcentral.com",
        "jit.si", "meet.jit.si",
        "around.co",
        "discord.gg",
    ]

    private static func conferencingURL(in text: String) -> String? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..., in: text)
        guard let detector else { return nil }
        let matches = detector.matches(in: text, options: [], range: range)
        for match in matches {
            guard let url = match.url, let host = url.host?.lowercased() else { continue }
            if conferencingHostPatterns.contains(where: { host.contains($0) }) {
                return url.absoluteString
            }
        }
        return nil
    }

    // MARK: - Logging helpers

    private func statusDescription(_ s: EKAuthorizationStatus) -> String {
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

    private func stateDescription(_ s: AuthorizationState) -> String {
        switch s {
        case .notDetermined: return "notDetermined"
        case .denied: return "denied"
        case .writeOnly: return "writeOnly"
        case .authorized: return "authorized"
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    /// Posted on `MainActor` when `AppleCalendarService.shared.store` is
    /// replaced. Observers should re-register any `EKEventStoreChanged`
    /// listeners against the new store instance.
    static let appleCalendarStoreReplaced = Notification.Name("appleCalendarStoreReplaced")
}

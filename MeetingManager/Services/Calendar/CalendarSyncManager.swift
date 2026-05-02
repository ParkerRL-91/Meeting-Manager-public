import EventKit
import Foundation
import GRDB
import os

// MARK: - CalendarSource

/// Where the app pulls calendar events from. Persisted under
/// `UserDefaults` key `"calendar.source"` (raw string).
enum CalendarSource: String, CaseIterable {
    case googleCalendar
    case appleCalendar
    case both
    case none

    /// Convenience reader for the current user setting. Defaults to
    /// `.googleCalendar` to preserve existing behavior.
    static var current: CalendarSource {
        let raw = UserDefaults.standard.string(forKey: "calendar.source") ?? "googleCalendar"
        return CalendarSource(rawValue: raw) ?? .googleCalendar
    }
}

// MARK: - CalendarSyncError

enum CalendarSyncError: LocalizedError {
    case notSignedIn
    case syncFailed(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Not signed in to Google Calendar. Please sign in first."
        case .syncFailed(let message):
            return "Calendar sync failed: \(message)"
        }
    }
}

// MARK: - CalendarSyncManager

/// Coordinates periodic and manual synchronisation of Google Calendar events
/// with local `Meeting` records.
///
/// Events are matched by `calendarEventId` for deduplication. New events
/// create new meetings; existing events update their matching meeting record.
@Observable
@MainActor
final class CalendarSyncManager {

    // MARK: - Public State

    private(set) var lastSyncDate: Date?
    private(set) var isSyncing = false
    private(set) var lastError: String?
    private(set) var eventsSyncedCount = 0

    // MARK: - Dependencies

    private let authManager: GoogleAuthManager
    private let calendarService: GoogleCalendarService
    private let meetingRepository: MeetingRepository

    // MARK: - Private

    nonisolated(unsafe) private var syncTimer: Timer?
    nonisolated(unsafe) private var syncTask: Task<Void, Never>?

    /// Periodic-sync interval in seconds. Captured at `startPeriodicSync` so
    /// the source-change handler can restart with the same cadence without
    /// re-reading settings.
    private var lastInterval: TimeInterval = 15 * 60

    /// Debounces EventKit change notifications so an edit storm in
    /// Calendar.app doesn't trigger N back-to-back syncs.
    nonisolated(unsafe) private var changeDebounceTask: Task<Void, Never>?

    /// Holds the EventKit / UserDefaults observers for lifetime management.
    nonisolated(unsafe) private var eventStoreObserver: NSObjectProtocol?
    nonisolated(unsafe) private var sourceChangeObserver: NSObjectProtocol?
    nonisolated(unsafe) private var storeReplacedObserver: NSObjectProtocol?

    /// How far into the future to fetch events during sync.
    private let lookAheadDays: Int = 7

    /// How far into the past to fetch events during sync.
    private let lookBehindDays: Int = 1

    // MARK: - Init

    init(
        authManager: GoogleAuthManager,
        calendarService: GoogleCalendarService = GoogleCalendarService(),
        meetingRepository: MeetingRepository
    ) {
        self.authManager = authManager
        self.calendarService = calendarService
        self.meetingRepository = meetingRepository
    }

    deinit {
        syncTimer?.invalidate()
        syncTask?.cancel()
        changeDebounceTask?.cancel()
        if let obs = eventStoreObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = sourceChangeObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = storeReplacedObserver { NotificationCenter.default.removeObserver(obs) }
    }

    // MARK: - Periodic Sync

    /// Starts a periodic sync timer that fires at the given interval.
    ///
    /// Any existing timer is cancelled before starting the new one.
    /// The first sync runs immediately.
    ///
    /// Also installs (idempotently) two observers:
    /// - `EKEventStore.eventStoreChangedNotification` so edits made in
    ///   Calendar.app trigger an immediate (debounced) sync rather than
    ///   waiting for the next tick.
    /// - `Notification.Name.calendarSourceChanged` so the user flipping
    ///   `calendar.source` in Settings restarts the loop without a relaunch.
    ///
    /// - Parameter interval: Time between syncs, in seconds.
    func startPeriodicSync(interval: TimeInterval) async {
        await stopSync()

        lastInterval = interval
        Logger.calendar.info("Starting periodic calendar sync every \(Int(interval / 60)) minutes (source=\(CalendarSource.current.rawValue, privacy: .public))")

        // Fire immediately, then repeat.
        syncTask = Task { [weak self] in
            await self?.performSync()
        }

        syncTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.performSync()
            }
        }

        installEventStoreObserverIfNeeded()
        installSourceChangeObserverIfNeeded()
        installStoreReplacedObserverIfNeeded()
    }

    /// Subscribe to EventKit's change firehose so external edits show up
    /// without waiting for the next tick. Debounced to coalesce edit storms.
    ///
    /// Bound to `nil` instead of a specific store so it survives
    /// `AppleCalendarService` rebuilding its `EKEventStore` after a
    /// permission grant — the legacy approach of binding to a specific
    /// instance silently went deaf the moment the store was replaced.
    private func installEventStoreObserverIfNeeded() {
        guard eventStoreObserver == nil else { return }
        eventStoreObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // .main delivers on the main thread but Swift 6 still needs an
            // explicit MainActor hop to call into @MainActor-isolated state.
            Task { @MainActor in
                self?.scheduleDebouncedAppleSync()
            }
        }
    }

    /// When `AppleCalendarService` rebuilds its store after a permission
    /// transition, kick a sync. Calendar data is now actually fetchable —
    /// don't make the user wait for the next periodic tick to see events.
    private func installStoreReplacedObserverIfNeeded() {
        guard storeReplacedObserver == nil else { return }
        storeReplacedObserver = NotificationCenter.default.addObserver(
            forName: .appleCalendarStoreReplaced,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                let source = CalendarSource.current
                guard source == .appleCalendar || source == .both else { return }
                Logger.calendar.info("Apple store rebuilt — kicking immediate sync")
                await self?.performSync()
            }
        }
    }

    /// Coalesce rapid `EKEventStoreChanged` posts (Calendar.app fires bursts
    /// of them while the user is typing) into a single sync ~750ms after the
    /// last edit lands.
    private func scheduleDebouncedAppleSync() {
        let source = CalendarSource.current
        guard source == .appleCalendar || source == .both else {
            Logger.calendar.debug("EventKit change ignored — source is \(source.rawValue, privacy: .public), not Apple")
            return
        }
        Logger.calendar.debug("EventKit change received — debouncing 750ms before sync")
        changeDebounceTask?.cancel()
        changeDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled, let self else { return }
            Logger.calendar.info("EventKit change debounce elapsed — running Apple sync")
            await self.performSync()
        }
    }

    /// Listen for `calendar.source` flips so we stop / restart cleanly.
    private func installSourceChangeObserverIfNeeded() {
        guard sourceChangeObserver == nil else { return }
        sourceChangeObserver = NotificationCenter.default.addObserver(
            forName: .calendarSourceChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let interval = self.lastInterval
                if CalendarSource.current == .none {
                    Logger.calendar.info("Calendar source set to .none — stopping periodic sync")
                    await self.stopSync()
                } else {
                    Logger.calendar.info("Calendar source changed — restarting periodic sync")
                    await self.startPeriodicSync(interval: interval)
                }
            }
        }
    }

    /// Stops the periodic sync timer and waits for the in-flight sync to quiesce.
    ///
    /// Awaiting `syncTask?.value` matters because a cancel-only path can leave a
    /// half-written meeting record in SQLite: the Task is marked cancelled but it
    /// may still be mid-transaction when the caller moves on to start a new sync
    /// or reconfigure auth. Waiting for quiesce eliminates that race.
    func stopSync() async {
        syncTimer?.invalidate()
        syncTimer = nil
        let inflight = syncTask
        syncTask = nil
        inflight?.cancel()
        // `Task.value` is nonthrowing for `Task<Void, Never>` and returns once the
        // task honors cancellation (`performSync` checks for `Task.isCancelled` at
        // its async boundaries).
        await inflight?.value
        Logger.calendar.info("Periodic calendar sync stopped")
    }

    /// Triggers a single sync cycle manually.
    func syncNow() async throws {
        let source = CalendarSource.current
        // The not-signed-in guard only applies when Google is the active source.
        if (source == .googleCalendar || source == .both) && !authManager.isSignedIn {
            throw CalendarSyncError.notSignedIn
        }
        await performSync()
        if let error = lastError {
            throw CalendarSyncError.syncFailed(error)
        }
    }

    /// Wide-window backfill — useful as a one-shot from the Settings UI to
    /// repopulate participants and meet links on already-completed meetings.
    /// `upsertMeeting` always backfills empty participants regardless of
    /// status, so this is safe to run any time and idempotent on already-
    /// populated rows.
    func backfillFromCalendar(daysBehind: Int = 90, daysAhead: Int = 30) async throws -> Int {
        let source = CalendarSource.current
        if source == .none { return 0 }
        if (source == .googleCalendar || source == .both) && !authManager.isSignedIn {
            throw CalendarSyncError.notSignedIn
        }

        var processed = 0
        if source == .googleCalendar || source == .both {
            let accessToken = try await authManager.refreshTokenIfNeeded()
            let now = Date()
            let from = Calendar.current.date(byAdding: .day, value: -daysBehind, to: now)!
            let to = Calendar.current.date(byAdding: .day, value: daysAhead, to: now)!
            let calendarIds = selectedGoogleCalendarIds()
            for calendarId in calendarIds {
                do {
                    let events = try await calendarService.fetchEvents(
                        accessToken: accessToken,
                        from: from,
                        to: to,
                        calendarId: calendarId
                    )
                    for event in events {
                        try await upsertMeeting(from: event)
                        processed += 1
                    }
                } catch {
                    Logger.calendar.error("Google backfill failed for calendar=\(calendarId, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        if source == .appleCalendar || source == .both {
            // EventKit-backed wide-window pull. Mirrors the Google branch above
            // so the user-visible "Re-sync 90 days" semantics are real for
            // Apple-only users instead of a silent no-op.
            AppleCalendarService.shared.verifyAndRefresh()
            guard AppleCalendarService.shared.isAuthorized else {
                Logger.calendar.warning("Apple backfill skipped — calendar permission not granted")
                if processed == 0 {
                    throw CalendarSyncError.syncFailed("Apple Calendar access not granted. Open System Settings → Privacy & Security → Calendars to enable Meeting Manager.")
                }
                return processed
            }
            let selectedIds = selectedAppleCalendarIds()
            let events = await AppleCalendarService.shared.fetchEvents(daysBehind: daysBehind, daysAhead: daysAhead, calendarIds: selectedIds)
            for event in events {
                do {
                    let meeting = AppleCalendarService.shared.meeting(from: event)
                    try await upsertAppleMeeting(meeting)
                    processed += 1
                } catch {
                    Logger.calendar.error("Apple Calendar backfill upsert failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        await MainActor.run { self.lastSyncDate = Date() }
        Logger.calendar.info("Backfill complete: \(processed) events from -\(daysBehind)d to +\(daysAhead)d")
        return processed
    }

    // MARK: - Sync Logic

    private func performSync() async {
        let source = CalendarSource.current

        guard !isSyncing else {
            Logger.calendar.debug("Skipping sync — already in progress")
            return
        }

        // For Google-backed sources we still require a signed-in account.
        if (source == .googleCalendar || source == .both) && !authManager.isSignedIn {
            Logger.calendar.debug("Skipping sync — Google not signed in")
            return
        }

        if source == .none {
            Logger.calendar.debug("Skipping sync — calendar source set to .none")
            return
        }

        isSyncing = true
        lastError = nil

        do {
            var synced = 0

            if source == .googleCalendar || source == .both {
                synced += try await syncGoogle()
            }

            if source == .appleCalendar || source == .both {
                synced += await syncApple()
            }

            eventsSyncedCount = synced
            lastSyncDate = Date()

            Logger.calendar.info("Calendar sync complete (\(source.rawValue, privacy: .public)): \(synced) events processed")
            if synced > 0 {
                // AppState observes this to reload its cached meeting lists so
                // the UI picks up freshly-synced events without a relaunch.
                NotificationCenter.default.post(name: .calendarBackfillCompleted, object: nil)
            }
        } catch {
            lastError = error.localizedDescription
            Logger.calendar.error("Calendar sync failed: \(error.localizedDescription)")
        }

        isSyncing = false
    }

    /// Existing Google Calendar sync path, factored out so the source switch is readable.
    private func syncGoogle() async throws -> Int {
        let accessToken = try await authManager.refreshTokenIfNeeded()

        let now = Date()
        let from = Calendar.current.date(byAdding: .day, value: -lookBehindDays, to: now)!
        let to = Calendar.current.date(byAdding: .day, value: lookAheadDays, to: now)!

        let calendarIds = selectedGoogleCalendarIds()
        var synced = 0
        for calendarId in calendarIds {
            do {
                let events = try await calendarService.fetchEvents(
                    accessToken: accessToken,
                    from: from,
                    to: to,
                    calendarId: calendarId
                )
                for event in events {
                    try await upsertMeeting(from: event)
                    synced += 1
                }
            } catch {
                Logger.calendar.error("Google sync failed for calendar=\(calendarId, privacy: .public): \(error.localizedDescription, privacy: .public)")
                // One bad calendar shouldn't kill the whole sync — keep going.
            }
        }
        return synced
    }

    /// Pulls EventKit events and upserts them as Meeting rows. Dedupes by
    /// `calendarEventId` so events that also appear via Google are merged.
    /// Window matches the Google branch (`lookBehindDays` / `lookAheadDays`)
    /// so an in-progress meeting that started a few minutes before the last
    /// tick is still picked up.
    private func syncApple() async -> Int {
        // verifyAndRefresh() detects auth-state drift and rebuilds the
        // EKEventStore if needed. This is the recovery path that lets us
        // come back to life without an app relaunch.
        AppleCalendarService.shared.verifyAndRefresh()
        let state = AppleCalendarService.shared.authorizationState
        guard state == .authorized else {
            Logger.calendar.warning("Apple sync skipped — authorizationState=\(String(describing: state), privacy: .public). User must grant full access in Settings → Calendar or System Settings → Privacy & Security → Calendars.")
            return 0
        }
        let selectedIds = selectedAppleCalendarIds()
        let events = await AppleCalendarService.shared.fetchEvents(
            daysBehind: lookBehindDays,
            daysAhead: lookAheadDays,
            calendarIds: selectedIds
        )
        var synced = 0
        for event in events {
            do {
                let meeting = AppleCalendarService.shared.meeting(from: event)
                try await upsertAppleMeeting(meeting)
                synced += 1
            } catch {
                Logger.calendar.error("Apple Calendar upsert failed for event '\(event.title ?? "<no title>", privacy: .public)': \(error.localizedDescription, privacy: .public)")
            }
        }
        Logger.calendar.info("Apple sync complete: upserted \(synced, privacy: .public) of \(events.count, privacy: .public) events")
        return synced
    }

    /// Decode the comma-separated calendar ID selection from settings.
    /// Returns nil to mean "all enabled calendars" (user hasn't picked).
    private func selectedAppleCalendarIds() -> Set<String>? {
        let raw: String? = (try? AppDatabase.shared.writer.read { db in
            try AppSettings.fetchOne(db)?.selectedAppleCalendarIds
        }) ?? nil
        guard let raw, !raw.isEmpty else { return nil }
        let ids = raw.split(separator: ",").map { String($0) }
        return ids.isEmpty ? nil : Set(ids)
    }

    /// Read the user's multi-select Google calendar IDs. Falls back to the
    /// legacy `selectedCalendarId` single-string when the new field is unset
    /// (preserves behaviour for users upgrading from the single-select UI).
    private func selectedGoogleCalendarIds() -> [String] {
        if let raw: String = (try? AppDatabase.shared.writer.read { db in
            try AppSettings.fetchOne(db)?.selectedGoogleCalendarIds
        }) ?? nil, !raw.isEmpty {
            let ids = raw.split(separator: ",").map { String($0) }
            if !ids.isEmpty { return ids }
        }
        // Legacy single-select fallback.
        let legacy: String? = (try? AppDatabase.shared.writer.read { db in
            try AppSettings.fetchOne(db)?.selectedCalendarId
        }) ?? nil
        return [legacy ?? "primary"]
    }

    /// Upserts a Meeting derived from an EKEvent. Mirrors `upsertMeeting(from:)`
    /// but works directly on a fully-formed Meeting struct.
    private func upsertAppleMeeting(_ incoming: Meeting) async throws {
        guard let eventId = incoming.calendarEventId else { return }
        try await AppDatabase.shared.writer.write { db in
            if var existing = try Meeting
                .filter(Column("calendarEventId") == eventId)
                .fetchOne(db)
            {
                var needsUpdate = false
                if let p = incoming.participants, !p.isEmpty,
                   existing.participants == nil || existing.participants!.isEmpty {
                    existing.participants = p
                    needsUpdate = true
                }
                // v3.10 RSVP gate: refresh declined-attendee list every sync.
                if existing.declinedAttendees != incoming.declinedAttendees {
                    existing.declinedAttendees = incoming.declinedAttendees
                    needsUpdate = true
                }
                if existing.meetLink == nil, let link = incoming.meetLink {
                    existing.meetLink = link
                    needsUpdate = true
                }
                if existing.status == .scheduled || existing.status == .notified {
                    // QA finding: don't clobber a user-edited title. Only adopt the
                    // calendar title if the local title is empty or still a placeholder.
                    // Otherwise the v3.0.0 click-to-edit feature would silently lose
                    // edits on the next sync cycle.
                    if Self.isPlaceholderTitle(existing.title) {
                        existing.title = incoming.title
                    }
                    existing.scheduledStartDate = incoming.scheduledStartDate
                    existing.scheduledEndDate = incoming.scheduledEndDate
                    existing.isAllDay = incoming.isAllDay
                    existing.meetLink = incoming.meetLink ?? existing.meetLink
                    needsUpdate = true
                }
                if needsUpdate {
                    try existing.update(db)
                }
            } else {
                var copy = incoming
                try copy.insert(db)
            }
        }
    }

    /// True when a meeting title is empty / a placeholder, meaning the calendar
    /// is the source of truth. Any other title is treated as user-owned.
    /// Marked `nonisolated` so it can be called from inside GRDB's synchronous
    /// write closure (which is not main-actor isolated).
    nonisolated private static func isPlaceholderTitle(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty
            || trimmed == "New Meeting"
            || trimmed == "Untitled Meeting"
    }

    /// Creates or updates a `Meeting` record from a calendar event.
    ///
    /// Matching is done by `calendarEventId`. The fetch-and-insert/update is
    /// wrapped in a single GRDB write transaction to prevent races where two
    /// concurrent syncs could both see "no existing row" and double-insert.
    private func upsertMeeting(from event: CalendarEvent) async throws {
        try await AppDatabase.shared.writer.write { db in
            if var existing = try Meeting
                .filter(Column("calendarEventId") == event.id)
                .fetchOne(db)
            {
                // Always backfill participants and meetLink, regardless of meeting status.
                // This ensures completed meetings get participant data from calendar.
                var needsUpdate = false
                if !event.attendees.isEmpty && (existing.participants == nil || existing.participants!.isEmpty) {
                    existing.participants = event.attendees.joined(separator: ", ")
                    needsUpdate = true
                    Logger.calendar.debug("Backfilled participants for '\(event.title)': \(event.attendees.count) attendees")
                }
                // v3.10 RSVP gate: always refresh declined-attendee list — it
                // can change between syncs (someone declines after accepting).
                let declinedString = event.declinedAttendees.isEmpty
                    ? nil
                    : event.declinedAttendees.joined(separator: ", ")
                if existing.declinedAttendees != declinedString {
                    existing.declinedAttendees = declinedString
                    needsUpdate = true
                }
                if existing.meetLink == nil && event.meetLink != nil {
                    existing.meetLink = event.meetLink
                    needsUpdate = true
                }

                // Only update scheduling details for meetings that haven't started yet.
                if existing.status == .scheduled || existing.status == .notified {
                    // Don't clobber user-edited titles (see isPlaceholderTitle helper above).
                    if Self.isPlaceholderTitle(existing.title) {
                        existing.title = event.title
                    }
                    existing.scheduledStartDate = event.startDate
                    existing.scheduledEndDate = event.endDate
                    existing.meetLink = event.meetLink ?? existing.meetLink
                    needsUpdate = true
                }

                if needsUpdate {
                    try existing.update(db)
                    Logger.calendar.debug("Updated meeting '\(event.title)' from calendar")
                }
            } else {
                var meeting = Meeting(
                    title: event.title,
                    scheduledStartDate: event.startDate,
                    scheduledEndDate: event.endDate,
                    status: .scheduled,
                    calendarEventId: event.id
                )
                // Populate participants from calendar invite attendees on first insert.
                if !event.attendees.isEmpty {
                    meeting.participants = event.attendees.joined(separator: ", ")
                }
                if !event.declinedAttendees.isEmpty {
                    meeting.declinedAttendees = event.declinedAttendees.joined(separator: ", ")
                }
                meeting.meetLink = event.meetLink
                try meeting.insert(db)
                Logger.calendar.debug("Created new meeting '\(event.title)' from calendar (participants: \(event.attendees.count), declined: \(event.declinedAttendees.count))")
            }
        }
    }
}

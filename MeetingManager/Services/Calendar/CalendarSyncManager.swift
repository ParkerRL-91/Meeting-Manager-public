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
    }

    // MARK: - Periodic Sync

    /// Starts a periodic sync timer that fires at the given interval.
    ///
    /// Any existing timer is cancelled before starting the new one.
    /// The first sync runs immediately.
    ///
    /// - Parameter interval: Time between syncs, in seconds.
    func startPeriodicSync(interval: TimeInterval) async {
        await stopSync()

        Logger.calendar.info("Starting periodic calendar sync every \(Int(interval / 60)) minutes")

        // Fire immediately, then repeat.
        syncTask = Task { [weak self] in
            await self?.performSync()
        }

        syncTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.performSync()
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

        let calendarId = selectedCalendarId() ?? "primary"
        let events = try await calendarService.fetchEvents(
            accessToken: accessToken,
            from: from,
            to: to,
            calendarId: calendarId
        )

        var synced = 0
        for event in events {
            try await upsertMeeting(from: event)
            synced += 1
        }
        return synced
    }

    /// Pulls EventKit events and upserts them as Meeting rows. Dedupes by
    /// `calendarEventId` so events that also appear via Google are merged.
    private func syncApple() async -> Int {
        let events = await AppleCalendarService.shared.fetchUpcomingEvents(daysAhead: lookAheadDays)
        var synced = 0
        for event in events {
            do {
                let meeting = AppleCalendarService.shared.meeting(from: event)
                try await upsertAppleMeeting(meeting)
                synced += 1
            } catch {
                Logger.calendar.error("Apple Calendar upsert failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        return synced
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

    /// Returns the user-selected calendar ID from settings, or nil for "primary".
    private func selectedCalendarId() -> String? {
        try? AppDatabase.shared.writer.read { db in
            try AppSettings.fetchOne(db)?.selectedCalendarId
        } ?? nil
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
                meeting.meetLink = event.meetLink
                try meeting.insert(db)
                Logger.calendar.debug("Created new meeting '\(event.title)' from calendar (participants: \(event.attendees.count))")
            }
        }
    }
}

import Foundation
import os

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

    private var syncTimer: Timer?
    private var syncTask: Task<Void, Never>?

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
        // Timer is invalidated when the object is deallocated
    }

    // MARK: - Periodic Sync

    /// Starts a periodic sync timer that fires at the given interval.
    ///
    /// Any existing timer is cancelled before starting the new one.
    /// The first sync runs immediately.
    ///
    /// - Parameter interval: Time between syncs, in seconds.
    func startPeriodicSync(interval: TimeInterval) {
        stopSync()

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

    /// Stops the periodic sync timer and cancels any in-flight sync.
    func stopSync() {
        syncTimer?.invalidate()
        syncTimer = nil
        syncTask?.cancel()
        syncTask = nil
        Logger.calendar.info("Periodic calendar sync stopped")
    }

    /// Triggers a single sync cycle manually.
    func syncNow() async throws {
        guard authManager.isSignedIn else {
            throw CalendarSyncError.notSignedIn
        }
        await performSync()
        if let error = lastError {
            throw CalendarSyncError.syncFailed(error)
        }
    }

    // MARK: - Sync Logic

    private func performSync() async {
        guard authManager.isSignedIn else {
            Logger.calendar.debug("Skipping sync — not signed in")
            return
        }

        guard !isSyncing else {
            Logger.calendar.debug("Skipping sync — already in progress")
            return
        }

        isSyncing = true
        lastError = nil

        do {
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

            eventsSyncedCount = synced
            lastSyncDate = Date()

            Logger.calendar.info("Calendar sync complete: \(synced) events processed")
        } catch {
            lastError = error.localizedDescription
            Logger.calendar.error("Calendar sync failed: \(error.localizedDescription)")
        }

        isSyncing = false
    }

    /// Returns the user-selected calendar ID from settings, or nil for "primary".
    private func selectedCalendarId() -> String? {
        try? AppDatabase.shared.writer.read { db in
            try AppSettings.fetchOne(db)?.selectedCalendarId
        } ?? nil
    }

    /// Creates or updates a `Meeting` record from a calendar event.
    ///
    /// Matching is done by `calendarEventId`. If a meeting with the same
    /// calendar event ID already exists, its scheduling metadata is updated.
    /// Otherwise a new meeting is created.
    private func upsertMeeting(from event: CalendarEvent) async throws {
        if var existing = try await meetingRepository.findByCalendarEventId(event.id) {
            // Never overwrite meetings that are actively recording or already completed —
            // a calendar sync must not clobber runtime state (startDate, endDate, status, etc.).
            guard existing.status == .scheduled || existing.status == .notified else {
                Logger.calendar.debug("Skipping sync for '\(event.title)' — status is \(existing.status.rawValue)")
                return
            }
            // Update scheduling details only; don't overwrite user-created data.
            existing.title = event.title
            existing.scheduledStartDate = event.startDate
            existing.scheduledEndDate = event.endDate
            try await meetingRepository.save(&existing)
            Logger.calendar.debug("Updated meeting '\(event.title)' from calendar")
        } else {
            var meeting = Meeting(
                title: event.title,
                scheduledStartDate: event.startDate,
                scheduledEndDate: event.endDate,
                status: .scheduled,
                calendarEventId: event.id
            )
            try await meetingRepository.save(&meeting)
            Logger.calendar.debug("Created new meeting '\(event.title)' from calendar")
        }
    }
}

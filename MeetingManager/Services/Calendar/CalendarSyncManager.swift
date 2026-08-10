import AppKit
import Combine
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

// MARK: - Calendar Sync Health

/// Why calendar sync is not in a good state. Drives the Home banner copy.
enum CalendarHealthReason: Equatable, Sendable {
    /// Google confirmed the stored grant is dead (invalid_grant / 401 / 403).
    case authRevoked
    /// The Keychain grant is gone for an account that was previously connected —
    /// a failed sign-in, a cleared Keychain item. Distinct from never-connected,
    /// which is `CalendarConnectBanner`'s job and stays `.unknown`.
    case signedOut
    /// No sync has succeeded for longer than `stalenessThreshold`. Cause unknown —
    /// offline, throttled timer, wedged request.
    case syncStalled(since: Date)
    /// Selected calendars that keep returning 403/404/410.
    case calendarsUnreadable(ids: [String])
    /// Selected calendars that don't exist on the connected account at all. This is
    /// the account-switch signature: no HTTP error anywhere, sync reports success,
    /// and the calendars the user actually cares about are simply never fetched.
    case calendarsMissing(ids: [String], account: String?)
}

/// Verdict on whether calendar sync is working. `.unknown` is load-bearing: it is
/// the state during the async Keychain restore at launch, and it must render no
/// banner at all so a signed-in user never sees a flash of "disconnected".
enum CalendarSyncHealth: Equatable, Sendable {
    case unknown
    case healthy
    /// Some calendars are broken; the rest are syncing.
    case degraded(CalendarHealthReason)
    /// Nothing is syncing.
    case disconnected(CalendarHealthReason)
}

extension CalendarHealthReason {
    /// User-facing banner copy. Lives on the reason rather than in a view so the
    /// Home banner and the menu-bar row cannot drift apart — two surfaces
    /// describing the same outage differently is worse than one surface.
    var bannerMessage: String {
        switch self {
        case .authRevoked:
            return "Calendar disconnected — Google access was revoked. Reconnect to resume syncing."
        case .signedOut:
            return "Calendar sign-in was lost. Reconnect to resume syncing."
        case .syncStalled(let since):
            let elapsed = Date().timeIntervalSince(since)
            let stamp = elapsed < 24 * 60 * 60
                ? since.formatted(date: .omitted, time: .shortened)
                : since.formatted(date: .abbreviated, time: .shortened)
            return "Calendar hasn't synced since \(stamp). Reconnect or check your connection."
        case .calendarsMissing(_, let account):
            if let account {
                return "Some calendars you selected aren't on \(account). Reconnect to fix."
            }
            return "Some calendars you selected aren't on the connected account. Reconnect to fix."
        case .calendarsUnreadable(let ids):
            let noun = ids.count == 1 ? "calendar" : "calendars"
            return "\(ids.count) selected \(noun) can't be read. Reconnect Google Calendar."
        }
    }
}

/// Per-calendar failure bookkeeping. A calendar must fail repeatedly before it
/// counts toward a banner — one 500 shouldn't nag the user.
struct CalendarFetchFailure: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case revoked    // 401/403
        case notFound   // 404/410
        case transient  // everything else
    }
    var kind: Kind
    var firstSeen: Date
    var lastSeen: Date
    var consecutive: Int
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

    /// Current sync-health verdict. Derived, never persisted — see ADR-031.
    private(set) var health: CalendarSyncHealth = .unknown

    /// Identity of the current failure episode. A fresh UUID is minted when the
    /// reason changes or when a failure follows an intervening success, which is
    /// exactly the granularity the Home banner's dismissal needs. `nil` while
    /// healthy or unknown.
    private(set) var healthEpisodeId: UUID?

    /// When sync last completed with every selected calendar readable.
    ///
    /// Deliberately separate from `lastSyncDate`, which advances even when every
    /// calendar failed — that is why an 18-day outage could show a fresh
    /// "last synced" timestamp in Settings.
    private(set) var lastSuccessfulSyncDate: Date?

    /// `lastSuccessfulSyncDate` including the persisted floor, so a fresh launch
    /// reports the real age of the last good sync instead of "never". Read-only
    /// surface for UI copy (Home's empty-day caption); the health verdict uses the
    /// same pair directly.
    var effectiveLastSuccessfulSync: Date? {
        lastSuccessfulSyncDate ?? Self.persistedLastSuccessfulSync
    }

    // MARK: - Dependencies

    private let authManager: GoogleAuthManager
    private let calendarService: GoogleCalendarService
    private let meetingRepository: MeetingRepository

    // MARK: - Private

    /// Periodic tick. Uses `.common` run-loop mode like every other timer in the
    /// app (see `AppState.startProximityCheck`) so menu tracking and modal panels
    /// don't defer it. `.common` alone is not a reliability guarantee, though —
    /// `deadlineCatchUpIfNeeded()` is what actually recovers a missed tick.
    private var syncTimerCancellable: AnyCancellable?

    /// Health tick, owned by the manager rather than by Home. `refreshHealth()`
    /// also drives `deadlineCatchUpIfNeeded()`, so while Home was the only caller
    /// a window-closed process neither evaluated health nor self-healed a missed
    /// sync — the two states that most need a verdict were the ones with no
    /// evaluator running.
    private var healthTimerCancellable: AnyCancellable?

    nonisolated(unsafe) private var syncTask: Task<Void, Never>?

    /// Monotonic id for each `performSync` pass, so a pass that has been
    /// superseded (watchdog reset, `stopSync`, a later pass claiming the flags)
    /// cannot write anything when its hung fetch finally returns. Without it the
    /// stalled pass's `defer` cleared the *new* pass's `isSyncing` / `syncStartedAt`
    /// and its late outcome stamped `lastSuccessfulSyncDate` over a real failure —
    /// or latched `markAccessRevoked()` from an all-revoked result the app had
    /// already retried past.
    private var syncGeneration: UInt64 = 0

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
    nonisolated(unsafe) private var authStateObserver: NSObjectProtocol?
    /// Registered on `NSWorkspace.shared.notificationCenter`, NOT the default
    /// centre — it must be removed from the same one in `deinit`.
    nonisolated(unsafe) private var wakeObserver: NSObjectProtocol?

    /// How far into the future to fetch events during sync.
    private let lookAheadDays: Int = 7

    /// How far into the past to fetch events during sync.
    private let lookBehindDays: Int = 1

    // MARK: - Health Tracking

    /// Grace baseline so a fresh launch gets a full `stalenessThreshold` before
    /// anything can be called stale.
    private let processStart = Date()
    private var lastSyncAttemptDate: Date?
    private var syncStartedAt: Date?
    /// Suppresses the staleness rule briefly after waking, so a long sleep
    /// doesn't flash a banner in the seconds before the catch-up sync lands.
    private var wakeGraceUntil: Date?
    private var calendarFailures: [String: CalendarFetchFailure] = [:]
    private var missingCalendarIds: [String] = []
    private var lastCalendarListVerification: Date?
    private var lastVerifiedAccountEmail: String?
    /// Until a sync actually produces an outcome, health stays `.unknown`.
    private var hadSyncOutcomeThisLaunch = false

    /// No successful sync for this long ⇒ `.syncStalled`. Long enough that an
    /// offline lunch break or a coalesced timer stays silent.
    static let stalenessThreshold: TimeInterval = 60 * 60

    /// A sync running longer than this is assumed wedged and gets force-reset.
    /// Without this, one hung request pins `isSyncing` and every later tick
    /// no-ops forever.
    static let syncWatchdogTimeout: TimeInterval = 5 * 60

    /// Cadence for the calendarList membership check. Not every sync — it's an
    /// extra HTTP round trip and calendar membership changes rarely.
    static let calendarVerifyInterval: TimeInterval = 6 * 60 * 60

    /// Consecutive failed syncs before one calendar counts toward a banner.
    private static let failureEscalationThreshold = 2

    /// Persisted so an account switch that happens while the app is closed is
    /// still detected at next launch. Identity, not health — hence UserDefaults
    /// next to `calendar.source` rather than the high-churn appSettings row.
    private static let lastSyncedAccountKey = "calendar.lastSyncedAccountEmail"

    /// Persisted staleness floor. ADR-031 declared cross-launch staleness a
    /// non-goal; that was wrong — an in-memory-only floor handed every relaunch a
    /// fresh hour of grace, so nobody who quits the app nightly (or works in
    /// sub-hour sessions) could ever see a stalled banner during a multi-day
    /// outage. Same UserDefaults precedent as `lastSyncedAccountKey`: it stays out
    /// of the high-churn `appSettings` row.
    private static let lastSuccessfulSyncKey = "calendar.lastSuccessfulSyncAt"

    private static var persistedLastSuccessfulSync: Date? {
        let stamp = UserDefaults.standard.double(forKey: lastSuccessfulSyncKey)
        return stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
    }

    private static var persistedLastSyncedAccount: String? {
        UserDefaults.standard.string(forKey: lastSyncedAccountKey)
    }

    /// Erases the evidence-of-prior-connection that `.signedOut` health depends
    /// on. Called only by `GoogleAuthManager.signOut()`, the user-initiated
    /// disconnect — without it, choosing Disconnect in Settings would raise a
    /// permanent "sign-in was lost" warning about a state the user asked for.
    /// `markAccessRevoked()` deliberately does NOT do this: an expired credential
    /// is exactly the case that must still say "reconnect" (ADR-031 decision 3).
    static func forgetLastSyncedAccount() {
        UserDefaults.standard.removeObject(forKey: lastSyncedAccountKey)
    }

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
        syncTask?.cancel()
        changeDebounceTask?.cancel()
        if let obs = eventStoreObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = sourceChangeObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = storeReplacedObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = authStateObserver { NotificationCenter.default.removeObserver(obs) }
        // Registered on the workspace centre, so it must be removed from there.
        if let obs = wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(obs) }
    }

    // MARK: - Periodic Sync

    /// Starts a periodic sync timer that fires at the given interval.
    ///
    /// Any existing timer is cancelled before starting the new one.
    /// The first sync runs immediately.
    ///
    /// Also installs (idempotently) these observers:
    /// - `EKEventStore.eventStoreChangedNotification` so edits made in
    ///   Calendar.app trigger an immediate (debounced) sync rather than
    ///   waiting for the next tick.
    /// - `Notification.Name.calendarSourceChanged` so the user flipping
    ///   `calendar.source` in Settings restarts the loop without a relaunch.
    /// - `Notification.Name.googleAuthStateChanged` so a session restored
    ///   moments after launch syncs immediately instead of waiting out the
    ///   first full interval.
    /// - `NSWorkspace.didWakeNotification` so a machine that slept through
    ///   several ticks catches up on wake.
    ///
    /// - Parameter interval: Time between syncs, in seconds.
    func startPeriodicSync(interval: TimeInterval) async {
        await stopSync()

        lastInterval = interval
        Logger.calendar.info("Starting periodic calendar sync every \(Int(interval / 60)) minutes (source=\(CalendarSource.current.rawValue, privacy: .public))")

        // Fire immediately, then repeat.
        launchSync()

        syncTimerCancellable = Timer.publish(every: interval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.launchSync()
                }
            }

        healthTimerCancellable = Timer.publish(every: 60, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] date in
                Task { @MainActor [weak self] in
                    self?.refreshHealth(now: date)
                }
            }

        installEventStoreObserverIfNeeded()
        installSourceChangeObserverIfNeeded()
        installStoreReplacedObserverIfNeeded()
        installAuthStateObserverIfNeeded()
        installWakeObserverIfNeeded()
    }

    /// The single way to start a sync pass.
    ///
    /// Every entry path must route through here so `syncTask` actually refers to
    /// the pass that is running. It used to be assigned only by
    /// `startPeriodicSync`, while the timer tick, wake, auth, catch-up and resync
    /// paths each ran `performSync` in an anonymous `Task` — so the watchdog's
    /// `syncTask?.cancel()` cancelled a long-finished task and left the wedged one
    /// running.
    ///
    /// The predecessor handle is what the watchdog cancels. `syncTask` at the
    /// moment the watchdog fires is the watchdog's OWN pass, so cancelling that
    /// would make every tick kill itself — a permanently broken sync, worse than
    /// the no-op it replaced.
    @discardableResult
    private func launchSync() -> Task<Void, Never> {
        let predecessor = syncTask
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performSync(predecessor: predecessor)
        }
        syncTask = task
        return task
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
                self?.launchSync()
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
            self.launchSync()
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

    /// React to Google auth transitions.
    ///
    /// The Keychain restore runs off the init path (a blocking `SecItemCopyMatching`
    /// froze the app for minutes on 2026-06-11), so at launch `isSignedIn` is false
    /// even for a signed-in user and the immediate sync gets skipped. Before this
    /// observer existed, nothing retried for a full 15 minutes.
    private func installAuthStateObserverIfNeeded() {
        guard authStateObserver == nil else { return }
        authStateObserver = NotificationCenter.default.addObserver(
            forName: .googleAuthStateChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let source = CalendarSource.current
                let googleActive = source == .googleCalendar || source == .both
                if googleActive, self.authManager.isSignedIn, !self.hadSyncOutcomeThisLaunch {
                    Logger.calendar.info("Google auth became usable — syncing without waiting for the next tick")
                    self.launchSync()
                } else {
                    self.refreshHealth()
                }
            }
        }
    }

    /// Catch up after sleep. A timer that should have fired while asleep fires
    /// once on wake and re-anchors, so a long sleep otherwise leaves the DB stale
    /// until the next full interval.
    private func installWakeObserverIfNeeded() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, CalendarSource.current != .none else { return }
                // Grace first, then sync. Order matters: the staleness rule must
                // be muzzled before any health evaluation can run.
                self.wakeGraceUntil = Date().addingTimeInterval(90)
                Logger.calendar.info("Woke from sleep — catching up on calendar sync")
                AppFileLogger.shared.log("CALSYNC: wake catch-up")
                self.launchSync()
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
        syncTimerCancellable = nil
        healthTimerCancellable = nil
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
        // Routed through `syncTask` like every other entry path so the watchdog
        // can cancel it, but awaited here because the caller reports the outcome.
        await launchSync().value
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
            var anyCalendarFailed = false
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
                    anyCalendarFailed = true
                    Logger.calendar.error("Google backfill failed for calendar=\(calendarId, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
            // A clean wide backfill is a successful sync. Without this, hitting
            // "Re-sync" would clear the real problem but leave a stale banner up
            // until the next periodic tick.
            if !anyCalendarFailed {
                calendarFailures.removeAll()
                recordSuccessfulSync(at: Date())
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
        hadSyncOutcomeThisLaunch = true
        refreshHealth()
        return processed
    }

    // MARK: - Sync Logic

    /// - Parameter predecessor: the previously launched pass, i.e. the one holding
    ///   `isSyncing` if this pass finds it wedged. Only `launchSync()` calls this.
    private func performSync(predecessor: Task<Void, Never>?) async {
        let source = CalendarSource.current

        if isSyncing {
            // Watchdog. `isSyncing` used to be a bare early-return, so a single
            // hung request (the fetch path sets no request timeout) pinned it
            // true and silently no-op'd every subsequent tick for the rest of
            // the process's life.
            if let started = syncStartedAt,
               Date().timeIntervalSince(started) > Self.syncWatchdogTimeout {
                let stuckFor = Int(Date().timeIntervalSince(started))
                Logger.calendar.error("Sync wedged for \(stuckFor)s — forcing reset")
                AppFileLogger.shared.log("CALSYNC: watchdog reset after \(stuckFor)s")
                predecessor?.cancel()
                isSyncing = false
                syncStartedAt = nil
            } else {
                Logger.calendar.debug("Skipping sync — already in progress")
                return
            }
        }

        // For Google-backed sources we still require a signed-in account.
        //
        // Deliberately does NOT touch `health`: during the async Keychain restore
        // `isSignedIn` is false for a genuinely signed-in user, and writing any
        // verdict here is exactly what would flash a wrong banner at launch.
        // `.googleAuthStateChanged` re-drives us the moment restore lands.
        if (source == .googleCalendar || source == .both) && !authManager.isSignedIn {
            Logger.calendar.debug("Skipping sync — Google not signed in")
            refreshHealth()
            return
        }

        if source == .none {
            Logger.calendar.debug("Skipping sync — calendar source set to .none")
            refreshHealth()
            return
        }

        syncGeneration += 1
        let generation = syncGeneration

        isSyncing = true
        syncStartedAt = Date()
        lastSyncAttemptDate = Date()
        lastError = nil
        defer {
            // Only the pass that still owns the flags may clear them. A wedged
            // pass whose fetch returns after a watchdog reset would otherwise
            // clear the *replacement* pass's `isSyncing`, letting two passes write
            // meeting rows concurrently and re-arming the same wedge.
            if generation == syncGeneration {
                isSyncing = false
                syncStartedAt = nil
            }
        }

        AppFileLogger.shared.log("CALSYNC: start source=\(source.rawValue) calendars=\(selectedGoogleCalendarIds().count)")

        do {
            var synced = 0

            if source == .googleCalendar || source == .both {
                synced += try await syncGoogle(generation: generation)
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
            AppFileLogger.shared.log("CALSYNC: failed error=\(error.localizedDescription)")
        }

        guard generation == syncGeneration else {
            Logger.calendar.warning("Superseded sync pass finished — discarding its verdict")
            AppFileLogger.shared.log("CALSYNC: superseded pass discarded")
            return
        }

        hadSyncOutcomeThisLaunch = true
        refreshHealth()
    }

    /// Existing Google Calendar sync path, factored out so the source switch is readable.
    private func syncGoogle(generation: UInt64) async throws -> Int {
        let accessToken = try await authManager.refreshTokenIfNeeded()

        let now = Date()
        let from = Calendar.current.date(byAdding: .day, value: -lookBehindDays, to: now)!
        let to = Calendar.current.date(byAdding: .day, value: lookAheadDays, to: now)!

        let calendarIds = selectedGoogleCalendarIds()
        var synced = 0
        var succeeded: Set<String> = []
        var failures: [String: CalendarFetchFailure.Kind] = [:]
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
                succeeded.insert(calendarId)
            } catch {
                let kind = Self.classify(error)
                Logger.calendar.error("Google sync failed for calendar=\(calendarId, privacy: .public): \(error.localizedDescription, privacy: .public)")
                failures[calendarId] = kind
                // One bad calendar shouldn't kill the whole sync — keep going.
                // The failure is recorded rather than dropped, though: silently
                // swallowing it here is what let a broken calendar look healthy.
            }
        }

        AppFileLogger.shared.log(
            "CALSYNC: done synced=\(synced) ok=[\(succeeded.sorted().joined(separator: ","))] failed=[\(failures.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ","))]"
        )

        // A superseded pass's result describes a state the app has already moved
        // past: recording it could stamp `lastSuccessfulSyncDate` over a real
        // failure, or latch `markAccessRevoked()` from an all-revoked result that
        // a later pass already retried successfully.
        guard generation == syncGeneration else { return synced }

        recordGoogleOutcome(succeeded: succeeded, failures: failures)
        await detectAccountChangeAndVerify(accessToken: accessToken)
        return synced
    }

    /// Classify a per-calendar fetch error by whether retrying or waiting can help.
    private static func classify(_ error: Error) -> CalendarFetchFailure.Kind {
        switch error {
        case GoogleCalendarError.accessRevoked:
            return .revoked
        case GoogleCalendarError.httpError(404, _), GoogleCalendarError.httpError(410, _):
            return .notFound
        default:
            return .transient
        }
    }

    /// Folds one Google pass into the per-calendar failure ledger.
    ///
    /// `.transient` failures never raise a banner on their own — they only
    /// withhold `lastSuccessfulSyncDate`, which feeds the one-hour staleness
    /// rule. That plus `failureEscalationThreshold` is what keeps a dropped
    /// wifi connection silent.
    private func recordGoogleOutcome(succeeded: Set<String>, failures: [String: CalendarFetchFailure.Kind]) {
        let now = Date()

        // Forget calendars the user has since deselected. Without this,
        // deselecting a broken calendar would leave its entry in the ledger and
        // the banner would never clear.
        let stillSelected = succeeded.union(failures.keys)
        calendarFailures = calendarFailures.filter { stillSelected.contains($0.key) }

        for id in succeeded { calendarFailures[id] = nil }

        for (id, kind) in failures {
            if var existing = calendarFailures[id] {
                existing.kind = kind
                existing.lastSeen = now
                existing.consecutive += 1
                calendarFailures[id] = existing
            } else {
                calendarFailures[id] = CalendarFetchFailure(
                    kind: kind, firstSeen: now, lastSeen: now, consecutive: 1
                )
            }
        }

        // A blanket revocation across every selected calendar is a dead
        // credential, not N separate ACL problems — latch it so the sync guard
        // stops re-POSTing a dead token every tick.
        if !failures.isEmpty, succeeded.isEmpty,
           failures.values.allSatisfy({ $0 == .revoked }) {
            authManager.markAccessRevoked()
            return
        }

        if failures.isEmpty {
            recordSuccessfulSync(at: now)
        }
    }

    /// The single writer for `lastSuccessfulSyncDate`, so the persisted mirror
    /// that carries the staleness floor across launches can never drift from the
    /// in-memory value.
    private func recordSuccessfulSync(at date: Date) {
        lastSuccessfulSyncDate = date
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: Self.lastSuccessfulSyncKey)
    }

    /// Selected calendars that have failed non-transiently often enough to count.
    private var escalatedUnreadableIds: [String] {
        calendarFailures
            .filter { $0.value.kind != .transient && $0.value.consecutive >= Self.failureEscalationThreshold }
            .keys
            .sorted()
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

    // MARK: - Account & Calendar Verification

    /// Detects that the connected Google account changed, and verifies the user's
    /// selected calendars still exist on it.
    ///
    /// This is the detector the July 2026 incident actually needed. When the
    /// account was switched from work to personal, every selected calendar ID was
    /// valid on the *new* account: no 401, no 403, no 404. Sync reported success
    /// every 15 minutes while the work calendar — which was no longer selected and
    /// no longer reachable — silently stopped updating for 18 days. Only comparing
    /// the selection against the connected account's calendar list catches it.
    private func detectAccountChangeAndVerify(accessToken: String) async {
        let current = authManager.userEmail
        let previous = UserDefaults.standard.string(forKey: Self.lastSyncedAccountKey)

        var force = false
        if let current, let previous, previous != current {
            Logger.calendar.warning("Connected Google account changed \(previous, privacy: .public) → \(current, privacy: .public)")
            AppFileLogger.shared.log("CALSYNC: account changed from=\(previous) to=\(current)")
            // Failures attributed to the old account mean nothing now.
            calendarFailures.removeAll()
            force = true
        }
        if let current {
            UserDefaults.standard.set(current, forKey: Self.lastSyncedAccountKey)
        }

        await verifySelectedCalendars(accessToken: accessToken, force: force)
    }

    /// Confirms every selected Google calendar ID exists on the connected account.
    ///
    /// Deliberately not run on every sync — it is an extra HTTP round trip and
    /// calendar membership changes rarely. Runs on the first sync of a launch, on
    /// an account change, on an explicit reconnect, and otherwise at most every
    /// `calendarVerifyInterval`.
    private func verifySelectedCalendars(accessToken: String, force: Bool = false) async {
        let now = Date()
        let accountChanged = authManager.userEmail != lastVerifiedAccountEmail
        if !force, !accountChanged, let last = lastCalendarListVerification,
           now.timeIntervalSince(last) < Self.calendarVerifyInterval {
            return
        }

        let selected = Set(selectedGoogleCalendarIds())
        // "primary" is an alias that always resolves for whoever is connected, so
        // it can never be "missing" — and it is precisely the ID that silently
        // re-points at a different calendar when the account changes.
        let checkable = selected.subtracting(["primary"])
        guard !checkable.isEmpty else {
            missingCalendarIds = []
            lastCalendarListVerification = now
            lastVerifiedAccountEmail = authManager.userEmail
            return
        }

        do {
            let available = Set(try await calendarService.listCalendars(accessToken: accessToken).map(\.id))
            missingCalendarIds = checkable.subtracting(available).sorted()
            lastCalendarListVerification = now
            lastVerifiedAccountEmail = authManager.userEmail
            AppFileLogger.shared.log(
                "CALSYNC: verify account=\(authManager.userEmail ?? "unknown") missing=[\(missingCalendarIds.joined(separator: ","))]"
            )
        } catch GoogleCalendarError.accessRevoked {
            authManager.markAccessRevoked()
        } catch {
            // A failed verification must never itself change health — the previous
            // `missingCalendarIds` verdict stands and we retry on the next cadence.
            Logger.calendar.warning("Calendar list verification failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Drops the cached verification verdict so the next sync re-checks the
    /// selection against the connected account immediately, whatever the cadence
    /// would otherwise allow. Called by the reconnect path — reconnecting means
    /// "recheck now", including when the user signs back in as the same account.
    func invalidateCalendarVerification() {
        lastCalendarListVerification = nil
        lastVerifiedAccountEmail = nil
        missingCalendarIds = []
        calendarFailures.removeAll()
    }

    // MARK: - Health Evaluation

    /// Re-derives `health` from current state.
    ///
    /// Pure and idempotent, so it is safe to call from a UI tick — Home's existing
    /// 60-second timer drives it, which is what lets the staleness verdict appear
    /// without the user navigating anywhere. Also the hook for the deadline
    /// catch-up that recovers a throttled or missed timer.
    func refreshHealth(now: Date = Date()) {
        deadlineCatchUpIfNeeded(now: now)

        let newHealth = evaluateHealth(now: now)

        let newEpisodeId: UUID?
        switch newHealth {
        case .unknown, .healthy:
            newEpisodeId = nil
        case .degraded(let reason), .disconnected(let reason):
            let previousReason: CalendarHealthReason?
            switch health {
            case .degraded(let r), .disconnected(let r): previousReason = r
            case .unknown, .healthy: previousReason = nil
            }
            // A fresh episode when the reason changes, or when a failure follows
            // an intervening success. Otherwise the same episode persists so a
            // dismissal sticks for as long as the problem is unchanged.
            newEpisodeId = (previousReason == reason) ? healthEpisodeId ?? UUID() : UUID()
        }

        // `@Observable` notifies on every assignment with no equality check, and
        // this runs every 60s — guard both writes or the whole Home view
        // re-renders on a tick that changed nothing.
        if health != newHealth {
            AppFileLogger.shared.log(
                "CALSYNC: health \(Self.describe(health)) → \(Self.describe(newHealth)) episode=\(newEpisodeId?.uuidString.prefix(8) ?? "none")"
            )
            health = newHealth
        }
        if healthEpisodeId != newEpisodeId { healthEpisodeId = newEpisodeId }
    }

    private func evaluateHealth(now: Date) -> CalendarSyncHealth {
        let source = CalendarSource.current
        if source == .none { return .unknown }

        let googleActive = source == .googleCalendar || source == .both

        if googleActive, authManager.accessRevoked {
            return .disconnected(.authRevoked)
        }

        // Ahead of the `hadSyncOutcomeThisLaunch` gate on purpose: a signed-out
        // account never produces a sync outcome, so behind the gate this pinned
        // health at `.unknown` for the whole launch while cached meetings made the
        // schedule look fine — the exact silent failure this feature exists to
        // prevent. Requires evidence of a prior connection; a never-connected user
        // stays `.unknown` so `CalendarConnectBanner` keeps that job.
        if googleActive, authManager.didAttemptSessionRestore, !authManager.isSignedIn,
           !authManager.accessRevoked, Self.persistedLastSyncedAccount != nil {
            return .disconnected(.signedOut)
        }

        // Until the Keychain restore has resolved and a sync has produced an
        // outcome, we genuinely don't know — say so rather than guessing.
        if googleActive, !authManager.didAttemptSessionRestore { return .unknown }
        if !hadSyncOutcomeThisLaunch { return .unknown }

        // Never-connected (no prior account on record) is the existing
        // CalendarConnectBanner's job.
        if googleActive, !authManager.isSignedIn { return .unknown }

        // Both of these describe Google calendars, and the banner's only action is
        // a Google OAuth handshake — so they must not surface for someone who has
        // switched to Apple-only and still has a stale Google verdict cached.
        if googleActive, !missingCalendarIds.isEmpty {
            return .degraded(.calendarsMissing(ids: missingCalendarIds, account: authManager.userEmail))
        }

        let unreadable = escalatedUnreadableIds
        if googleActive, !unreadable.isEmpty {
            return .degraded(.calendarsUnreadable(ids: unreadable))
        }

        // The persisted floor sits between the two so a multi-day outage keeps
        // accumulating across relaunches. It is still behind the
        // `hadSyncOutcomeThisLaunch` gate above, so it cannot flash at launch
        // before this process has learned anything.
        let staleSince = lastSuccessfulSyncDate ?? Self.persistedLastSuccessfulSync ?? processStart
        let pastWakeGrace = now > (wakeGraceUntil ?? .distantPast)
        if pastWakeGrace, now.timeIntervalSince(staleSince) > Self.stalenessThreshold {
            // Carries `staleSince`, never `now` — a moving date would mint a new
            // episode on every 60-second tick and defeat dismissal.
            return .disconnected(.syncStalled(since: staleSince))
        }

        return .healthy
    }

    /// Runs a sync when the last attempt is overdue by more than half an interval.
    ///
    /// This — not the run-loop mode — is what makes the periodic refresh
    /// self-healing. The app has no App Nap mitigation, so a backgrounded
    /// window-closed process can have its main-run-loop timer throttled hard.
    private func deadlineCatchUpIfNeeded(now: Date) {
        guard CalendarSource.current != .none, !isSyncingWithinWatchdog(now: now) else { return }
        let lastAttempt = lastSyncAttemptDate ?? processStart
        guard now.timeIntervalSince(lastAttempt) > lastInterval * 1.5 else { return }
        Logger.calendar.info("Sync overdue by more than half an interval — catching up")
        launchSync()
    }

    /// Kicks a sync if the last attempt is more than 5 minutes old. Called when
    /// the app comes forward, covering the lid-open case where `didWake` fires
    /// before the network is actually reachable.
    func resyncIfStale() {
        let now = Date()
        guard CalendarSource.current != .none, !isSyncingWithinWatchdog(now: now) else { return }
        let lastAttempt = lastSyncAttemptDate ?? processStart
        guard now.timeIntervalSince(lastAttempt) > 5 * 60 else { return }
        launchSync()
    }

    /// True when a sync is running and has NOT yet blown past the watchdog
    /// timeout.
    ///
    /// The recovery paths must use this rather than a bare `isSyncing`: the
    /// watchdog that clears a wedged flag lives inside `performSync`, so bailing
    /// on `isSyncing` alone meant that once the periodic timer was gone, nothing
    /// could ever reach the code that unwedges it.
    private func isSyncingWithinWatchdog(now: Date) -> Bool {
        guard isSyncing else { return false }
        guard let started = syncStartedAt else { return true }
        return now.timeIntervalSince(started) <= Self.syncWatchdogTimeout
    }

    private static func describe(_ health: CalendarSyncHealth) -> String {
        switch health {
        case .unknown: return "unknown"
        case .healthy: return "healthy"
        case .degraded(let r): return "degraded(\(describe(r)))"
        case .disconnected(let r): return "disconnected(\(describe(r)))"
        }
    }

    private static func describe(_ reason: CalendarHealthReason) -> String {
        switch reason {
        case .authRevoked: return "authRevoked"
        case .signedOut: return "signedOut"
        case .syncStalled: return "syncStalled"
        case .calendarsUnreadable(let ids): return "calendarsUnreadable:\(ids.count)"
        case .calendarsMissing(let ids, _): return "calendarsMissing:\(ids.count)"
        }
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
                    existing.meetLink = Self.refreshedMeetLink(existing: existing.meetLink, derived: incoming.meetLink)
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

    /// Resolves the `meetLink` to persist for a scheduled/notified calendar row
    /// on re-sync. A newly derived non-nil link REPLACES the stored one (the
    /// call moved Meet→Zoom, or a Zoom URL rotated); a nil derivation preserves
    /// the existing link rather than nulling it out. Completed/recorded rows are
    /// never routed through here — they are only backfilled when empty.
    /// `nonisolated` so GRDB's synchronous write closure can call it. (TASK-127)
    nonisolated static func refreshedMeetLink(existing: String?, derived: String?) -> String? {
        derived ?? existing
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
                    existing.meetLink = Self.refreshedMeetLink(existing: existing.meetLink, derived: event.meetLink)
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

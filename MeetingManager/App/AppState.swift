import AVFoundation
import SwiftUI
import Combine
import GRDB
import Speech
import SpeakerKit
import UserNotifications
import os

@Observable
@MainActor
final class AppState {
    /// Shared instance for access from AppDelegate (menu bar popover).
    /// Set during init — there is exactly one AppState per app lifetime.
    /// Held as Optional (not IUO) so early access during app launch is a
    /// compile-time-visible nil check rather than a runtime crash.
    static private(set) var shared: AppState?

    /// Stable accessor for the App struct's `@State` initial value. SwiftUI
    /// re-creates the App struct freely; constructing a fresh AppState there
    /// forked state — the discarded copy overwrote `AppState.shared`, so the
    /// HUD, notification actions, and menu bar read a frozen snapshot with no
    /// observers for the rest of the run. Returning the live instance means a
    /// re-creation never constructs a fork in the first place.
    static func sharedOrCreate() -> AppState {
        if let existing = shared, isInitialized { return existing }
        return AppState()
    }

    // MARK: - Sidebar Navigation

    /// Which top-level section is active in the sidebar/detail area.
    var sidebarDestination: SidebarDestination = .home

    var selectedMeetingId: String? {
        didSet {
            if selectedMeetingId != nil {
                sidebarDestination = .meetings
            }
        }
    }

    /// PRJ-013: deep-link target for the task manager. When set, the task board
    /// shell focuses this task's detail. Notification "Open Task" actions and
    /// per-task alerts (Phase 5) route through this alongside `.taskBoard`.
    var selectedTaskId: Int64?

    /// PRJ-014: reactive gate for the Knowledge Base viewer. `rootURL` is
    /// UserDefaults-backed (not observable), so this mirror — seeded at init and
    /// flipped by `KnowledgeBaseService.setRoot`/`clearRoot` — is what the
    /// sidebar item and discoverability hooks observe.
    var kbConfigured: Bool = false

    /// PRJ-014: deep-link target for the KB browser. Citation click-through
    /// (Phase 4) sets this alongside `sidebarDestination = .knowledgeBase`. The
    /// browser consumes it to select the cited file. Unused until later phases.
    var selectedKBPath: String?
    var isRecording = false
    var activeMeeting: Meeting?

    /// TASK-078: a clip span to cue once its meeting's player has loaded.
    /// Set when opening a quote from the global Key Quotes list; consumed
    /// (and cleared) by MeetingDetailView after it loads the player.
    var pendingPlaybackRange: (meetingId: String, start: Double, end: Double)?

    /// TASK-094: incremented when a topic backfill run finishes. TopicTrackersView
    /// observes this to refresh counts/hits after a just-added topic has been
    /// scanned against history, so a new topic doesn't sit at a stale "0 meetings".
    var topicBackfillToken = 0

    /// TASK-094 (REQ-2): set when a topic is added/edited while a backfill is
    /// already running. That in-flight pass snapshotted the old tracker set, so
    /// the new topic wouldn't be scanned; `runTopicBackfill` honors this flag by
    /// looping for another pass before it signals completion.
    private var topicBackfillRerunRequested = false

    /// True while the recording mic has disconnected and the app is holding the
    /// recording open waiting for a replacement (system audio keeps capturing).
    /// Mirrored from `AudioCaptureService`; drives the inline red mic-recovery
    /// banner + picker in the recording bar (TASK-104). The meeting is NOT ended on
    /// mic loss alone — only the genuine all-silent 5-minute auto-stop ends it.
    var isMicRecovering = false

    /// Signal-independent mic-health snapshot (TASK-095), mirrored from
    /// `AudioCaptureService` on the audio-level poll. Drives the recording-bar
    /// live/identity/muted status (REQ-6), which is shown even while the user is
    /// silent — distinct from the `micLevel` talk-time meter.
    var micHealth: MicHealthSnapshot = .unknown

    /// Debounces rapid in-app mic-picker changes into a single live switch.
    private var micSwitchDebounceTask: Task<Void, Never>?

    /// The resolved template for the current/most-recently-started recording.
    /// Set when recording starts (from meeting.templateId or series inheritance).
    /// Read by LiveMeetingView to pre-populate the notepad.
    var activeTemplate: MeetingTemplate?

    /// True only when the current recording was auto-started by BrowserCallDetector.
    /// Used to gate `callAppTerminated` auto-stop — manually-started recordings
    /// must not be stopped just because the browser-call heuristic loses signal.
    private var recordingStartedByDetector = false

    /// Departure confirmation (TASK-072): the detected call ended while a
    /// MANUALLY-started recording runs. Back-to-back meetings made this the
    /// top messy-data source — forgetting to stop meeting A merges it with
    /// meeting B. Silence-based auto-stop was tried and rejected (false
    /// stops); call-presence + a confirmation window is the design: prompt,
    /// then auto-end after the grace period unless the user objects.
    struct DeparturePrompt: Equatable {
        let meetingTitle: String
        let firedAt: Date
    }
    var departurePrompt: DeparturePrompt?
    private var departureAutoEndTask: Task<Void, Never>?
    private var departureSuppressedUntil: Date?
    /// Grace before auto-end once the prompt shows.
    static let departureGraceSeconds: TimeInterval = 180

    /// True when the current recording is a reopen session appending to an existing meeting.
    private(set) var isReopening = false

    /// Live audio levels mirrored from AudioCaptureService for SwiftUI views.
    /// AudioCaptureService is @ObservableObject but nested inside @Observable AppState,
    /// so SwiftUI can't see its @Published changes. These are updated on a 10Hz timer.
    var micLevel: Float = 0
    var systemLevel: Float = 0
    private var levelPollingCancellable: AnyCancellable?

    /// The name of a detected call app when a meeting is in progress but recording hasn't started.
    /// Cleared when recording begins or the call app exits.
    private(set) var detectedCallApp: String?

    /// Signals the active meeting view to focus and select its title field so the user can
    /// rename immediately after an ad-hoc "New Meeting" is created. The consumer resets this
    /// to false after handling.
    var focusTitleForRename: Bool = false

    /// Timestamp of the last call detection event, used to deduplicate rapid-fire
    /// notifications from CallDetectionService and BrowserCallDetector firing for
    /// the same meeting (e.g., Zoom native app + Zoom in browser tab).
    private var lastCallDetectionTime: Date?
    var meetings: [Meeting] = []
    var upcomingMeetings: [Meeting] = [] { didSet { _cachedFolders = nil } }
    var pastMeetings: [Meeting] = []    { didSet { _cachedFolders = nil } }

    /// The next scheduled/notified meeting within the next 2 hours that isn't
    /// the currently active meeting. Derived from the already-loaded `upcomingMeetings`
    /// so no async DB call is needed.
    var nextUpcomingMeeting: Meeting? {
        let now = Date()
        let twoHoursFromNow = now.addingTimeInterval(2 * 3600)
        let activeId = activeMeeting?.id
        return upcomingMeetings.first { meeting in
            guard meeting.id != activeId else { return false }
            guard meeting.status == .scheduled || meeting.status == .notified else { return false }
            guard let start = meeting.scheduledStartDate else { return false }
            return start > now && start <= twoHoursFromNow
        }
    }

    /// Cached folder groupings — invalidated whenever meetings change.
    /// Presents the global search sheet (⌘K — TASK-039).
    var showGlobalSearch = false

    private var _cachedFolders: [MeetingFolder]?
    var navigationPath = NavigationPath()

    /// The count of today's meetings that need prep (carryOver category).
    /// Updated when the Daily Brief view loads. Used for the sidebar badge.
    var dailyBriefMeetingsNeedingPrep: Int = 0

    // MARK: - Daily AI Brief (observable, surfaces in DailyBriefView)

    /// AI-narrated daily brief text. Populated from the on-disk cache on
    /// launch and refreshed in the background by `maybeRegenerateDailyBrief`.
    /// The View reads this directly so the brief appears instantly without
    /// the user clicking "Generate".
    var dailyBriefAIText: String?

    /// When the current `dailyBriefAIText` was generated. `nil` while
    /// regenerating with no prior text on disk.
    var dailyBriefGeneratedAt: Date?

    /// Model that produced the current text — surfaced as a small footer hint.
    var dailyBriefModel: String?

    /// PRJ-014: KB documents fed to the model as background for the current brief,
    /// threaded from `DailyBriefCache.Entry.kbSources`. The View renders these under
    /// "Context from your Knowledge Base"; old cache entries decode as nil → empty.
    var dailyBriefKBSources: [KBSourceRef] = []

    /// True while a background generation is in flight. Drives the spinner /
    /// "Generating…" label in DailyBriefView.
    var isGeneratingDailyBrief: Bool = false

    /// Last generation error (if any), shown inline in the View.
    var dailyBriefError: String?

    /// True when brief generation was deferred because the AI backend was busy
    /// with other work (e.g. a bulk re-transcription saturating the local
    /// model), rather than genuinely failing. The View shows a neutral
    /// "Daily brief queued" notice instead of a red error, and the brief is
    /// retried automatically once the task queue drains.
    var dailyBriefQueued: Bool = false

    /// Cancellation token + signature for the most-recent generation, so
    /// repeated triggers don't fire concurrent regenerations.
    private var dailyBriefGenerationTask: Task<Void, Never>?
    private var currentDailyBriefSignature: String?
    private let dailyBriefAIService = DailyBriefAIService()

    /// Persisted Ask Anything conversation. Stored here so the history survives
    /// the user navigating away from GlobalChatView and returning.
    var globalChatMessages: [GlobalChatMessage] = []

    /// When set, SettingsView will switch to this tab index and clear the value.
    /// Tab indices: 0 General, 1 Audio, 2 Transcription, 3 Calendar, 4 AI(Claude), 5 AI(Local).
    var pendingSettingsTab: Int?

    /// The user's persisted settings. Changes are automatically written to the database.
    var settings: AppSettings = .default {
        didSet {
            guard settings != oldValue else { return }
            persistSettings()
            // System banner notifications are intentionally disabled — the
            // in-app HUD (MeetingReminderWindowController) is the only
            // pre-meeting alert. Lead-time changes still affect the proximity
            // warning posted to the menu bar via .meetingStartingSoon.
            if settings.calendarSyncIntervalMinutes != oldValue.calendarSyncIntervalMinutes {
                let intervalSeconds = TimeInterval(max(1, settings.calendarSyncIntervalMinutes) * 60)
                Task {
                    await self.calendarSyncManager.startPeriodicSync(interval: intervalSeconds)
                }
            }
            // Hot-swap the recording mic when the user changes the override mid-meeting.
            if isRecording,
               settings.micOverrideEnabled != oldValue.micOverrideEnabled ||
               settings.micOverrideDeviceID != oldValue.micOverrideDeviceID {
                scheduleMicSwitch()
            }
        }
    }

    // Services
    let database: AppDatabase
    let ollamaService: OllamaService
    let embeddingService: EmbeddingService
    let interactiveAIBroker: InteractiveAIBroker
    /// Shared transcript-synced player (TASK-077). One instance so the
    /// transport persists across meeting-detail tabs.
    let audioPlayback = AudioPlaybackService()
    let ollamaInstaller: OllamaInstaller
    let meetingRepository: MeetingRepository
    let transcriptRepository: TranscriptRepository
    let noteRepository: NoteRepository
    let summaryRepository: SummaryRepository
    let enhancedNoteRepository: EnhancedNoteRepository
    /// Unified task model repository (PRJ-013). Held so the AppDelegate and the
    /// per-task notification reconcile can reach it via `AppState.shared`.
    let taskRepository: TaskRepository
    let audioCaptureService: AudioCaptureService
    let transcriptionService: TranscriptionService
    let appleSpeechTranscriber: AppleSpeechTranscriber
    let taskQueueManager: TaskQueueManager
    let notificationService: NotificationService

    /// Single source of truth for Google OAuth state. Shared between the
    /// running `CalendarSyncManager` and the Settings UI so signing in /
    /// signing out from one updates the other immediately.
    let googleAuthManager: GoogleAuthManager

    /// Drives periodic Google + Apple Calendar sync. Constructed eagerly at
    /// launch so the periodic timer fires regardless of which source the user
    /// picked. Apple-only users no longer rely on a manual nudge from Settings.
    let calendarSyncManager: CalendarSyncManager

    // State machine — single source of truth for meeting lifecycle
    private(set) var stateMachine: MeetingStateMachine

    /// Detects meeting participants from screen when calendar data is absent.
    /// Only runs when meeting.participantList.isEmpty at recording start.
    private var participantDetectionService: ParticipantDetectionService?

    /// True while the WhisperKit model is downloading/loading.
    private(set) var isLoadingModel = false

    /// Synthetic model download progress (0.0–1.0) that combines real WhisperKit progress
    /// with a time-based estimate so the UI shows continuous advancement.
    var modelDownloadProgress: Double = 0
    private var modelProgressCancellable: AnyCancellable?

    /// User-visible error from the most recent operation (shown via alert).
    var lastUserError: String?

    /// Note drafts found at launch whose sidecar content diverged from the
    /// stored note (a previous session ended before SQLite committed). Drives
    /// the startup `DraftRecoverySheet`. Empty when there's nothing to recover.
    var recoverableDrafts: [RecoverableDraft] = []

    /// Meetings queued for transcription when model wasn't available.
    /// Persisted via UserDefaults so they survive app restarts.
    private static let pendingTranscriptionKey = "pendingTranscriptions"

    private var cancellables = Set<AnyCancellable>()
    private var proximityPollingCancellable: AnyCancellable?
    private var prepContextTimerCancellable: AnyCancellable?

    /// Tracks meetings for which a `meetingStartingSoon` notification has already been posted.
    /// Prevents posting 4+ duplicates across timer ticks for the same meeting.
    private var notifiedMeetingIds: Set<String> = []

    /// The id of an upcoming meeting we've offered to switch to while
    /// recording a different one. Drives the persistent "Switch meetings"
    /// banner. nil when no offer is currently outstanding.
    var pendingSwitchMeetingId: String?

    /// Switch offers the user explicitly dismissed — don't re-show for the
    /// same meeting until it drops out of the upcoming set.
    private var dismissedSwitchMeetingIds: Set<String> = []

    /// Tracks meetings for which the 1-minute HUD panel has already been shown.
    /// Separate from notifiedMeetingIds so the HUD always fires at t-1min regardless
    /// of the user's lead-time notification setting.
    private var hudShownMeetingIds: Set<String> = []

    /// Tracks meetings auto-joined by the 1-minute auto-record path so we
    /// don't try to start recording or open the meet link more than once
    /// per meeting across timer ticks.
    private var autoJoinedMeetingIds: Set<String> = []

    /// Cumulative model load attempt count across initial attempts and background retries.
    /// Hard-capped at `modelLoadHardMax` to prevent infinite retry loops on permanent failures.
    private var modelLoadTotalAttempts = 0
    private let modelLoadHardMax = 9  // 3 initial + up to 2 background retry rounds of 3
    private var loadMeetingsTask: Task<Void, Never>?

    /// Whether this instance has been fully initialized (guards against SwiftUI re-creating @State).
    private static var isInitialized = false

    init() {
        // Guard: if an AppState already exists (SwiftUI @State re-creation), reuse its services.
        // This prevents the model-loaded state from being lost when SwiftUI re-creates the App struct.
        if let existing = AppState.shared, AppState.isInitialized {
            self.database = existing.database
            self.ollamaService = existing.ollamaService
            self.embeddingService = existing.embeddingService
            self.interactiveAIBroker = existing.interactiveAIBroker
            self.ollamaInstaller = existing.ollamaInstaller
            self.meetingRepository = existing.meetingRepository
            self.transcriptRepository = existing.transcriptRepository
            self.noteRepository = existing.noteRepository
            self.summaryRepository = existing.summaryRepository
            self.enhancedNoteRepository = existing.enhancedNoteRepository
            self.taskRepository = existing.taskRepository
            self.audioCaptureService = existing.audioCaptureService
            self.transcriptionService = existing.transcriptionService
            self.appleSpeechTranscriber = existing.appleSpeechTranscriber
            self.stateMachine = existing.stateMachine
            self.taskQueueManager = existing.taskQueueManager
            self.notificationService = existing.notificationService
            self.googleAuthManager = existing.googleAuthManager
            self.calendarSyncManager = existing.calendarSyncManager

            // Copy mutable state from existing instance
            self.isRecording = existing.isRecording
            self.activeMeeting = existing.activeMeeting
            self.isLoadingModel = existing.isLoadingModel
            self.modelDownloadProgress = existing.modelDownloadProgress
            self.meetings = existing.meetings
            self.upcomingMeetings = existing.upcomingMeetings
            self.pastMeetings = existing.pastMeetings
            self.settings = existing.settings

            // Deliberately NOT reassigning AppState.shared: SwiftUI discards
            // this candidate in favour of the stored @State value, so `shared`
            // must keep pointing at the live, fully-observed original — not at
            // this observer-less copy. (This branch is now a last-resort
            // defense; MeetingManagerApp uses sharedOrCreate(), which returns
            // the existing instance without constructing a fork at all.)
            fileLog("AppState re-created by SwiftUI — reusing existing services (model loaded: \(transcriptionService.isModelLoaded))")
            return
        }

        self.database = AppDatabase.shared
        if let dbError = AppDatabase.initializationError {
            Logger.general.critical("AppState: database unavailable at launch — \(dbError)")
            self.lastUserError = "The database could not be opened (\(dbError.localizedDescription)). Your meeting data is unavailable. Please restart the app or contact support."
        }
        self.ollamaService = OllamaService()
        self.embeddingService = EmbeddingService(database: database, ollama: self.ollamaService)
        self.interactiveAIBroker = InteractiveAIBroker(ollama: self.ollamaService)
        self.ollamaInstaller = OllamaInstaller()
        self.meetingRepository = MeetingRepository(database: database)
        self.transcriptRepository = TranscriptRepository(database: database)
        self.noteRepository = NoteRepository(database: database)
        self.summaryRepository = SummaryRepository(database: database)
        self.enhancedNoteRepository = EnhancedNoteRepository(database: database)
        self.taskRepository = TaskRepository(database: database)
        self.audioCaptureService = AudioCaptureService()

        let txService = TranscriptionService()
        self.transcriptionService = txService
        self.appleSpeechTranscriber = AppleSpeechTranscriber()

        self.stateMachine = MeetingStateMachine(
            meetingRepository: meetingRepository,
            audioCaptureService: audioCaptureService
        )

        self.taskQueueManager = TaskQueueManager(database: database)
        self.notificationService = NotificationService()
        self.googleAuthManager = GoogleAuthManager()
        self.calendarSyncManager = CalendarSyncManager(
            authManager: self.googleAuthManager,
            meetingRepository: meetingRepository
        )

        // Supply the (off-by-default) microphone override to the capture
        // service. Returns nil unless the user has explicitly turned the
        // override on AND picked a device, so auto-detection stays the default.
        audioCaptureService.preferredInputDeviceIDProvider = { [weak self] in
            guard let self, self.settings.micOverrideEnabled else { return nil }
            let id = self.settings.micOverrideDeviceID
            return id.isEmpty ? nil : id
        }

        // Tells the capture service whether the user has pinned a mic, so the
        // system-default auto-follow can suppress itself when an override is set.
        audioCaptureService.isMicOverrideEnabledProvider = { [weak self] in
            self?.settings.micOverrideEnabled ?? false
        }

        // Mirror the mic-recovery state so the recording bar shows the inline red
        // "finding a mic" banner + picker (TASK-104).
        audioCaptureService.onMicRecoveryStateChanged = { [weak self] recovering in
            Task { @MainActor in self?.isMicRecovering = recovering }
        }

        // Auto-stop recording after sustained silence (meeting ended)
        audioCaptureService.onSilenceDetected = { [weak self] in
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                self.fileLog("Silence auto-stop: no audio on mic or speaker for 5 minutes — ending meeting")
                self.stopRecording()
            }
        }

        // Auto-stop recording when buffer hits max duration (prevents OOM crash)
        audioCaptureService.onCapacityReached = { [weak self] in
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                self.fileLog("Capacity auto-stop: buffer hit 2-hour limit — ending meeting to prevent crash")
                self.stopRecording()
            }
        }

        // Mic died/disconnected. Do NOT raise a modal alert — the inline red
        // recovery banner + mic picker in the recording bar (driven by
        // isMicRecovering) surfaces it calmly, and the call keeps recording via
        // system audio (TASK-104). Log for diagnostics only.
        audioCaptureService.onMicProblemDetected = { [weak self] message in
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                self.fileLog("Mic problem (shown inline via recovery banner, no modal): \(message)")
            }
        }

        // Surface missing Screen Recording permission (no system/remote audio).
        audioCaptureService.onSystemAudioUnavailable = { [weak self] message in
            Task { @MainActor in
                self?.lastUserError = message
            }
        }

        loadMeetings()
        loadSettings()
        loadCachedDailyBriefForToday()
        observeNotifications()
        startProximityCheck()
        autoLoadTranscriptionModel()
        cleanupStuckMeetings()
        setupTaskQueue()
        startPrepContextTimer()
        startCalendarSync()
        // Prime the Ollama reachability check so views that gate on
        // `ollamaService.isReachable` (DailyBriefView, ActionItemsView, etc.)
        // don't render "Set up AI →" before the first lazy refresh fires.
        Task { await self.ollamaService.refreshStatus() }
        // v3.10.4 (ADR-007): if the user is on the local-LLM path and the
        // Qwen3 ladder isn't installed, kick off a background pull. The
        // installer's existing phase machinery surfaces progress in the
        // existing Settings UI without blocking app launch. No-op when
        // both Qwen3 tier models are already present, when Ollama is
        // unreachable, or when the user is using Claude.
        Task { await self.verifyLocalModelsOnStartup() }
        // One-shot retroactive speaker attribution scan (gated by UserDefaults
        // flag — only runs once per app upgrade). Re-attributes existing
        // meetings against the loosened fuzzy matcher + auto-mic mapping
        // introduced in v3.4.1.
        runRetroactiveSpeakerAttributionIfNeeded()

        // Knowledge Base: if the user has previously chosen a folder, start
        // its FSEvents watcher and kick off a background re-index so the FTS
        // table reflects any external edits made while the app was closed.
        if let kbRoot = KnowledgeBaseService.shared.rootURL {
            kbConfigured = true
            KnowledgeBaseService.shared.startWatching(url: kbRoot)
            Task { await KnowledgeBaseService.shared.reindex() }
        }

        // v3.9 Phase 1: bootstrap Person identity records from meeting history.
        // Runs once per install in the background; subsequent runs are fast
        // because findOrCreate is a no-op for already-known canonical keys.
        Task {
            let repo = PersonRepository(database: database)
            let count = await repo.bootstrapFromMeetingHistory(db: database)
            if count > 0 {
                Logger.general.info("Person bootstrap: created \(count) new person records from meeting history")
            }
        }

        // Surface note drafts a previous session left unsaved. The per-meeting
        // recovery in NotepadPaneView.loadNote only fires when the user reopens
        // that specific meeting; this proactively lists ALL recoverable drafts
        // at launch so nothing is silently stranded. Background — never blocks
        // launch, and a no-op (empty sheet never shown) on a clean shutdown.
        Task { await self.scanForRecoverableDrafts() }

        // PRJ-013 Phase 5: reconcile per-task due alerts at launch so pending
        // notifications survive relaunch (and stale ones for now-complete tasks
        // get cleared).
        Task { await self.refreshTaskNotifications() }

        // Make this instance accessible to AppDelegate for the menu bar popover
        AppState.shared = self
        AppState.isInitialized = true

        fileLog("AppState initialized — starting model download")
    }

    // MARK: - Note Draft Recovery

    /// Scans sidecar note drafts at launch and populates `recoverableDrafts`
    /// with those whose content diverged from the stored note. Orphaned
    /// sidecars (the meeting no longer exists) are cleared and skipped so they
    /// don't re-surface on every launch. See `NoteDraftStore` and
    /// `NotepadPaneView.loadNote` for the per-meeting recovery path.
    private func scanForRecoverableDrafts() async {
        let drafts = await NoteDraftStore.recoverableDrafts(noteRepo: noteRepository)
        guard !drafts.isEmpty else { return }

        var resolved: [RecoverableDraft] = []
        for draft in drafts {
            guard let meeting = try? await meetingRepository.find(id: draft.meetingId) else {
                NoteDraftStore.clearDraft(meetingId: draft.meetingId)
                continue
            }
            resolved.append(RecoverableDraft(
                meetingId: draft.meetingId,
                meetingTitle: meeting.title,
                content: draft.content,
                modifiedAt: draft.modifiedAt
            ))
        }
        recoverableDrafts = resolved
    }

    /// Writes a recovered draft into the meeting's note and clears the sidecar.
    /// Mirrors `NotepadPaneView.saveNote`: update the latest note in place when
    /// one exists, otherwise insert a new note row.
    func restoreDraft(_ draft: RecoverableDraft) async {
        do {
            if var note = try await noteRepository.latestNote(meetingId: draft.meetingId) {
                note.content = draft.content
                try await noteRepository.save(&note)
            } else {
                var note = MeetingNote(meetingId: draft.meetingId, content: draft.content)
                try await noteRepository.save(&note)
            }
            NoteDraftStore.clearDraft(meetingId: draft.meetingId)
            recoverableDrafts.removeAll { $0.meetingId == draft.meetingId }
        } catch {
            Logger.database.error("restoreDraft: failed for \(draft.meetingId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            lastUserError = "Couldn't restore the note draft: \(error.localizedDescription)"
        }
    }

    /// Discards a recovered draft: deletes the sidecar and drops it from the
    /// list. The stored note is left untouched.
    func discardDraft(_ draft: RecoverableDraft) {
        NoteDraftStore.clearDraft(meetingId: draft.meetingId)
        recoverableDrafts.removeAll { $0.meetingId == draft.meetingId }
    }

    // MARK: - Settings

    func loadSettings() {
        Task {
            do {
                let loaded = try await database.writer.read { db in
                    try AppSettings.fetchOne(db)
                }
                if let loaded = loaded {
                    await MainActor.run { self.settings = loaded }
                }
            } catch {
                Logger.database.error("Failed to load settings: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func persistSettings() {
        let current = settings
        Task {
            do {
                try await database.writer.write { db in
                    if try AppSettings.fetchOne(db) != nil {
                        try current.update(db)
                    } else {
                        var s = current
                        try s.insert(db)
                    }
                }
            } catch {
                Logger.database.error("Failed to persist settings: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// TASK-047: one schema-constrained call turns the fresh summary into
    /// entity facts (decisions/commitments/questions/status) fanned out to
    /// person, company, and series dossiers. Replace-mode per meeting so
    /// regeneration can't duplicate. Best-effort — never fails the task.
    private func extractInsightsBestEffort(meetingId: String) async {
        do {
            guard let meeting = try await meetingRepository.find(id: meetingId) else { return }
            guard let summary = try await summaryRepository.latestSummary(meetingId: meetingId),
                  !summary.summaryText.isEmpty else { return }
            guard let textGen = await makeTextGenerator(
                maxOutputTokens: 2048,
                schemaJSON: InsightExtraction.schemaJSON
            ) else { return }
            let response = try await textGen(
                InsightExtraction.systemPrompt,
                "Meeting: \(meeting.title)\nParticipants: \(meeting.participantList.joined(separator: ", "))\n\nSummary:\n\(summary.summaryText)"
            )
            guard let payload = InsightExtraction.parse(response) else {
                fileLog("Insights: unparseable extraction for \(meetingId) — skipping")
                return
            }
            let personRepo = PersonRepository(database: AppDatabase.shared)
            var domains: [String] = []
            for name in meeting.participantList {
                if let person = try? await personRepo.find(for: name), let d = person.domain {
                    domains.append(d)
                }
            }
            let facts = InsightExtraction.facts(from: payload, meeting: meeting, participantDomains: domains)
            // TASK-066: anchor commitments/decisions to their transcript
            // moment. One BM25 lookup per unique text; misses just ship
            // without a receipt.
            var anchors: [String: (transcriptId: Int64, startTime: Double)] = [:]
            let anchorable = Set(facts.filter { ["commitment", "decision", "objection"].contains($0.kind) }.map(\.text))
            for text in anchorable {
                if let hit = try? await transcriptRepository.bestAnchor(meetingId: meetingId, factText: text) {
                    anchors[text] = hit
                }
            }
            let anchored = InsightExtraction.applyAnchors(facts, anchors: anchors)
            try await EntityFactRepository(database: database).replaceForMeeting(meetingId, with: anchored)
            fileLog("Insights: \(anchored.count) fact(s) for \(meetingId), \(anchors.count) anchored")
        } catch {
            fileLog("Insights: extraction failed (best-effort) — \(error.localizedDescription)")
        }
    }

    /// TASK-065: score the user's pre-meeting intent against the summary —
    /// "did you get what you came for", one small schema call, neutral
    /// note. Best-effort inside the summary handler; re-scores on
    /// regeneration (the summary changed, the verdict may too).
    private func scoreIntentBestEffort(meetingId: String) async {
        do {
            let repo = MeetingIntentRepository(database: database)
            guard let intent = try await repo.find(meetingId: meetingId) else { return }
            guard let summary = try await summaryRepository.latestSummary(meetingId: meetingId),
                  !summary.summaryText.isEmpty else { return }
            guard let textGen = await makeTextGenerator(
                maxOutputTokens: 256,
                schemaJSON: IntentScoring.schemaJSON,
                activityLabel: "Scoring meeting intent"
            ) else { return }
            let response = try await textGen(
                IntentScoring.systemPrompt,
                IntentScoring.userPrompt(intent: intent.intent, summary: summary.summaryText))
            guard let payload = IntentScoring.parse(response) else {
                fileLog("Intent: unparseable score for \(meetingId) — skipping")
                return
            }
            var updated = intent
            updated.outcomeScore = payload.score
            updated.outcomeNote = payload.note.trimmingCharacters(in: .whitespacesAndNewlines)
            updated.scoredAt = Date()
            try await repo.save(updated)
            fileLog("Intent: \(meetingId) scored '\(payload.score)'")
        } catch {
            fileLog("Intent: scoring failed (best-effort) — \(error.localizedDescription)")
        }
    }

    /// TASK-049: merge the new session into the series' running thread.
    /// Only runs for meetings that belong to a folder (2+ instances).
    private func updateSeriesThreadBestEffort(meetingId: String) async {
        do {
            guard let meeting = try await meetingRepository.find(id: meetingId) else { return }
            let folderKey = MeetingFolder.normaliseTitle(meeting.title)
            let siblings = try await meetingRepository.allActiveMeetings()
                .filter { MeetingFolder.normaliseTitle($0.title) == folderKey }
            guard siblings.count >= 2 else { return }
            guard let summary = try await summaryRepository.latestSummary(meetingId: meetingId),
                  !summary.summaryText.isEmpty else { return }

            let repo = SeriesThreadRepository(database: database)
            let prior = try await repo.thread(folderKey: folderKey)?.content ?? "(no prior thread — this is the first one)"
            let facts = (try? await EntityFactRepository(database: database)
                .facts(entityType: "series", entityKey: folderKey, limit: 20)) ?? []
            let factsBlock = facts.map { "- [\($0.kind)] \($0.text)" }.joined(separator: "\n")

            guard let textGen = await makeTextGenerator(maxOutputTokens: 1500) else { return }
            let updated = try await textGen(
                SeriesThreadPrompts.system,
                "Previous thread:\n\(prior)\n\nNew session (\(meeting.effectiveDate.formatted(date: .abbreviated, time: .omitted))):\n\(summary.summaryText.prefix(4000))\n\nRecent facts:\n\(factsBlock)"
            )
            guard !updated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            try await repo.save(SeriesThread(folderKey: folderKey, content: updated, updatedAt: Date()))
            fileLog("SeriesThread: updated '\(folderKey)'")
        } catch {
            fileLog("SeriesThread: update failed (best-effort) — \(error.localizedDescription)")
        }
    }

    static let weeklyDigestSentinel = "__weekly_digest__"

    /// TASK-051: enqueue last week's digest once per ISO week. Launch +
    /// hourly catch-up semantics — there is no fixed Monday scheduler, so
    /// a Mac asleep over the weekend writes the digest on first wake.
    private func enqueueWeeklyDigestIfDue() {
        Task { [weak self] in
            guard let self else { return }
            let range = WeeklyDigest.previousWeekRange()
            let repo = WeeklyDigestRepository(database: self.database)
            if (try? await repo.digest(isoWeek: range.isoWeek)) != nil { return }
            let queued = self.taskQueueManager.allTasks.contains {
                $0.type == .weeklyDigest && !$0.isTerminal
            }
            guard !queued, self.isAIWorkConfigured else { return }
            // Only digest weeks that had meetings.
            let hadMeetings = ((try? await self.meetingRepository.allActiveMeetings()) ?? [])
                .contains { $0.effectiveDate >= range.start && $0.effectiveDate < range.end }
            guard hadMeetings else { return }
            await self.taskQueueManager.enqueue(type: .weeklyDigest,
                                                meetingId: Self.weeklyDigestSentinel, priority: 9)
        }
    }

    /// Build the digest from STRUCTURED data (meetings, facts, open items)
    /// — one LLM call over aggregates, never raw transcripts.
    private func generateWeeklyDigest() async throws {
        let range = WeeklyDigest.previousWeekRange()
        let allHistory = (try? await meetingRepository.allActiveMeetings()) ?? []
        let meetings = allHistory
            .filter { $0.effectiveDate >= range.start && $0.effectiveDate < range.end }
        guard !meetings.isEmpty else { return }
        let ids = meetings.map(\.id)
        let facts = (try? await EntityFactRepository(database: database)
            .factsForMeetings(ids)) ?? []
        let openItems = (try? await TaskRepository(database: database).allOpenItems(limit: 50)) ?? []

        var data: [String] = []
        data.append("Meetings (\(meetings.count)):")
        for m in meetings {
            data.append("- \(m.title) — \(m.effectiveDate.formatted(date: .abbreviated, time: .omitted)) — \(m.participantList.joined(separator: ", "))")
        }
        let seriesFacts = facts.filter { $0.entityType == "series" }
        if !seriesFacts.isEmpty {
            data.append("\nFacts:")
            for f in seriesFacts.prefix(40) {
                data.append("- [\(f.kind)]\(f.owner.map { " (\($0))" } ?? "") \(f.text)")
            }
        }
        if !openItems.isEmpty {
            data.append("\nOpen action items:")
            for i in openItems.prefix(25) {
                data.append("- \(i.title)\(i.assignee.map { " — \($0)" } ?? "")\(i.dueDate.map { " (due \($0.formatted(date: .abbreviated, time: .omitted)))" } ?? "")")
            }
        }

        guard let textGen = await makeTextGenerator(maxOutputTokens: 1200) else { return }
        var content = try await textGen(WeeklyDigest.systemPrompt,
                                        "Week \(range.isoWeek):\n\n" + data.joined(separator: "\n"))
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        // TASK-056: deterministic appendix — never LLM-generated, so a
        // reversal is only reported when a factLink row actually exists.
        let conflicts = (try? await FactLinkRepository(database: database)
            .conflictDescriptors(from: range.start, to: range.end)) ?? []
        if !conflicts.isEmpty {
            let lines = conflicts.prefix(6).map { d in
                "- \(d.relation == "supersedes" ? "Updated" : "Conflict"): \"\(d.toText)\" → \"\(d.fromText)\""
            }
            content += "\n\n## Reversals & conflicts\n" + lines.joined(separator: "\n")
        }

        // TASK-061: deterministic relationship signals. Quiet/cadence only —
        // they need nothing but meeting dates; the person/company pages
        // carry the full signal set including aging items.
        var datesByKey: [String: (name: String, dates: [Date])] = [:]
        for m in allHistory {
            for p in m.participantList {
                let key = VocativeMiningService.canonicalKey(for: p)
                guard !key.isEmpty else { continue }
                datesByKey[key, default: (p, [])].dates.append(m.effectiveDate)
            }
        }
        let signalLines: [String] = datesByKey.values.compactMap { entry in
            guard entry.dates.count >= RelationshipHealth.minMeetingsForCadence else { return nil }
            let signal = RelationshipHealth.signals(meetingDates: entry.dates, openItems: [])
                .first { $0.kind == .staleContact || $0.kind == .cadenceDrop }
            return signal.map { "- \(entry.name): \($0.detail)" }
        }.sorted()
        if !signalLines.isEmpty {
            content += "\n\n## Relationship signals\n" + signalLines.prefix(4).joined(separator: "\n")
        }

        // TASK-065: deterministic meeting-ROI appendix — counts from rows,
        // never the LLM. Neutral "did you get what you came for" framing.
        let weekIds = meetings.map(\.id)
        let weekIntents = (try? await MeetingIntentRepository(database: database)
            .intents(meetingIds: weekIds)) ?? []
        let weekDecisions = (try? await EntityFactRepository(database: database)
            .factsForMeetings(weekIds, kinds: ["decision"])) ?? []
        let roi = MeetingROI.folderStats(meetings: meetings, decisionFacts: weekDecisions, intents: weekIntents)
        if roi.decisionCount > 0 || roi.intentsSet > 0 {
            var roiLines: [String] = []
            let perHour = roi.decisionsPerHour.map { String(format: " (%.1f/hour)", $0) } ?? ""
            roiLines.append("- \(meetings.count) meetings, \(String(format: "%.1f", roi.totalHours)) recorded hours, \(roi.decisionCount) unique decision\(roi.decisionCount == 1 ? "" : "s")\(perHour).")
            if roi.intentsSet > 0 {
                let partly = roi.intentsPartial > 0 ? ", \(roi.intentsPartial) partly" : ""
                roiLines.append("- You set an intent for \(roi.intentsSet) meeting\(roi.intentsSet == 1 ? "" : "s") and got what you came for in \(roi.intentsMet)\(partly).")
            }
            content += "\n\n## Meeting ROI\n" + roiLines.joined(separator: "\n")
        }

        // TASK-081: tracked-topic counts for the week (deterministic, only
        // when there were hits).
        let trackerRepo = TopicTrackerRepository(database: database)
        let activeTrackers = (try? await trackerRepo.activeTrackers()) ?? []
        if !activeTrackers.isEmpty {
            var topicLines: [String] = []
            for tracker in activeTrackers {
                guard let tid = tracker.id else { continue }
                let n = (try? await trackerRepo.recentHitCount(trackerId: tid, since: range.start)) ?? 0
                if n > 0 { topicLines.append("- \(tracker.name): came up in \(n) meeting\(n == 1 ? "" : "s") this week.") }
            }
            if !topicLines.isEmpty {
                content += "\n\n## Tracked topics\n" + topicLines.joined(separator: "\n")
            }
        }

        try await WeeklyDigestRepository(database: database).save(
            WeeklyDigestRecord(isoWeek: range.isoWeek, content: content, createdAt: Date()))
        fileLog("WeeklyDigest: wrote \(range.isoWeek)")

        // KB write-back when configured — same folder discipline as meetings.
        if settings.kbWriteBack, let root = KnowledgeBaseService.shared.rootURL {
            let dir = root.appendingPathComponent("Weekly Digests", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("\(range.isoWeek).md")
            try? content.write(to: url, atomically: true, encoding: .utf8)
            await KnowledgeBaseService.shared.reindexFile(url: url)
        }
    }

    static let gardenerSentinel = "__gardener__"

    /// TASK-056: enqueue the knowledge gardener once per calendar day.
    /// "Nightly" in practice means "daily, when quiet" — the row is
    /// background-class, so the governor holds it through recordings,
    /// upcoming meetings, battery, and interactive AI waits.
    private func enqueueGardenerIfDue() {
        let dayStamp = Self.dayStamp(Date())
        guard UserDefaults.standard.string(forKey: "gardener.lastRunDay") != dayStamp else { return }
        let queued = taskQueueManager.allTasks.contains { $0.type == .gardener && !$0.isTerminal }
        guard !queued else { return }
        Task { [weak self] in
            guard let self else { return }
            // Configuration checks go AFTER the refresh — at launch both
            // isAIWorkConfigured and isAvailable read the stale pre-probe
            // Ollama status and silently skipped until the hourly net.
            await self.ollamaService.refreshStatus()
            guard self.isAIWorkConfigured, self.embeddingService.isAvailable else { return }
            await self.taskQueueManager.enqueue(type: .gardener,
                                                meetingId: Self.gardenerSentinel, priority: 9)
        }
    }

    static func dayStamp(_ date: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")
        return df.string(from: date)
    }

    /// The gardener run: transient fact embeddings + one schema-constrained
    /// classification call, then links + soft-hides (GardenerService).
    private func runGardener() async throws {
        guard embeddingService.isAvailable else {
            fileLog("Gardener: embedding model unavailable — skipping")
            return
        }
        guard let textGen = await makeTextGenerator(
            maxOutputTokens: 1024,
            schemaJSON: GardenerService.classifySchemaJSON
        ) else {
            fileLog("Gardener: no AI backend — skipping")
            return
        }
        try await GardenerService.run(
            database: database,
            embed: { try await self.embeddingService.embed(texts: $0) },
            textGenerator: textGen,
            log: { self.fileLog($0) }
        )
        // Stamp only after a completed pass — a failed run retries via the
        // queue and, past max retries, again on the next day's enqueue.
        UserDefaults.standard.set(Self.dayStamp(Date()), forKey: "gardener.lastRunDay")
    }

    static let glossarySentinel = "__glossary__"

    /// TASK-064: enqueue the glossary miner once per calendar day, same
    /// cadence and gates as the gardener.
    private func enqueueGlossaryIfDue() {
        let dayStamp = Self.dayStamp(Date())
        guard UserDefaults.standard.string(forKey: "glossary.lastRunDay") != dayStamp else { return }
        let queued = taskQueueManager.allTasks.contains { $0.type == .glossary && !$0.isTerminal }
        guard !queued else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.ollamaService.refreshStatus()
            guard self.isAIWorkConfigured else { return }
            await self.taskQueueManager.enqueue(type: .glossary,
                                                meetingId: Self.glossarySentinel, priority: 9)
        }
    }

    private func runGlossaryMiner() async throws {
        guard let textGen = await makeTextGenerator(
            maxOutputTokens: 1024,
            schemaJSON: GlossaryMiner.defineSchemaJSON
        ) else {
            fileLog("Glossary: no AI backend — skipping")
            return
        }
        let repo = GlossaryRepository(database: database)
        let excluded = (try? await repo.allTermStrings()) ?? []

        // Recent-60-meeting window keeps the mine bounded; older meetings'
        // jargon resurfaces as soon as it's used again.
        let recent = ((try? await meetingRepository.allActiveMeetings()) ?? [])
            .sorted { $0.effectiveDate > $1.effectiveDate }
            .prefix(60)
        var transcriptsByMeeting: [String: String] = [:]
        for meeting in recent {
            if Task.isCancelled { return }
            if let text = try? await transcriptRepository.fullText(meetingId: meeting.id), !text.isEmpty {
                transcriptsByMeeting[meeting.id] = text
            }
        }
        guard transcriptsByMeeting.count >= GlossaryMiner.meetingFloor else {
            fileLog("Glossary: only \(transcriptsByMeeting.count) transcript(s) — below the floor, skipping")
            return
        }

        let dictionary = Self.systemDictionary()
        let candidates = GlossaryMiner.candidates(
            transcriptsByMeeting: transcriptsByMeeting,
            dictionary: dictionary,
            excluded: excluded)
        guard !candidates.isEmpty else {
            fileLog("Glossary: no new candidate terms tonight")
            UserDefaults.standard.set(Self.dayStamp(Date()), forKey: "glossary.lastRunDay")
            return
        }

        let response = try await textGen(
            GlossaryMiner.defineSystemPrompt,
            GlossaryMiner.defineUserPrompt(candidates: candidates))
        guard let payload = GlossaryMiner.parseDefinitions(response) else {
            fileLog("Glossary: unparseable definitions — aborting run")
            return
        }
        let byTerm = Dictionary(uniqueKeysWithValues: candidates.map { ($0.term, $0) })
        var saved = 0
        for entry in payload.definitions {
            let definition = entry.definition.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let candidate = byTerm[entry.term],
                  !definition.isEmpty,
                  definition.lowercased() != "unknown" else { continue }
            try await repo.save(GlossaryTerm(
                term: candidate.term,
                definition: definition,
                exampleMeetingId: candidate.exampleMeetingId,
                hiddenAt: nil,
                updatedAt: Date()))
            saved += 1
        }
        fileLog("Glossary: \(candidates.count) candidate(s), \(saved) defined")

        // KB write-back — same folder discipline as the weekly digest.
        if settings.kbWriteBack, let root = KnowledgeBaseService.shared.rootURL,
           let visible = try? await repo.visibleTerms(), !visible.isEmpty {
            let url = root.appendingPathComponent("Glossary.md")
            try? GlossaryMiner.markdown(terms: visible).write(to: url, atomically: true, encoding: .utf8)
            await KnowledgeBaseService.shared.reindexFile(url: url)
        }
        UserDefaults.standard.set(Self.dayStamp(Date()), forKey: "glossary.lastRunDay")
    }

    /// Lowercased /usr/share/dict/words — the "not jargon" filter.
    /// Loaded per run (the run is nightly; no point caching 2 MB).
    nonisolated static func systemDictionary() -> Set<String> {
        guard let content = try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8) else {
            return []
        }
        return Set(content.components(separatedBy: .newlines).map { $0.lowercased() })
    }

    static let speechStatsSentinel = "__speech_stats__"
    static let speechStatsDoneKey = "speechStats.processedMeetingIds"

    /// TASK-059: per-meeting speaking metrics — pure math, no LLM. Runs
    /// in the summary chain for new meetings; this is the history batch.
    private func enqueueSpeechStatsBackfillIfNeeded() async {
        let queued = taskQueueManager.allTasks.contains { $0.type == .speechStats && !$0.isTerminal }
        guard !queued else { return }
        let done = Set(UserDefaults.standard.stringArray(forKey: Self.speechStatsDoneKey) ?? [])
        let pending = ((try? await SpeechStatsRepository(database: database).unprocessedMeetingIds()) ?? [])
            .filter { !done.contains($0) }
        guard !pending.isEmpty else { return }
        fileLog("SpeechStats: \(pending.count) meeting(s) lack speaking stats — enqueueing backfill")
        await taskQueueManager.enqueue(type: .speechStats, meetingId: Self.speechStatsSentinel, priority: 9)
    }

    private func runSpeechStatsBackfill() async {
        let repo = SpeechStatsRepository(database: database)
        var done = Set(UserDefaults.standard.stringArray(forKey: Self.speechStatsDoneKey) ?? [])
        let pending = ((try? await repo.unprocessedMeetingIds()) ?? []).filter { !done.contains($0) }
        guard !pending.isEmpty else { return }
        let selfName = ProcessInfo.processInfo.fullUserName
        var processed = 0
        for meetingId in pending {
            if Task.isCancelled { break }
            let rows = (try? await transcriptRepository.transcriptsForMeeting(meetingId, limit: 5000)) ?? []
            if let stats = SpeechStatsBuilder.build(meetingId: meetingId, transcripts: rows, selfName: selfName) {
                try? await repo.save(stats)
            }
            done.insert(meetingId)
            processed += 1
            if processed.isMultiple(of: 20) {
                UserDefaults.standard.set(Array(done), forKey: Self.speechStatsDoneKey)
                taskQueueManager.reportCurrentProgress(stage: "Computing speaking stats (\(processed)/\(pending.count))")
            }
        }
        UserDefaults.standard.set(Array(done), forKey: Self.speechStatsDoneKey)
        fileLog("SpeechStats: processed \(processed)/\(pending.count) meeting(s)")
    }

    private func computeSpeechStatsBestEffort(meetingId: String) async {
        let rows = (try? await transcriptRepository.transcriptsForMeeting(meetingId, limit: 5000)) ?? []
        guard let stats = SpeechStatsBuilder.build(
            meetingId: meetingId, transcripts: rows,
            selfName: ProcessInfo.processInfo.fullUserName) else { return }
        try? await SpeechStatsRepository(database: database).save(stats)
    }

    static let topicBackfillSentinel = "__topic_backfill__"

    /// TASK-081: match all active topic trackers against one meeting's
    /// transcript (one hit per tracker per meeting). Inline in the summary
    /// chain so new meetings populate immediately. Pure keyword match.
    private func matchTopicTrackersBestEffort(meetingId: String) async {
        let repo = TopicTrackerRepository(database: database)
        let trackers = (try? await repo.activeTrackers()) ?? []
        guard !trackers.isEmpty else { return }
        let segs = (try? await transcriptRepository.transcriptsForMeeting(meetingId, limit: 5000)) ?? []
        guard !segs.isEmpty else { return }
        for tracker in trackers {
            guard let tid = tracker.id else { continue }
            if (try? await repo.hasHit(trackerId: tid, meetingId: meetingId)) == true { continue }
            if let m = TopicMatcher.firstMatch(keywords: tracker.keywordList, in: segs) {
                try? await repo.saveHit(TopicTrackerHit(
                    id: nil, trackerId: tid, meetingId: meetingId,
                    atSeconds: m.atSeconds, snippet: m.snippet,
                    matchType: "keyword", createdAt: Date()))
            }
        }
    }

    /// Scan history for active trackers (triggered on tracker create/edit).
    func enqueueTopicBackfill() async {
        // If a pass is already running it snapshotted the trackers before this
        // topic existed (REQ-2). Don't drop the request — flag a rerun so the
        // running pass re-enqueues itself on completion and the new topic is
        // scanned, instead of sitting at a stale "0 meetings". A *pending* pass
        // hasn't snapshotted yet, so the queue's own dedup correctly folds this
        // into it.
        let running = taskQueueManager.allTasks.contains { $0.type == .topicBackfill && $0.status == .running }
        if running {
            topicBackfillRerunRequested = true
            return
        }
        await taskQueueManager.enqueue(type: .topicBackfill, meetingId: Self.topicBackfillSentinel, priority: 9)
    }

    private func runTopicBackfill() async {
        // REQ-2: a topic added *while this run is in flight* missed the snapshot
        // each pass takes. Rather than enqueue a fresh task (the queue would see
        // this one still `.running` and dedup it away), loop here: clear the flag
        // before a pass, and if `enqueueTopicBackfill` set it again during the
        // pass, scan once more. Each pass re-reads activeTrackers() so the new
        // topic is included. The completion token bumps once, at the very end.
        repeat {
            topicBackfillRerunRequested = false
            await runTopicBackfillPass()
            if Task.isCancelled { break }
        } while topicBackfillRerunRequested

        topicBackfillToken &+= 1   // TASK-094: signal TopicTrackersView to refresh counts/hits
    }

    private func runTopicBackfillPass() async {
        let repo = TopicTrackerRepository(database: database)
        let trackers = (try? await repo.activeTrackers()) ?? []
        guard !trackers.isEmpty else { return }
        let meetings = (try? await meetingRepository.allActiveMeetings()) ?? []
        var processed = 0
        for meeting in meetings {
            if Task.isCancelled { break }
            let segs = (try? await transcriptRepository.transcriptsForMeeting(meeting.id, limit: 5000)) ?? []
            guard !segs.isEmpty else { continue }
            for tracker in trackers {
                guard let tid = tracker.id else { continue }
                if (try? await repo.hasHit(trackerId: tid, meetingId: meeting.id)) == true { continue }
                if let m = TopicMatcher.firstMatch(keywords: tracker.keywordList, in: segs) {
                    try? await repo.saveHit(TopicTrackerHit(
                        id: nil, trackerId: tid, meetingId: meeting.id,
                        atSeconds: m.atSeconds, snippet: m.snippet,
                        matchType: "keyword", createdAt: Date()))
                }
            }
            processed += 1
            if processed.isMultiple(of: 20) {
                taskQueueManager.reportCurrentProgress(stage: "Scanning topics (\(processed)/\(meetings.count))")
            }
        }
        fileLog("TopicTrackers: scanned \(processed) meeting(s) for \(trackers.count) tracker(s)")
    }

    // MARK: - Knowledge Base Backfill (TASK-115 / PRJ-016)

    /// Progress of the one-time "Export existing meetings to Knowledge Base"
    /// backfill, surfaced inline in KB Settings. nil when not running.
    var kbBackfillProgress: (done: Int, total: Int)?

    /// Result line shown after the backfill finishes (until another run starts).
    /// nil when it hasn't run this launch.
    var kbBackfillResult: String?

    /// In-flight guard. A disabled button alone doesn't survive a Settings view
    /// rebuild, so reentrancy is gated here rather than on view state.
    private var kbBackfillTask: Task<Void, Never>?

    /// Export every summarized meeting to the Knowledge Base. Forward-only
    /// write-back (`summaryCompletedHandler`) only writes meetings summarized
    /// after the toggle was turned on, so the back-catalogue was never exported.
    /// File-only work (no AI, no network) → a tracked standalone Task with its
    /// own progress, NOT the TaskQueue. Idempotent: `writeMeeting` overwrites its
    /// own prior output and writes a dated addendum for any note the user
    /// hand-edited, so re-running is safe.
    func startKnowledgeBaseBackfill() {
        guard kbBackfillTask == nil else { return }
        guard KnowledgeBaseService.shared.rootURL != nil else { return }
        kbBackfillResult = nil
        kbBackfillTask = Task { [weak self] in
            await self?.runKnowledgeBaseBackfill()
            self?.kbBackfillTask = nil
        }
    }

    private func runKnowledgeBaseBackfill() async {
        let meetings = (try? await meetingRepository.allWithSummaries()) ?? []
        guard !meetings.isEmpty else {
            kbBackfillResult = "No meetings with a summary to export."
            return
        }
        // Meetings already in kbExport before this run, so the completion line
        // can honestly split "newly exported" from "already up to date" without
        // trusting writeMeeting's (Void) return.
        let priorExportIds: Set<String> = (try? await database.writer.read { db in
            try String.fetchSet(db, sql: "SELECT meetingId FROM kbExport")
        }) ?? []

        kbBackfillProgress = (0, meetings.count)
        var newlyExported = 0
        var alreadyCurrent = 0
        for (index, meeting) in meetings.enumerated() {
            if Task.isCancelled { break }
            // allWithSummaries guarantees a summary row exists; skip the rare
            // empty/raced one rather than writing a blank-summary note.
            guard let summary = try? await summaryRepository.latestSummary(meetingId: meeting.id),
                  !summary.summaryText.isEmpty else {
                kbBackfillProgress = (index + 1, meetings.count)
                continue
            }
            let segments = (try? await transcriptRepository.transcriptsForMeeting(meeting.id, limit: 5000)) ?? []
            await KBWriteBackService.shared.writeMeeting(
                meeting,
                summary: summary.summaryText,
                transcript: segments
            )
            if priorExportIds.contains(meeting.id) { alreadyCurrent += 1 } else { newlyExported += 1 }
            kbBackfillProgress = (index + 1, meetings.count)
        }
        let stopped = Task.isCancelled
        kbBackfillProgress = nil
        kbBackfillResult = stopped
            ? "Export stopped. \(newlyExported) newly exported, \(alreadyCurrent) already up to date."
            : "Exported \(newlyExported) meeting(s) to your Knowledge Base. \(alreadyCurrent) were already up to date."
        fileLog("KB backfill: \(newlyExported) new, \(alreadyCurrent) already current, stopped=\(stopped)")
    }

    /// Run the audio retention sweep immediately — called when the user confirms
    /// a shorter window in Settings, so space is reclaimed without waiting for a
    /// relaunch. Drops a stale player for any just-pruned meeting that's open.
    /// Returns bytes freed for the confirmation. No-op at 0 (Forever).
    @discardableResult
    func runAudioRetentionSweepNow() async -> Int64 {
        let days = settings.audioRetentionDays
        guard days > 0 else { return 0 }
        let result = await AudioRetention.sweep(database: database, retentionDays: days)
        if let loaded = audioPlayback.loadedMeetingId, result.prunedMeetingIds.contains(loaded) {
            audioPlayback.unload()
        }
        loadMeetings()
        return result.bytes
    }

    static let sentimentBackfillSentinel = "__sentiment_backfill__"
    static let sentimentBackfillDoneKey = "sentiment.processedMeetingIds"

    /// TASK-079: coarse, neutral lexicon sentiment per meeting + speaker.
    /// Pure/instant — runs inline in the summary chain. Honors the
    /// `sentiment.enabled` toggle (default on).
    private func computeSentimentBestEffort(meetingId: String) async {
        guard UserDefaults.standard.object(forKey: "sentiment.enabled") as? Bool ?? true else { return }
        let rows = (try? await transcriptRepository.transcriptsForMeeting(meetingId, limit: 5000)) ?? []
        let spoken = rows.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        guard spoken.count >= 2 else { return }
        let now = Date()

        // Per-speaker (grouped by canonical key; skip system channel).
        var sentimentRows: [MeetingSentiment] = []
        var speakerPolarities: [Double] = []
        let groups = Dictionary(grouping: spoken) { seg -> String in
            VocativeMiningService.canonicalKey(for: seg.speakerLabel ?? "")
        }
        for (key, segs) in groups where !key.isEmpty && key != "system" {
            let text = segs.map(\.text).joined(separator: " ")
            let s = SentimentLexicon.score(text)
            speakerPolarities.append(s.polarity)
            sentimentRows.append(MeetingSentiment(
                id: nil, meetingId: meetingId, scope: "speaker", speakerKey: key,
                label: s.label, polarity: s.polarity, magnitude: s.magnitude,
                method: "lexicon", note: nil, computedAt: now))
        }

        // Meeting-level over all spoken text, with divergence → "mixed".
        let overall = SentimentLexicon.score(spoken.map(\.text).joined(separator: " "))
        let meetingLabel = SentimentLexicon.meetingLabel(speakerPolarities: speakerPolarities, overall: overall.label)
        sentimentRows.append(MeetingSentiment(
            id: nil, meetingId: meetingId, scope: "meeting", speakerKey: nil,
            label: meetingLabel, polarity: overall.polarity, magnitude: overall.magnitude,
            method: "lexicon", note: nil, computedAt: now))

        try? await SentimentRepository(database: database).replaceForMeeting(meetingId, with: sentimentRows)
    }

    private func enqueueSentimentBackfillIfNeeded() async {
        guard UserDefaults.standard.object(forKey: "sentiment.enabled") as? Bool ?? true else { return }
        let queued = taskQueueManager.allTasks.contains { $0.type == .sentimentBackfill && !$0.isTerminal }
        guard !queued else { return }
        let done = Set(UserDefaults.standard.stringArray(forKey: Self.sentimentBackfillDoneKey) ?? [])
        let pending = ((try? await SentimentRepository(database: database).unprocessedMeetingIds()) ?? [])
            .filter { !done.contains($0) }
        guard !pending.isEmpty else { return }
        fileLog("Sentiment: \(pending.count) meeting(s) lack a tone read — enqueueing backfill")
        await taskQueueManager.enqueue(type: .sentimentBackfill, meetingId: Self.sentimentBackfillSentinel, priority: 9)
    }

    private func runSentimentBackfill() async {
        var done = Set(UserDefaults.standard.stringArray(forKey: Self.sentimentBackfillDoneKey) ?? [])
        let pending = ((try? await SentimentRepository(database: database).unprocessedMeetingIds()) ?? [])
            .filter { !done.contains($0) }
        guard !pending.isEmpty else { return }
        var processed = 0
        for meetingId in pending {
            if Task.isCancelled { break }
            await computeSentimentBestEffort(meetingId: meetingId)
            done.insert(meetingId)
            processed += 1
            if processed.isMultiple(of: 25) {
                UserDefaults.standard.set(Array(done), forKey: Self.sentimentBackfillDoneKey)
                taskQueueManager.reportCurrentProgress(stage: "Reading tone (\(processed)/\(pending.count))")
            }
        }
        UserDefaults.standard.set(Array(done), forKey: Self.sentimentBackfillDoneKey)
        fileLog("Sentiment: processed \(processed)/\(pending.count) meeting(s)")
    }

    static let embedBackfillSentinel = "__embed_backfill__"

    /// TASK-045: semantic-index one meeting, or — for the backfill
    /// sentinel — every meeting that has transcripts but no embeddings.
    /// One sentinel row drains the whole backlog through the serial queue
    /// (cancellable, progress-reported) instead of polluting the Tasks UI
    /// with hundreds of rows.
    private func runEmbedIndex(meetingId: String) async throws {
        guard embeddingService.isAvailable else {
            fileLog("EmbedIndex: embedding model unavailable — skipping (degrades to FTS)")
            return
        }
        if meetingId == Self.embedBackfillSentinel {
            let all = try await meetingRepository.allActiveMeetings()
            var done = 0
            for meeting in all {
                if Task.isCancelled { return }
                let repo = EmbeddingRepository(database: database)
                if (try? await repo.hasEmbeddings(meetingId: meeting.id)) == true { continue }
                let rows = (try? await transcriptRepository.transcriptsForMeeting(meeting.id, limit: 5000)) ?? []
                guard !rows.isEmpty else { continue }
                let summary = try? await summaryRepository.latestSummary(meetingId: meeting.id)
                let slides = ((try? await MeetingSlideRepository(database: database).slides(meetingId: meeting.id)) ?? []).map(\.text)
                try? await embeddingService.indexMeeting(meeting.id, transcripts: rows, summaryText: summary?.summaryText, slideTexts: slides)
                done += 1
                taskQueueManager.reportCurrentProgress(stage: "Indexing history (\(done))")
            }
            fileLog("EmbedIndex backfill: indexed \(done) meeting(s)")
            return
        }
        let rows = try await transcriptRepository.transcriptsForMeeting(meetingId, limit: 5000)
        guard !rows.isEmpty else { return }
        let summary = try? await summaryRepository.latestSummary(meetingId: meetingId)
        let slides = ((try? await MeetingSlideRepository(database: database).slides(meetingId: meetingId)) ?? []).map(\.text)
        try await embeddingService.indexMeeting(meetingId, transcripts: rows, summaryText: summary?.summaryText, slideTexts: slides)
    }

    /// Post-summary action-item extraction (TASK-037). Skips meetings that
    /// already have items (regeneration must not duplicate them); the
    /// extractor persists what it finds.
    private func extractActionItemsBestEffort(meetingId: String) async {
        do {
            guard let meeting = try await meetingRepository.find(id: meetingId) else { return }
            let repo = TaskRepository(database: database)
            let existing = try await repo.itemsForMeeting(meetingId)
            guard existing.isEmpty else { return }
            guard let textGen = await makeTextGenerator(
                maxOutputTokens: 2048,
                schemaJSON: ActionItemExtractor.itemsSchemaJSON
            ) else { return }
            let items = try await ActionItemExtractor().extractActionItems(
                for: meeting,
                transcriptRepo: transcriptRepository,
                actionItemRepo: repo,
                textGenerator: textGen
            )
            fileLog("Action items: extracted \(items.count) for \(meetingId)")
        } catch {
            fileLog("Action items: extraction failed (best-effort) — \(error.localizedDescription)")
        }
    }

    func loadMeetings() {
        loadMeetingsTask?.cancel()
        loadMeetingsTask = Task {
            // Debounce: wait 150ms before actually loading to coalesce rapid calls
            // (e.g., multiple database change notifications firing in quick succession).
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            do {
                let upcoming = try await meetingRepository.upcomingMeetings()
                let past = try await meetingRepository.pastMeetings(limit: 50)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.upcomingMeetings = upcoming
                    let currentIds = Set(upcoming.map(\.id))
                    self.notifiedMeetingIds = self.notifiedMeetingIds.intersection(currentIds)
                    self.hudShownMeetingIds = self.hudShownMeetingIds.intersection(currentIds)
                    self.pastMeetings = past
                    self.meetings = upcoming + past
                }
                // Rebuild folders from the WHOLE table (the lists above are a
                // 50-row window; see meetingFolders). Runs after the lists
                // land so their didSet cache invalidation precedes the
                // refill, and on every reload — a new series instance joins
                // its folder the moment the meeting lists refresh, which is
                // what makes folder auto-add reliable.
                let everything = try await meetingRepository.allActiveMeetings()
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self._cachedFolders = MeetingFolder.group(everything)
                }
                // System banner notifications are disabled in favour of the
                // in-app HUD. Clear any reminders scheduled by older builds
                // so they don't fire alongside it.
                await self.notificationService.cancelAllMeetingNotifications()
            } catch {
                if !Task.isCancelled {
                    Logger.database.error("Failed to load meetings: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    // MARK: - Startup Cleanup

    /// On launch, recover meetings stuck in "recording" or "transcribing" from a prior crash.
    ///
    /// - Stuck recordings WITH audio files → set to transcribing and queue batch transcription
    // MARK: - Task Queue Setup

    private func setupTaskQueue() {
        // Register handlers — these closures do the actual work
        taskQueueManager.transcriptionHandler = { [weak self] meetingId, audioURL, metadata in
            guard let self else { return }
            // "retranscribe" tasks come from the full voice-profile rebuild.
            // They REPLACE a meeting's existing transcripts rather than append:
            // the old rows stay visible until the new transcription succeeds,
            // then are swapped atomically in the commit below. Normal recordings
            // pass nil metadata and never delete (there's nothing to replace).
            let replaceExisting = (metadata == "retranscribe")
            self.fileLog("TaskQueue: running transcription for \(meetingId)\(replaceExisting ? " (retranscribe/replace)" : "")")
            self.taskQueueManager.reportCurrentProgress(stage: "Transcribing audio")

            // Multi-session resolution. A reopened meeting carries one WAV per
            // capture session; the queue resolves `audioFilePaths.first`. When
            // prior transcript rows exist and a newer session file is present,
            // transcribe the LATEST session and APPEND its rows after the
            // existing timeline — re-transcribing session 1 produced duplicate
            // (meetingId, startTime, endTime) rows that the unique index
            // silently swallowed, so reopened audio never reached the
            // transcript. With no rows yet (crash recovery can leave a 44-byte
            // husk as .first), transcribe the largest file instead.
            var effectiveURL = audioURL
            var timebaseOffset: Double = 0
            if !replaceExisting,
               let meeting = try? await self.meetingRepository.find(id: meetingId),
               meeting.audioFilePaths.count > 1 {
                let existingMaxEnd: Double = (try? await self.database.writer.read { db in
                    try Double.fetchOne(db, sql: "SELECT MAX(endTime) FROM transcript WHERE meetingId = ?", arguments: [meetingId]) ?? 0
                }) ?? 0
                if existingMaxEnd > 0, let lastPath = meeting.audioFilePaths.last {
                    effectiveURL = URL(fileURLWithPath: lastPath)
                    // Offset floor = session 1's FILE duration, not just its
                    // last transcript row: the voice-fingerprint slicers
                    // resolve `audioFilePaths.first`, so an offset that lands
                    // inside file 1's trailing-silence band would slice the
                    // wrong session's audio into a person's voice profile.
                    var offsetFloor = existingMaxEnd + 1.0
                    if let firstPath = meeting.audioFilePaths.first,
                       let firstFile = try? AVAudioFile(forReading: URL(fileURLWithPath: firstPath)),
                       firstFile.processingFormat.sampleRate > 0 {
                        let firstDuration = Double(firstFile.length) / firstFile.processingFormat.sampleRate
                        offsetFloor = max(offsetFloor, firstDuration + 1.0)
                    }
                    timebaseOffset = offsetFloor
                    self.fileLog("TaskQueue: append-mode transcription — session file \(URL(fileURLWithPath: lastPath).lastPathComponent), offset \(Int(timebaseOffset))s")
                } else if existingMaxEnd == 0 {
                    func fileSize(_ path: String) -> Int {
                        ((try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? Int) ?? 0
                    }
                    if let largest = meeting.audioFilePaths.max(by: { fileSize($0) < fileSize($1) }) {
                        effectiveURL = URL(fileURLWithPath: largest)
                        self.fileLog("TaskQueue: multi-file meeting with no rows — transcribing largest file \(URL(fileURLWithPath: largest).lastPathComponent)")
                    }
                }
            }

            var rawTranscripts = try await self.batchTranscribe(meetingId: meetingId, audioURL: effectiveURL, timebaseOffset: timebaseOffset)

            // Append mode: the new session's diarization numbers clusters from
            // "Speaker 1" again, colliding with session 1's label namespace —
            // a later fill-only pass would then stamp session-2 names onto
            // session-1's still-anonymous rows. Shift the new session's labels
            // past the highest existing speaker number.
            if timebaseOffset > 0 {
                let existingLabels: [String] = (try? await self.database.writer.read { db in
                    try String.fetchAll(db, sql: "SELECT DISTINCT speakerLabel FROM transcript WHERE meetingId = ? AND speakerLabel IS NOT NULL", arguments: [meetingId])
                }) ?? []
                let existingMapKeys: [String] = (try? await self.meetingRepository.find(id: meetingId))
                    .map { Array($0.speakerMapDictionary.keys) } ?? []
                let labelShift = Self.maxSpeakerNumber(in: existingLabels + existingMapKeys)
                if labelShift > 0 {
                    rawTranscripts = Self.shiftSessionSpeakerLabels(rawTranscripts, by: labelShift)
                    self.fileLog("TaskQueue: append-mode labels shifted by +\(labelShift)")
                }
            }

            // Atomically commit transcripts + meeting-status update in one write.
            // Previously separate writer.write calls; a single transaction means a crash
            // between steps cannot leave transcripts saved but meeting still in .transcribing.
            if var meeting = try? await self.meetingRepository.find(id: meetingId) {
                // Speaker labels (Speaker 1, Speaker 2, …) are intentionally NOT
                // written to meeting.participants. That field holds real names from
                // calendar attendees. Labels live only in transcript.speakerLabel
                // and are mapped to real names by applySpeakerAttribution below.

                // v3.1 Layer 2: try to attribute "Speaker N" clusters to real
                // attendee names. The hook fires AFTER diarization but BEFORE
                // persistence so the rewritten labels land in the DB on the
                // first save. No-op when Ollama is down, no other participants
                // exist, or the LLM fails — labels just stay as Speaker N.
                // Replace mode rebuilds the transcript from scratch — the old
                // speakerMap/confidence/flags are keyed to the OLD clustering's
                // ids. Left in place, a later fill-only pass would stamp stale
                // names onto unrelated new clusters.
                if replaceExisting, !rawTranscripts.isEmpty {
                    meeting.setSpeakerMap([:])
                    meeting.setSpeakerConfidenceMap([:])
                    meeting.setAttributionFlags([])
                }

                // Append mode preserves session 1's maps: pass them as existing
                // assignments (elimination must not re-mint their names) and
                // merge the result instead of replacing.
                let isAppend = timebaseOffset > 0
                let priorMap = meeting.speakerMapDictionary
                let priorConf = meeting.speakerConfidenceMapDictionary
                let priorFlags = meeting.attributionFlagList

                self.taskQueueManager.reportCurrentProgress(stage: "Attributing speakers")
                let (transcripts, attributedMeeting) = await self.applySpeakerAttribution(
                    transcripts: rawTranscripts,
                    meeting: meeting,
                    existingAssignments: isAppend ? priorMap : [:]
                )
                meeting = attributedMeeting

                if isAppend {
                    // Session-2 cluster ids are namespaced past session 1's, so
                    // a plain union is collision-free; prior entries win on the
                    // shared "mic" key (same value anyway).
                    let newMap = meeting.speakerMapDictionary.merging(priorMap) { _, prior in prior }
                    let newConf = meeting.speakerConfidenceMapDictionary.merging(priorConf) { _, prior in prior }
                    var mergedFlags = priorFlags
                    for f in meeting.attributionFlagList where !mergedFlags.contains(f) {
                        mergedFlags.append(f)
                    }
                    meeting.setSpeakerMap(newMap)
                    meeting.setSpeakerConfidenceMap(newConf)
                    meeting.setAttributionFlags(mergedFlags)
                }

                let wasTranscribing = meeting.status == .transcribing
                if wasTranscribing { meeting.status = .complete }

                // Durable record that transcription ran — set whether or not it
                // produced segments. Stops the startup orphan scan from
                // re-enqueuing this meeting forever when it yields zero
                // transcripts (and survives the Tasks "Clear completed" button,
                // which deletes the task rows the scan used to rely on).
                meeting.transcriptionAttemptedAt = Date()

                self.taskQueueManager.reportCurrentProgress(stage: "Saving transcripts")
                let commitSucceeded: Bool
                do {
                    try await self.database.writer.write { db in
                        // Replace mode: clear the meeting's old transcripts in the
                        // same transaction, but only when the new pass actually
                        // produced segments — a failed re-transcription must not
                        // wipe a meeting's existing transcript. Also avoids the
                        // unique-index conflict on (meetingId, startTime, endTime)
                        // that appending re-transcribed rows would hit.
                        if replaceExisting, !transcripts.isEmpty {
                            try Transcript
                                .filter(Transcript.Columns.meetingId == meetingId)
                                .deleteAll(db)
                        }
                        for var t in transcripts { try t.save(db) }
                        try meeting.save(db)
                    }
                    commitSucceeded = true
                } catch {
                    Logger.transcription.error("Failed to commit transcripts for \(meetingId): \(error.localizedDescription, privacy: .public)")
                    commitSucceeded = false
                }

                if commitSucceeded, wasTranscribing {
                    NotificationCenter.default.post(
                        name: .meetingStateChanged,
                        object: self.stateMachine,
                        userInfo: ["meetingId": meeting.id, "status": meeting.status.rawValue]
                    )
                }
                if commitSucceeded {
                    Logger.transcription.info("Transcription committed: \(transcripts.count) segments for \(meetingId)")
                }

                // P1-T06: auto-title ad-hoc meetings once transcripts are persisted.
                // Calendar meetings already have a title from the event, so skip those.
                await self.autoTitleIfNeeded(meeting: meeting, transcripts: transcripts)

                // Cross-meeting voice learning. This is the ONLY place the normal
                // recording flow learns voice profiles. learnVoiceProfiles is
                // transcript-based: it reads the just-committed rows (now carrying
                // attributed names), groups time ranges per confirmed speaker, and
                // extracts a fingerprint from the system-only WAV. It already
                // filters generic labels (Speaker N / system / mic / Unknown) and
                // applies a confidence floor so low-confidence LLM guesses don't
                // poison the profile DB. No-op when there's no system audio.
                //
                // (Historically this only ran on manual re-run / rebuild, so
                // profiles were never learned automatically — the diarization
                // task that was supposed to do it bailed because it required
                // "system"-labelled rows the batch path never produces.)
                if commitSucceeded {
                    await self.learnVoiceProfiles(meetingId: meetingId)
                }

                self.loadMeetings()
            }
        }

        taskQueueManager.summaryHandler = { [weak self] meetingId in
            guard let self else { return }
            self.fileLog("TaskQueue: running summary for \(meetingId)")
            try await self.generateSummaryForTask(meetingId: meetingId)
            // Action items are a default output of every summarized meeting,
            // not an opt-in recipe: 6 items had ever been extracted across
            // 641 meetings before this (TASK-037). Best-effort — extraction
            // failure never fails the summary task. Runs inside the queue's
            // summary handler, so the TaskQueue rule holds.
            await self.extractActionItemsBestEffort(meetingId: meetingId)
            await self.extractInsightsBestEffort(meetingId: meetingId)
            await self.scoreIntentBestEffort(meetingId: meetingId)
            await self.computeSpeechStatsBestEffort(meetingId: meetingId)
            await self.computeSentimentBestEffort(meetingId: meetingId)
            await self.matchTopicTrackersBestEffort(meetingId: meetingId)
            await self.updateSeriesThreadBestEffort(meetingId: meetingId)
            // Semantic index (TASK-045): priority 8 — after cleanup (6) and
            // the follow-up email (7), embedding is the least urgent step.
            await self.taskQueueManager.enqueue(type: .embedIndex, meetingId: meetingId, priority: 8)
            self.loadMeetings()
        }

        taskQueueManager.embedIndexHandler = { [weak self] meetingId in
            guard let self else { return }
            try await self.runEmbedIndex(meetingId: meetingId)
        }

        taskQueueManager.weeklyDigestHandler = { [weak self] in
            guard let self else { return }
            try await self.generateWeeklyDigest()
        }

        taskQueueManager.gardenerHandler = { [weak self] in
            guard let self else { return }
            try await self.runGardener()
        }

        taskQueueManager.factBackfillHandler = { [weak self] in
            guard let self else { return }
            try await self.runFactBackfill()
        }

        taskQueueManager.glossaryHandler = { [weak self] in
            guard let self else { return }
            try await self.runGlossaryMiner()
        }

        taskQueueManager.speechStatsHandler = { [weak self] in
            guard let self else { return }
            await self.runSpeechStatsBackfill()
        }

        taskQueueManager.sentimentBackfillHandler = { [weak self] in
            guard let self else { return }
            await self.runSentimentBackfill()
        }

        taskQueueManager.topicBackfillHandler = { [weak self] in
            guard let self else { return }
            await self.runTopicBackfill()
        }

        // Governor inputs (TASK-055): composed from signals AppState already
        // tracks. deferredSinceHours is the continuous-deferral age of the
        // longest-waiting pending background row — anchored to firstDeferredAt
        // (set on first defer, reset on run; TASK-093), not row-creation time.
        ollamaService.onAllWorkFinished = { [weak self] in
            self?.interactiveAIBroker.drain()
        }

        interactiveAIBroker.onTimeout = { [weak self] id in
            guard let self,
                  let idx = self.globalChatMessages.firstIndex(where: { $0.id == id }) else { return }
            self.globalChatMessages[idx].content = "Timed out waiting for the local model — ask again."
            self.globalChatMessages[idx].isPending = false
        }

        taskQueueManager.backgroundPolicyInputs = { [weak self] in
            guard let self else {
                return BackgroundWorkPolicy.Inputs(
                    isRecording: false, minutesToNextMeeting: nil,
                    thermalState: .nominal, onBattery: false,
                    allowOnBattery: false, interactivePending: false,
                    localHour: 12, deferredSinceHours: 0)
            }
            let nextStart = self.upcomingMeetings
                .compactMap(\.scheduledStartDate)
                .filter { $0 > Date() }
                .min()
            return BackgroundWorkPolicy.Inputs(
                isRecording: self.isRecording,
                minutesToNextMeeting: nextStart.map { Int($0.timeIntervalSinceNow / 60) },
                thermalState: self.thermalState,
                onBattery: BackgroundWorkPolicy.isOnBattery(),
                allowOnBattery: UserDefaults.standard.bool(forKey: "backgroundAI.allowOnBattery"),
                interactivePending: self.interactiveAIBroker.pendingCount > 0,
                localHour: Calendar.current.component(.hour, from: Date()),
                deferredSinceHours: TaskQueueItem.backgroundDeferralAgeHours(self.taskQueueManager.allTasks, now: Date())
            )
        }

        // Gate AI-dependent auto-enqueues (summary) on a configured backend so
        // users with no AI don't accumulate failed tasks after every meeting.
        taskQueueManager.isAIWorkConfigured = { [weak self] in self?.isAIWorkConfigured ?? false }

        taskQueueManager.diarizationHandler = { [weak self] meetingId, systemAudioURL in
            guard let self else { return }
            self.fileLog("TaskQueue: diarization starting for \(meetingId)")
            // Rethrows so the queue's retry/failed machinery engages — a
            // swallowed diarization error used to mark the task completed
            // with the transcript silently stuck at "Speaker N".
            try await self.runDiarization(meetingId: meetingId, systemAudioURL: systemAudioURL)
        }

        taskQueueManager.enrichmentHandler = { [weak self] meetingId in
            guard let self else { return }
            self.fileLog("TaskQueue: enrichment placeholder for \(meetingId)")
        }

        taskQueueManager.contextEnrichmentHandler = { [weak self] meetingId in
            guard let self else { return }
            self.fileLog("TaskQueue: finding related meetings for \(meetingId)")
            let service = RelevantMeetingService(database: AppDatabase.shared)

            // Build a synthesizer closure that routes to the same AI backend
            // the user has configured for summaries (Claude key wins; falls
            // back to Ollama if a local model is reachable). Returns nil — and
            // the brief is skipped — when neither is available.
            let synthesizer = await self.makeContextBriefSynthesizer()
            try await service.enrichContext(meetingId: meetingId, briefSynthesizer: synthesizer)
            self.loadMeetings()
        }

        taskQueueManager.regenerationHandler = { [weak self] meetingId, recipeId in
            guard let self else { return }
            self.fileLog("TaskQueue: running regeneration for \(meetingId) recipeId=\(recipeId ?? "none")")
            try await self.generateSummaryForTask(meetingId: meetingId, recipeId: recipeId)
            self.loadMeetings()
        }

        taskQueueManager.summaryCompletedHandler = { [weak self] meetingId in
            guard let self else { return }
            let meeting = try? await self.meetingRepository.find(id: meetingId)
            let title = meeting?.title ?? "Meeting"
            self.sendSummaryReadyNotification(meetingId: meetingId, meetingTitle: title)

            // Write summary + transcript back to KB folder if enabled
            if self.settings.kbWriteBack, let meeting {
                let summary = try? await self.summaryRepository.latestSummary(meetingId: meetingId)
                let segments: [Transcript] = (try? await self.transcriptRepository.transcriptsForMeeting(meetingId)) ?? []
                await KBWriteBackService.shared.writeMeeting(
                    meeting,
                    summary: summary?.summaryText ?? "",
                    transcript: segments
                )
            }

            if self.settings.autoFollowUpEmail {
                let metadata = "{\"recipeId\":\"builtin-follow-up-email\"}"
                await self.taskQueueManager.enqueue(
                    type: .regeneration,
                    meetingId: meetingId,
                    priority: 7,
                    metadata: metadata
                )
            }

            // If the meeting whose summary just landed is on today's calendar
            // (typical for an in-the-moment recording), the daily brief now
            // has fresher carry-over context. Re-evaluate.
            if let m = meeting, Calendar.current.isDateInToday(m.scheduledStartDate ?? m.startDate ?? .distantPast) {
                await self.maybeRegenerateDailyBrief()
            }

            // v3.10.3+: auto-enqueue the detailed outline after summary
            // completes. Lower priority than the follow-up email so the
            // summary-adjacent UX surfaces (notification + email draft)
            // land first; outline takes longest of the three.
            await self.taskQueueManager.enqueue(
                type: .detailedOutline,
                meetingId: meetingId,
                priority: 8
            )
        }

        taskQueueManager.knowledgeBaseIndexHandler = {
            await KnowledgeBaseService.shared.reindex()
        }

        // Wire the KB service back to the queue so enqueueReindex() routes through it.
        KnowledgeBaseService.shared.taskQueue = taskQueueManager
        KnowledgeBaseService.shared.embedder = embeddingService

        // Transcript cleanup: stitch + best-effort AI pass.
        // Runs after batch transcription completes (enqueued from the
        // transcription handler). Best-effort AI — falls back to
        // stitch-only when no model is configured or the call fails.
        taskQueueManager.transcriptCleanupHandler = { [weak self] meetingId in
            guard let self else { return }
            await self.runTranscriptCleanup(meetingId: meetingId)
            // v3.10 #7: after cleanup completes, re-check whether attribution
            // left any clusters unresolved. If so, enqueue a retryAttribution
            // task. The retry runs with the same pipeline but against the
            // full transcript — useful when the first 20-turn LLM window
            // didn't have enough context.
            await self.maybeEnqueueRetryAttribution(meetingId: meetingId)
        }

        // v3.10 #7: second-pass speaker attribution — runs the same flow as
        // applySpeakerAttribution but explicitly triggered after cleanup.
        // Limited to one retry per meeting (gated in maybeEnqueueRetryAttribution).
        taskQueueManager.retryAttributionHandler = { [weak self] meetingId in
            guard let self else { return }
            await self.runRetryAttribution(meetingId: meetingId)
        }

        // v3.10.3+: detailed outline — single LLM pass that produces a
        // time-stamped, topic-segmented Markdown blob. Auto-enqueued after
        // summary completes; can be re-run on demand from the Outline tab.
        taskQueueManager.detailedOutlineHandler = { [weak self] meetingId in
            guard let self else { return }
            await self.runDetailedOutlineGeneration(meetingId: meetingId)
        }

        // PRJ-007: "Enhance Notes" — rewrites the user's raw notes into a
        // polished version in their own structure. User-initiated only; the
        // throw propagates so the queue surfaces "No AI backend" as a failed
        // task with a clear error (mirrors the summary handler).
        taskQueueManager.enhanceNotesHandler = { [weak self] meetingId in
            guard let self else { return }
            self.fileLog("TaskQueue: enhancing notes for \(meetingId)")
            try await self.generateEnhancedNotesForTask(meetingId: meetingId)
        }

        // When the queue drains, retry any daily brief that was deferred due to
        // backend contention (e.g. while a bulk re-transcription was running),
        // and release the diarization models — Pyannote/wespeaker CoreML stays
        // resident otherwise, permanent footprint in a days-long menu-bar app
        // for work that runs ~a minute per meeting. Reload on next use is a
        // cache-hit (no re-download).
        taskQueueManager.onQueueIdle = { [weak self] in
            guard let self else { return }
            // Broker drains FIRST on the idle edge (review M3) — queued user
            // questions must not race the model unload below.
            self.interactiveAIBroker.drain()
            await SpeakerDiarizationService.shared.unloadModels()
            FluidAudioDiarizationService.shared.unloadModels()
            self.fileLog("TaskQueue: idle — diarization models unloaded")

            // Free the local LLM early after batch work instead of waiting
            // out keep_alive (TASK-055 §4). Guards: nothing in flight at the
            // Ollama chokepoint (review M3 — an unload during a generation
            // starves the next chained call), and /api/ps-checked inside so
            // a non-resident model is never load-then-unloaded. TASK-071's
            // broker drains BEFORE this closure reaches here.
            if self.ollamaService.inFlightCount == 0 {
                await self.ollamaService.unloadIfResident(EmbeddingService.embedModel)
            }

            // WhisperKit (~1.5 GB) idle policy: release it when nothing can
            // need it soon — not recording, and no meeting starting within
            // the next hour (recordings cluster around meetings). On a 16 GB
            // machine this is the difference between the local LLM fitting
            // in RAM during summarization or swapping. Reload is kicked by
            // recording start AND by batchTranscribe itself, and the
            // transcription handler already waits up to 5 min for the load.
            if self.transcriptionService.isModelLoaded, !self.isRecording {
                let imminent = (try? await self.meetingRepository.meetingsStartingWithin(minutes: 60)) ?? []
                if imminent.isEmpty {
                    self.transcriptionService.unloadModel()
                    self.fileLog("TaskQueue: idle — WhisperKit model unloaded (no meeting within 60 min)")
                }
            }
        }

        // Start the queue (recovers stuck tasks, enqueues orphans, begins processing)
        Task {
            await taskQueueManager.startUp()
            await maybeRunPendingVoiceReset()
        }
    }

    /// UserDefaults key set (out-of-band, e.g. by the Settings button or a tool)
    /// to request a full voice-profile reset + re-transcription on the next
    /// normal launch. One-shot: cleared as soon as the reset is enqueued.
    static let pendingVoiceResetKey = "pendingFullVoiceReset"

    /// Runs the full reset when requested — either by the persistent
    /// `pendingFullVoiceReset` flag (the normal path: set it, reopen the app,
    /// it rebuilds in the background while you use the app) or by the
    /// `--rebuild-voice-profiles[=N]` launch arg (headless/testing). Waits for
    /// the meeting list and the WhisperKit model before enqueuing so the first
    /// re-transcription doesn't race model load. The flag is cleared up front so
    /// a crash mid-rebuild doesn't loop the wipe on every subsequent launch.
    private func maybeRunPendingVoiceReset() async {
        let flagSet = UserDefaults.standard.bool(forKey: Self.pendingVoiceResetKey)
        let arg = CommandLine.arguments.first { $0.hasPrefix("--rebuild-voice-profiles") }
        guard flagSet || arg != nil else { return }

        var cap: Int? = nil
        if let arg, let eq = arg.firstIndex(of: "="), let n = Int(arg[arg.index(after: eq)...]) { cap = n }

        // Clear the flag immediately — the wipe + enqueue below is the one-shot
        // action; the task queue persists the enqueued work across restarts.
        UserDefaults.standard.removeObject(forKey: Self.pendingVoiceResetKey)

        // Ensure the meeting list is loaded (the reset filters over `meetings`).
        loadMeetings()
        for _ in 0..<50 where meetings.isEmpty {
            try? await Task.sleep(for: .milliseconds(200))
            loadMeetings()
        }
        // Wait up to 5 min for the WhisperKit model so the first re-transcription
        // doesn't fail before the model finishes loading.
        for _ in 0..<300 where !transcriptionService.isModelLoaded {
            try? await Task.sleep(for: .seconds(1))
        }
        let count = await runFullVoiceProfileReset(maxMeetings: cap)
        fileLog("VoiceReset(pending): enqueued \(count) meeting(s)\(cap.map { " (capped at \($0))" } ?? "")")
    }

    /// Drive `DetailedOutlineService.generate` with the user's current AI
    /// provider preference. Used by the `detailedOutlineHandler` task wire-up
    /// and by the Outline tab's "Regenerate" button via direct call.
    ///
    /// Output budget is bumped to 16K tokens — hour-long meetings produce
    /// 8–12K tokens of structured outline, and the default 2K/4K caps used
    /// by every other path were silently truncating the outline mid-meeting.
    func runDetailedOutlineGeneration(meetingId: String) async {
        let textGen = await makeTextGenerator(maxOutputTokens: 16384)
        let modelLabel: String = {
            if settings.useLocalLLM { return "ollama/\(settings.ollamaModel)" }
            return settings.claudeModel
        }()
        _ = await DetailedOutlineService.shared.generate(
            meetingId: meetingId,
            settings: settings,
            textGenerator: textGen,
            modelLabel: modelLabel
        )
        loadMeetings()
    }

    /// Generate a summary for a meeting via the task queue.
    /// Uses Ollama (adaptive) or Claude depending on settings.
    /// - Parameter recipeId: Optional recipe override. When provided, uses the recipe's
    ///   promptTemplate instead of the default summaryPromptTemplate. Used by `.regeneration` tasks.
    private func generateSummaryForTask(meetingId: String, recipeId: String? = nil) async throws {
        // Load transcript
        let segments = try await transcriptRepository.transcriptsForMeeting(meetingId, limit: 5000)
        guard !segments.isEmpty else {
            throw TaskQueueError.noHandler("This meeting has no transcript yet. Record a meeting with audio first, then the summary can be generated.")
        }

        let transcript = segments.map { $0.text }.joined(separator: "\n")

        // Load meeting for template substitution
        guard let meeting = try await meetingRepository.find(id: meetingId) else { return }

        // Resolve which prompt template to use: recipe override → default template
        // Always read the prompt fresh from the database so edits in
        // Settings → Prompts take effect immediately, without depending on the
        // in-memory settings snapshot being current (eliminates a race where
        // the user changes the prompt and clicks Regenerate before loadSettings
        // completes its async refresh).
        let rawTemplate: String
        if let recipeId,
           let recipe = try? await RecipeRepository(database: database).find(id: recipeId) {
            rawTemplate = recipe.promptTemplate
        } else {
            rawTemplate = PromptManager().loadTemplate(settings: settings)
        }

        let participantsString = meeting.participantList.isEmpty
            ? "Not recorded"
            : meeting.participantList.joined(separator: ", ")

        // Pull relevant Knowledge Base excerpts so the summary can reference the
        // KB is intentionally OUT of the main-summary prompt. Earlier we injected
        // KB excerpts here, but they leaked unrelated content into Discussion
        // Points / Decisions / Open Questions — e.g. an Globex meeting summary
        // citing Initech-specific people and Umbrella Health pricing pulled from
        // KB docs about a different customer. The main summary must be grounded
        // ONLY in this meeting's transcript + the user's own notes.
        //
        // Cross-meeting context lives in a separate, strictly-scoped "How this
        // connects to other work" section appended after the summary saves —
        // see appendConnectionsSection below.
        // TASK-066: receipts variables. The auto follow-up email runs through
        // this path (recipe template as system prompt); insight extraction is
        // awaited inside the summary handler before the follow-up task pops,
        // so anchored facts already exist by the time this resolves.
        var receipts: (commitments: String, carried: String) = ("", "")
        if rawTemplate.contains("{{commitmentsWithReceipts}}") || rawTemplate.contains("{{carriedQuestions}}") {
            receipts = await ReceiptsBuilder.build(for: meeting, allMeetings: meetings, database: database)
        }

        let baseSystemPrompt = rawTemplate
            .replacingOccurrences(of: "{{meetingTitle}}", with: meeting.title)
            .replacingOccurrences(of: "{{date}}", with: meeting.startDate?.formatted() ?? "Unknown")
            .replacingOccurrences(of: "{{duration}}", with: meeting.formattedDuration)
            .replacingOccurrences(of: "{{participants}}", with: participantsString)
            .replacingOccurrences(of: "{{priorContext}}", with: "")
            .replacingOccurrences(of: "{{knowledgeBase}}", with: "")
            .replacingOccurrences(of: "{{transcript}}", with: "")
            .replacingOccurrences(of: "{{notes}}", with: "")
            .replacingOccurrences(of: "{{commitmentsWithReceipts}}",
                                  with: receipts.commitments.isEmpty ? "No tracked commitments for this meeting." : receipts.commitments)
            .replacingOccurrences(of: "{{carriedQuestions}}",
                                  with: receipts.carried.isEmpty ? "None carried from the previous session." : receipts.carried)

        // P2-T03: Notes-first summary. If the user captured notes during the meeting via
        // NotepadPaneView, treat those notes as the primary anchor and use the transcript to
        // fill in details. When no notes exist, fall back to the standard transcript-only path.
        let notes = (try? await noteRepository.notesForMeeting(meetingId)) ?? []
        let noteText = notes.map { $0.content }
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // P5-T02: Inject open action items from up to 3 prior sessions in the same series
        // so the model can carry them forward in the new summary.
        let seriesContext: String = await {
            let series = MeetingSeriesService.shared.detectSeries(for: meeting, in: meetings)
            let recent = Array(series.prefix(3))
            guard !recent.isEmpty else { return "" }
            let openByMeeting = await fetchOpenActionItems(for: recent)
            let lines = openByMeeting.compactMap { (m, items) -> String? in
                guard !items.isEmpty else { return nil }
                return items.map { "- [ ] \($0.title) (from \(m.title))" }.joined(separator: "\n")
            }
            guard !lines.isEmpty else { return "" }
            return """

            <previous_session_open_items>
            \(lines.joined(separator: "\n"))
            </previous_session_open_items>
            """
        }()

        let systemPrompt: String
        let userPrompt: String
        if noteText.isEmpty {
            systemPrompt = baseSystemPrompt + """


            Strict anti-hallucination rule: every claim, decision, action item, \
            and quoted line must come directly from the transcript provided. Do \
            NOT invent participants, accounts, organisations, dates, decisions, \
            commitments, pricing, or any specifics that aren't in the transcript. \
            If the transcript is short or thin, write a shorter summary — never \
            pad with assumed context.
            """
            if seriesContext.isEmpty {
                userPrompt = transcript
            } else {
                userPrompt = """
                \(seriesContext)

                <transcript>
                \(transcript)
                </transcript>
                """
            }
        } else {
            // Notes are GROUND TRUTH — both prep notes (written before the meeting)
            // and in-meeting notes captured by the user are stored in the same
            // MeetingNote rows, so this branch covers both. The summary's
            // structure, themes, and emphasis must mirror what the user wrote;
            // the transcript is supporting evidence, not the lead source.
            systemPrompt = baseSystemPrompt + """


            PRIORITY: the user captured notes before and/or during this meeting. \
            Treat those notes as GROUND TRUTH. The summary's structure, themes, \
            emphasis, and ordering must mirror what the user wrote — they \
            recorded what mattered to *them*. Use the transcript only to fill in \
            supporting detail, exact wording, names, and items the user clearly \
            missed.

            Strict anti-hallucination rules:
            - Every claim, decision, action item, and quoted line must be \
              traceable to either the notes or the transcript provided.
            - Do NOT contradict the notes.
            - Do NOT invent participants, accounts, organisations, dates, \
              decisions, commitments, pricing, or specifics absent from both \
              sources.
            - If neither source supports a section, write that section briefly \
              or skip it — never pad with assumed context.
            """
            userPrompt = """
            <user_notes>
            \(noteText)
            </user_notes>
            \(seriesContext)
            <transcript>
            \(transcript)
            </transcript>
            """
        }

        // Determine which AI backend to use (single source of truth).
        let backend = await resolveAIBackend(refreshOllama: true)

        // TASK-070: few-shot style calibration from the user's own past edits.
        let styleSection = await summaryStyleExamplesSection(
            excluding: meetingId,
            backend: backend,
            userPromptChars: userPrompt.count
        )
        let finalSystemPrompt = systemPrompt + styleSection

        let summaryText: String
        switch backend {
        case .ollama(let model):
            // Use streaming for task queue — never times out, reads chunks incrementally
            summaryText = try await ollamaService.generateStreaming(
                systemPrompt: finalSystemPrompt,
                userPrompt: userPrompt,
                model: model,
                activityLabel: "Summarizing meeting"
            )
        case .claude(let model):
            let claude = ClaudeService()
            summaryText = try await claude.sendMessage(
                systemPrompt: finalSystemPrompt,
                userPrompt: userPrompt,
                model: model,
                redactor: await cloudRedactorIfEnabled(texts: [finalSystemPrompt, userPrompt])
            )
        case .gemini(let model):
            let gemini = GeminiService()
            summaryText = try await gemini.sendMessage(
                systemPrompt: finalSystemPrompt,
                userPrompt: userPrompt,
                model: model,
                redactor: await cloudRedactorIfEnabled(texts: [finalSystemPrompt, userPrompt])
            )
        case .none:
            throw TaskQueueError.noHandler("No AI backend available (Ollama not running, no Claude key)")
        }

        // Defensive strip at the save boundary: never persist a summary that
        // still contains the model's <think> reasoning. generate() and
        // generateStreaming already strip, but enforcing it again here
        // guarantees a clean summary for every backend and code path —
        // belt-and-suspenders against the chain-of-thought leak.
        let cleanSummary = OllamaService.stripThinkBlock(summaryText)

        // Save summary. Record whether the user had notes at generation time —
        // the summary was anchored to them as ground truth above. Persisted
        // (not re-derived at view time) so the "Shaped by your notes" cue
        // survives the user editing or deleting their notes afterwards.
        var summary = MeetingSummary(
            meetingId: meetingId,
            promptUsed: finalSystemPrompt,
            summaryText: cleanSummary,
            modelUsed: backend.modelIdentifier,
            notesInformedSummary: !noteText.isEmpty
        )
        try await summaryRepository.save(&summary)
        fileLog("TaskQueue: summary saved for \(meetingId) (\(cleanSummary.count) chars)")

        // After saving, append a strictly-scoped "How this connects to other
        // work" section sourced ONLY from the Knowledge Base — see comment on
        // the removed KB injection above for why we keep KB out of the main
        // summary. No-op when no KB folder is set or no entities match.
        await appendConnectionsSection(meeting: meeting, summary: &summary)
    }

    /// PRJ-007: "Enhance Notes". Rewrites the user's raw notes into a polished
    /// version that keeps the user's own structure (their headings, order,
    /// emphasis) — a distinct artifact from the fixed-format `MeetingSummary`
    /// and never mutating the source `MeetingNote`. Driven by the user-initiated
    /// `.enhanceNotes` task type.
    ///
    /// Structure mirrors `generateSummaryForTask`: resolve the backend, build
    /// the prompt, run Ollama (streaming) or Claude, persist. Two differences:
    ///   - The transcript is OPTIONAL. During a live meeting the app hasn't
    ///     transcribed yet (transcription is post-stop), so an empty transcript
    ///     turns this into a pure polish — grammar/clarity only, no facts added.
    ///   - Empty notes is a hard guard — there is nothing to enhance, and the
    ///     UI disables the button in that case, so reaching here means a race.
    private func generateEnhancedNotesForTask(meetingId: String) async throws {
        guard let meeting = try await meetingRepository.find(id: meetingId) else {
            throw TaskQueueError.noHandler("Meeting not found.")
        }

        let noteText = (try await noteRepository.combinedNotes(meetingId: meetingId))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !noteText.isEmpty else {
            throw TaskQueueError.noHandler("There are no notes to enhance. Write some notes first.")
        }

        // Transcript is optional. Prefer the cleaned blob (resolved speaker
        // names, consistent timestamps); fall back to raw segments; empty when
        // neither exists (live meeting) — which the prompt builder reads as a
        // notes-only polish.
        let transcript: String = await {
            if let cleaned = try? await CleanedTranscriptRepository(database: database).cleanedTranscript(meetingId: meetingId),
               !cleaned.text.isEmpty {
                return cleaned.text
            }
            if let segments = try? await transcriptRepository.transcriptsForMeeting(meetingId, limit: 5000),
               !segments.isEmpty {
                return segments.map { $0.text }.joined(separator: "\n")
            }
            return ""
        }()

        // Resolve template fresh: user-edited value if present, else the
        // built-in default (mirrors PromptManager.loadEnhanceTemplate, but
        // reads the in-memory snapshot which AppState keeps current via the
        // summaryPromptTemplateDidChange observer).
        let template: String = {
            if let custom = settings.enhanceNotesPromptTemplate?.trimmingCharacters(in: .whitespacesAndNewlines),
               !custom.isEmpty {
                return custom
            }
            return DefaultPrompts.enhanceNotes
        }()

        let prompts = EnhanceNotesPromptBuilder.build(
            template: template,
            meeting: meeting,
            notes: noteText,
            transcript: transcript
        )

        let backend = await resolveAIBackend(refreshOllama: true)
        let content: String
        switch backend {
        case .ollama(let model):
            content = try await ollamaService.generateStreaming(
                systemPrompt: prompts.system,
                userPrompt: prompts.user,
                model: model,
                activityLabel: "Enhancing notes"
            )
        case .claude(let model):
            let claude = ClaudeService()
            content = try await claude.sendMessage(
                systemPrompt: prompts.system,
                userPrompt: prompts.user,
                model: model,
                redactor: await cloudRedactorIfEnabled(texts: [prompts.system, prompts.user])
            )
        case .gemini(let model):
            let gemini = GeminiService()
            content = try await gemini.sendMessage(
                systemPrompt: prompts.system,
                userPrompt: prompts.user,
                model: model,
                redactor: await cloudRedactorIfEnabled(texts: [prompts.system, prompts.user])
            )
        case .none:
            throw TaskQueueError.noHandler("No AI backend available (Ollama not running, no Claude key)")
        }

        let enhanced = EnhancedNote(
            meetingId: meetingId,
            content: content.trimmingCharacters(in: .whitespacesAndNewlines),
            modelUsed: backend.modelIdentifier,
            generatedAt: Date(),
            sourceNotesHash: EnhancedNote.stableHash(noteText),
            sourceNotesLength: noteText.count
        )
        try await enhancedNoteRepository.save(enhanced)
        fileLog("TaskQueue: enhanced notes saved for \(meetingId) (\(content.count) chars)")
    }

    /// Append a "How this connects to other work" section to a freshly-saved
    /// summary, sourced strictly from the user's Knowledge Base and gated on
    /// exact name matches against the meeting's context entities (account
    /// acronyms, product names, participant names). The strict gating exists
    /// because earlier KB injection bled unrelated context into the summary —
    /// e.g. an Globex-titled meeting picking up Initech-specific people and pricing
    /// from other customer docs in the KB.
    private func appendConnectionsSection(meeting: Meeting, summary: inout MeetingSummary) async {
        let entities = Self.extractContextEntities(meeting: meeting,
                                                    userEmail: googleAuthManager.userEmail,
                                                    userName: NSFullUserName())
        guard !entities.isEmpty else { return }

        // Per-entity KB retrieval so each query is anchored to a specific
        // name. Joining names into one FTS query would AND-combine the tokens;
        // we want excerpts that mention any one entity.
        var blocks: [String] = []
        var totalLen = 0
        let cap = 8000
        for entity in entities.prefix(8) {
            let chunk = await KnowledgeBaseService.shared.retrieveContext(query: entity)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !chunk.isEmpty else { continue }
            let labelled = "### Entity: \(entity)\n\(chunk)"
            if totalLen + labelled.count > cap { break }
            blocks.append(labelled)
            totalLen += labelled.count
        }
        guard !blocks.isEmpty else { return }
        let kbBlock = blocks.joined(separator: "\n\n---\n\n")

        guard let textGen = await makeTextGenerator(maxOutputTokens: 2048) else { return }

        let entitiesList = entities.map { "- \($0)" }.joined(separator: "\n")
        let system = """
            You are surfacing how a specific meeting connects to the user's wider work, drawing ONLY from the provided Knowledge Base excerpts. STRICT rules:

            1. Each connection MUST be anchored to one of the listed context entities — an account acronym, product name, or participant name from THIS meeting — appearing by EXACT name in the excerpt. If an excerpt doesn't mention a listed entity by exact name, ignore it; it's a different thread.
            2. Do NOT generalise from similar-sounding topics, generic industry terms, or shared roles. "Healthcare" or "genomics" alone is not a connection — the entity name must be present.
            3. First pass — direct: surface KB items that name a listed entity directly (e.g., "Globex", "Acme", a participant by name).
            4. Second pass — bridged: from the direct hits, you may briefly note where the SAME named entity appears in conversations with OTHER people elsewhere in the KB (e.g., "X also came up with Y" — still anchored on the named entity).
            5. Cite the source path in square brackets after each bullet (e.g., "[kb/path/to/doc.md]").
            6. If no excerpt qualifies after filtering, output exactly:
               (No clear connections to other work in your Knowledge Base.)
               Do NOT invent connections to fill the section.
            7. Output Markdown only — no preamble, no chain-of-thought. 2 to 5 bullets max. Each bullet under 30 words.
            """
        let user = """
            Meeting: \(meeting.title)
            Participants: \(meeting.participantList.joined(separator: ", "))

            Context entities (excerpts MUST mention one of these by exact name to count):
            \(entitiesList)

            Knowledge Base excerpts (some may be unrelated — apply the rules above):
            \(kbBlock)
            """
        let raw: String
        do {
            raw = try await textGen(system, user)
        } catch {
            Logger.ai.warning("Connections section synthesis failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        let body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Skip refusal-style or empty outputs so we don't pad the summary.
        guard !body.isEmpty,
              !body.lowercased().contains("no clear connections") else {
            return
        }

        let section = "\n\n## How this connects to other work\n\n\(body)"
        var updated = summary
        updated.summaryText += section
        do {
            try await summaryRepository.update(updated)
            summary = updated
            fileLog("Connections section appended for \(meeting.id) (\(body.count) chars, \(entities.count) entities)")
        } catch {
            Logger.ai.warning("Connections section save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Extract context entities for the connections section: participant
    /// names (excluding the local user), all-caps acronyms (Globex, NHS, Initech,
    /// 2–6 chars), and CamelCase product names (Acme). Used as exact-name
    /// gates against KB excerpts so the section can't drift to a different
    /// customer with a similar topic. Static so it stays trivially testable.
    static func extractContextEntities(meeting: Meeting, userEmail: String?, userName: String) -> [String] {
        var entities = [String]()
        var seen = Set<String>()
        func add(_ s: String) {
            let trimmed = s.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }
            let key = trimmed.lowercased()
            if seen.insert(key).inserted { entities.append(trimmed) }
        }

        // Participants (excluding the local user).
        let userEmailLower = userEmail?.lowercased().trimmingCharacters(in: .whitespaces) ?? ""
        let userNameLower = userName.lowercased().trimmingCharacters(in: .whitespaces)
        for raw in meeting.participantList {
            let p = raw.trimmingCharacters(in: .whitespaces)
            let pLower = p.lowercased()
            if !userEmailLower.isEmpty, pLower == userEmailLower { continue }
            if !userNameLower.isEmpty, pLower == userNameLower { continue }
            if let at = p.firstIndex(of: "@") {
                add(String(p[..<at]))   // email local-part — usually their name
            } else {
                add(p)
            }
        }

        // Acronyms (3–6 ALL CAPS letters/digits — 2-letter ones like "IT",
        // "OK", "AI" are too generic to anchor a connection on) and CamelCase
        // (initial cap + at least one internal cap, e.g. "Acme") from
        // the title.
        let titleStop: Set<String> = [
            "TBD"
        ]
        let title = meeting.title as NSString
        let range = NSRange(location: 0, length: title.length)
        if let acro = try? NSRegularExpression(pattern: "\\b[A-Z][A-Z0-9]{2,5}\\b") {
            acro.enumerateMatches(in: meeting.title, range: range) { m, _, _ in
                guard let r = m?.range else { return }
                let tok = title.substring(with: r)
                guard !titleStop.contains(tok) else { return }
                add(tok)
            }
        }
        if let camel = try? NSRegularExpression(pattern: "\\b[A-Z][a-z0-9]+[A-Z][A-Za-z0-9]*\\b") {
            camel.enumerateMatches(in: meeting.title, range: range) { m, _, _ in
                guard let r = m?.range else { return }
                add(title.substring(with: r))
            }
        }
        return entities
    }

    /// Re-run LLM speaker attribution against an existing meeting's transcripts
    /// and persist the result. Safe to call any time — silent no-op when the
    /// meeting has no participants or no transcripts. Used both by the manual
    /// "Re-run AI" button on the transcript diagnostic banner and by the
    /// one-time retroactive scan on app upgrade.
    func rerunSpeakerAttribution(for meetingId: String) async {
        guard let meeting = try? await meetingRepository.find(id: meetingId),
              !meeting.participantList.isEmpty else { return }
        let transcripts = (try? await transcriptRepository.transcriptsForMeeting(meetingId, limit: 10_000)) ?? []
        guard !transcripts.isEmpty else { return }

        let existingMap = meeting.speakerMapDictionary
        let existingConf = meeting.speakerConfidenceMapDictionary

        let (_, attributed) = await applySpeakerAttribution(
            transcripts: transcripts,
            meeting: meeting,
            existingAssignments: existingMap
        )

        // FILL-ONLY merge — same invariant as runRetryAttribution. A re-run
        // (manual "Re-run AI" button, series propagation, retro scan) must
        // never flip an existing attribution: replacing the whole map silently
        // dropped manual renames (confidence 1.0) and let the LLM rename
        // confirmed speakers. Re-runs only resolve still-anonymous clusters.
        var mergedMap = existingMap
        var mergedConf = existingConf
        var newCount = 0
        for (cluster, name) in attributed.speakerMapDictionary where mergedMap[cluster] == nil {
            mergedMap[cluster] = name
            if let c = attributed.speakerConfidenceMapDictionary[cluster] { mergedConf[cluster] = c }
            newCount += 1
        }
        guard newCount > 0 else {
            Logger.general.info("rerunSpeakerAttribution: no new mappings for \(meetingId, privacy: .public) — keeping existing")
            return
        }

        // Rewrite rows from the MERGED map (not the re-run's raw output) so
        // rows can never disagree with the persisted map, and only touch rows
        // that are still anonymous ("Speaker N") or the raw mic bucket.
        let safeRelabelled: [Transcript] = transcripts.compactMap { t in
            guard let old = t.speakerLabel else { return nil }
            let oldLower = old.lowercased()
            guard oldLower.hasPrefix("speaker ") || oldLower == "mic" || oldLower == "system",
                  let newName = mergedMap[old], newName != old else { return nil }
            var copy = t
            copy.speakerLabel = newName
            return copy
        }

        var updatedMeeting = meeting
        updatedMeeting.setSpeakerMap(mergedMap)
        updatedMeeting.setSpeakerConfidenceMap(mergedConf)
        // Fresh flags were computed WITH existingAssignments merged in, so
        // they describe the combined state — replacing the stale first-pass
        // flags (which used to linger because re-runs never persisted theirs).
        updatedMeeting.setAttributionFlags(attributed.attributionFlagList)
        let meetingToSave = updatedMeeting

        // Persist relabelled transcripts + speakerMap update atomically.
        do {
            try await database.writer.write { db in
                for t in safeRelabelled {
                    var copy = t
                    try copy.update(db)
                }
                var m = meetingToSave
                try m.update(db)
            }
            Logger.general.info("rerunSpeakerAttribution: filled \(newCount) new cluster(s) for \(meetingId, privacy: .public)")
        } catch {
            Logger.general.error("rerunSpeakerAttribution: persist failed: \(error.localizedDescription, privacy: .public)")
        }

        // Cross-meeting learning: feed any newly-confirmed names into the
        // voice-profile DB so future meetings recognise them without an LLM
        // call. No-op when the meeting has no system audio file.
        await learnVoiceProfiles(meetingId: meetingId)
    }

    /// One-time retroactive speaker-attribution scan. Runs at most once per
    /// v3.10.4 (ADR-007). Triggered from `init`. If `useLocalLLM` is on and
    /// the Qwen3 tier models aren't installed, fire a background pull so
    /// the user picks up the new ladder without ever touching Settings.
    /// Skips silently when:
    ///   - Local LLM is off (user is on Claude)
    ///   - Ollama isn't reachable (server down — Claude fallback handles it)
    ///   - Both tier models are already present
    func verifyLocalModelsOnStartup() async {
        guard settings.useLocalLLM else { return }
        await ollamaService.refreshStatus()
        guard ollamaService.isReachable else { return }
        // The Settings UI subscribes to `ollamaInstaller.phase`; calling
        // `verifyAndPullMissing` flips that phase through `.pulling` →
        // `.ready` so the in-progress notice shows up automatically. The
        // installer owns the missing-check (it re-reads /api/tags) so a
        // non-tier pin like qwen2.5:3b-instruct is pulled too — duplicating
        // a tier-only guard here would strand that case.
        await ollamaInstaller.verifyAndPullMissing(preferredModel: settings.ollamaModel)
    }

    /// app version: a UserDefaults flag (`speakerAttribution.retroScan.<v>`)
    /// keeps it from firing on every launch. Walks completed meetings that
    /// still contain "Speaker N" labels and re-runs attribution against the
    /// improved fuzzy matcher + auto-mic mapping. Yields between meetings to
    /// stay polite about CPU.
    func runRetroactiveSpeakerAttributionIfNeeded() {
        // Bump the version suffix every time the attribution logic itself
        // changes meaningfully (system-cluster fallback in 3.4.2, model
        // escalation in 3.4.2, etc.) so existing meetings get re-scanned with
        // the improved code path on first launch of the new version.
        let key = "speakerAttribution.retroScan.v3.4.2"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        // Run on the main actor — `rerunSpeakerAttribution` and the helpers it
        // touches (Logger, NSFullUserName, ollamaService) are all MainActor.
        Task { [weak self] in
            guard let self else { return }
            let meetingIds: [String] = (try? await AppDatabase.shared.writer.read { db in
                let sql = """
                    SELECT DISTINCT t.meetingId
                    FROM transcript t
                    WHERE t.speakerLabel LIKE 'Speaker %'
                    """
                return try String.fetchAll(db, sql: sql)
            }) ?? []
            self.fileLog("RetroScan: found \(meetingIds.count) meetings with unmatched Speaker N labels")
            for id in meetingIds {
                await self.rerunSpeakerAttribution(for: id)
                try? await Task.sleep(for: .milliseconds(150))  // be polite to the LLM
            }
            UserDefaults.standard.set(true, forKey: key)
            self.loadMeetings()
            self.fileLog("RetroScan: complete")
        }
    }

    /// Returns a closure that synthesises pre-meeting briefs via Claude or
    /// Ollama, picking the same backend the user's summaries use. Returns nil
    /// when no AI backend is available — the contextEnrichment task will then
    /// just cache the structured related-meetings list without a prose brief.
    private func makeContextBriefSynthesizer() -> ((String, String) async throws -> String)? {
        let claudeKey = (try? KeychainHelper.loadString(forKey: KeychainHelper.Key.claudeAPIKey)) ?? nil
        let hasClaudeKey = (claudeKey ?? "").isEmpty == false
        let useLocal = settings.useLocalLLM
        let claudeModel = settings.claudeModel
        let ollamaModel = settings.ollamaModel
        let ollama = ollamaService

        if useLocal || !hasClaudeKey {
            // Ollama path — only return a synthesizer if we can actually reach it.
            return { [weak ollama] systemPrompt, userPrompt in
                guard let ollama else {
                    throw TaskQueueError.noHandler("Ollama service unavailable")
                }
                await ollama.refreshStatus()
                guard ollama.isReachable else {
                    throw TaskQueueError.noHandler("Ollama not reachable")
                }
                return try await ollama.generate(
                    systemPrompt: systemPrompt,
                    userPrompt: userPrompt,
                    model: ollamaModel
                )
            }
        }

        if hasClaudeKey {
            return { systemPrompt, userPrompt in
                let claude = ClaudeService()
                return try await claude.sendMessage(
                    systemPrompt: systemPrompt,
                    userPrompt: userPrompt,
                    model: claudeModel
                )
            }
        }

        return nil
    }

    /// TASK-070: a STYLE CALIBRATION appendix built from the user's own
    /// summary edits — the 2 most recent (AI original → user-edited) pairs,
    /// clipped to ~600 tokens per side. The model is told to copy the
    /// user's STYLE (structure, ordering, tone), never their content.
    ///
    /// Budget honesty (ADR-015): on the 16 GB local baseline the examples
    /// compete with the transcript for context, so the Ollama path only
    /// injects when the user prompt is small (~6K tokens). Claude has a
    /// 200K window — always fits.
    private func summaryStyleExamplesSection(
        excluding meetingId: String,
        backend: AIBackendChoice,
        userPromptChars: Int
    ) async -> String {
        let defaults = UserDefaults.standard
        let enabled = defaults.object(forKey: "summary.learnFromEdits") as? Bool ?? true
        guard enabled else { return "" }
        if case .ollama = backend, userPromptChars > 24_000 {
            fileLog("TaskQueue: style examples skipped — prompt too large for local context (\(userPromptChars) chars)")
            return ""
        }
        let examples = (try? await summaryRepository.recentEditedExamples(excluding: meetingId)) ?? []
        guard !examples.isEmpty else { return "" }

        // Plan cap: ≤600 tokens per example — ~1,200 chars per side.
        func clip(_ s: String) -> String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.count <= 1_200 ? t : String(t.prefix(1_200)) + "\n[…]"
        }
        let blocks = examples.enumerated().compactMap { i, ex -> String? in
            guard let original = ex.originalText, !original.isEmpty else { return nil }
            return """
            Example \(i + 1) — the model originally wrote:
            <model_version>
            \(clip(original))
            </model_version>
            The user rewrote it as:
            <user_version>
            \(clip(ex.summaryText))
            </user_version>
            """
        }
        guard !blocks.isEmpty else { return "" }
        fileLog("TaskQueue: injecting \(blocks.count) style example(s) into summary prompt")
        return """


        STYLE CALIBRATION — this user edits summaries into a preferred shape. \
        Below are real before/after pairs from their past edits. Write the NEW \
        summary in the user's demonstrated style directly (structure, section \
        ordering, tone, level of detail) so they don't have to re-edit. Copy \
        ONLY the style — the content must come from this meeting's transcript \
        and notes.

        \(blocks.joined(separator: "\n\n"))
        """
    }

    /// P5-T02: Loads open action items for a set of prior meetings, preserving order.
    /// Used by the summary prompt to carry forward unfinished items across a series.
    private func fetchOpenActionItems(for meetings: [Meeting]) async -> [(Meeting, [TaskItem])] {
        let repo = TaskRepository(database: database)
        var result: [(Meeting, [TaskItem])] = []
        for m in meetings {
            // Gated to accepted, non-deleted items so inbox suggestions never
            // leak into the series carry-forward prompt (PRJ-013).
            let items = (try? await repo.acceptedItemsForMeeting(m.id)) ?? []
            let open = items.filter { !$0.isCompleted }
            if !open.isEmpty { result.append((m, open)) }
        }
        return result
    }

    /// - Stuck recordings WITHOUT audio → cancel (nothing to transcribe)
    /// - Stuck transcribing → re-run batch transcription if audio exists, else complete
    /// History hygiene (TASK-033): recordings that were attempted and
    /// produced nothing — no transcripts, no summary, no user notes — are
    /// debris: ambient captures attached to location calendar blocks, dead
    /// husk meetings, abandoned ad-hoc rows. Archive them (3-day grace so a
    /// fresh failure stays visible while the user might still retry it).
    /// User content is the hard line: anything with a note or summary stays.
    /// TASK-045: one sentinel task drains the un-embedded backlog through
    /// the serial queue at the lowest priority. Skips when the model isn't
    /// available, a backfill row is already queued, or nothing is missing.
    private func enqueueEmbeddingBackfillIfNeeded() async {
        guard embeddingService.isAvailable else { return }
        let queued = taskQueueManager.allTasks.contains {
            $0.type == .embedIndex && $0.meetingId == Self.embedBackfillSentinel && !$0.isTerminal
        }
        guard !queued else { return }
        let missing = (try? await database.writer.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM meeting m
                WHERE m.id IN (SELECT DISTINCT meetingId FROM transcript)
                  AND m.id NOT IN (SELECT DISTINCT meetingId FROM embedding WHERE meetingId IS NOT NULL)
                """) ?? 0
        }) ?? 0
        guard missing > 0 else { return }
        fileLog("EmbedIndex: \(missing) meeting(s) need semantic indexing — enqueueing backfill")
        await taskQueueManager.enqueue(type: .embedIndex, meetingId: Self.embedBackfillSentinel, priority: 9)
    }

    static let factBackfillSentinel = "__fact_backfill__"
    /// Meetings whose extraction legitimately produced zero facts — without
    /// this stamp they'd re-run on every backfill pass (the "has summary
    /// but no facts" filter can't tell empty from unprocessed).
    static let factBackfillDoneKey = "factBackfill.processedMeetingIds"

    /// TASK-063: one sentinel row extracts insights from every summarized
    /// meeting that has no facts yet — full extraction per meeting, anchors
    /// included (review M7), through `extractInsightsBestEffort`.
    private func enqueueFactBackfillIfNeeded() async {
        guard isAIWorkConfigured else { return }
        let queued = taskQueueManager.allTasks.contains {
            $0.type == .factBackfill && !$0.isTerminal
        }
        guard !queued else { return }
        let candidates = await factBackfillCandidates()
        guard !candidates.isEmpty else { return }
        fileLog("FactBackfill: \(candidates.count) summarized meeting(s) lack insights — enqueueing")
        await taskQueueManager.enqueue(type: .factBackfill, meetingId: Self.factBackfillSentinel, priority: 9)
    }

    private func factBackfillCandidates() async -> [String] {
        let done = Set(UserDefaults.standard.stringArray(forKey: Self.factBackfillDoneKey) ?? [])
        let ids = (try? await database.writer.read { db in
            try String.fetchAll(db, sql: """
                SELECT DISTINCT s.meetingId FROM meetingSummary s
                WHERE s.meetingId NOT IN (SELECT DISTINCT meetingId FROM entityFact)
                """)
        }) ?? []
        return ids.filter { !done.contains($0) }
    }

    private func runFactBackfill() async throws {
        let candidates = await factBackfillCandidates()
        guard !candidates.isEmpty else { return }
        var done = Set(UserDefaults.standard.stringArray(forKey: Self.factBackfillDoneKey) ?? [])
        var processed = 0
        for meetingId in candidates {
            if Task.isCancelled { break }
            await extractInsightsBestEffort(meetingId: meetingId)
            // Stamp regardless of fact count — zero facts is a valid result,
            // and a real failure logs and gets another chance only when the
            // user regenerates the summary.
            done.insert(meetingId)
            processed += 1
            UserDefaults.standard.set(Array(done), forKey: Self.factBackfillDoneKey)
            taskQueueManager.reportCurrentProgress(stage: "Extracting insights (\(processed)/\(candidates.count))")
        }
        fileLog("FactBackfill: processed \(processed)/\(candidates.count) meeting(s)")
    }

    private func archiveEmptyDebrisMeetings() async {
        do {
            let archived = try await database.writer.write { db -> Int in
                try db.execute(sql: """
                    UPDATE meeting SET status = ?, updatedAt = ?
                    WHERE status = ?
                      AND transcriptionAttemptedAt IS NOT NULL
                      AND startDate < ?
                      AND id NOT IN (SELECT DISTINCT meetingId FROM transcript)
                      AND id NOT IN (SELECT DISTINCT meetingId FROM meetingSummary)
                      AND id NOT IN (SELECT DISTINCT meetingId FROM meetingNote
                                     WHERE TRIM(COALESCE(content, '')) != '')
                    """, arguments: [
                        MeetingStatus.archived.rawValue,
                        Date(),
                        MeetingStatus.complete.rawValue,
                        Date().addingTimeInterval(-3 * 86_400)
                    ])
                return db.changesCount
            }
            if archived > 0 {
                fileLog("History hygiene: archived \(archived) empty attempted recording(s)")
                loadMeetings()
            }
        } catch {
            fileLog("History hygiene sweep failed: \(error.localizedDescription)")
        }
    }

    private func cleanupStuckMeetings() {
        Task {
            await archiveEmptyDebrisMeetings()
            await enqueueEmbeddingBackfillIfNeeded()
            do {
                // Gather stuck meetings inside a write transaction
                // Returns the UPDATED meeting objects (with corrected statuses)
                let (recoveredForTranscription, stuckTranscribing) = try await database.writer.write { db -> ([Meeting], [Meeting]) in
                    let recordings = try Meeting
                        .filter(Meeting.Columns.status == MeetingStatus.recording.rawValue)
                        .fetchAll(db)
                    var toTranscribe: [Meeting] = []
                    for var m in recordings {
                        m.endDate = m.endDate ?? Date()
                        func deleteWithSibling(_ path: String) {
                            try? FileManager.default.removeItem(atPath: path)
                            try? FileManager.default.removeItem(
                                at: AudioBufferManager.systemAudioURL(for: URL(fileURLWithPath: path)))
                        }
                        let (usable, husks) = Self.partitionUsableAudioPaths(m.audioFilePaths) { path in
                            guard FileManager.default.fileExists(atPath: path),
                                  let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
                            return attrs[.size] as? Int
                        }
                        for husk in husks { deleteWithSibling(husk) }
                        if !usable.isEmpty {
                            // Keep the good sessions, drop only husk entries —
                            // a multi-file meeting whose LAST session died must
                            // not lose its earlier good audio.
                            m.audioFilePaths = usable
                            m.status = .transcribing
                            try m.update(db)
                            toTranscribe.append(m)
                        } else {
                            // No usable audio anywhere — reset so the user can
                            // re-record. A dead husk left in audioFilePaths
                            // becomes `.first` after a re-record appends a real
                            // session, and transcription would resolve the husk
                            // instead of the audio.
                            m.audioFilePaths = []
                            m.status = .scheduled
                            m.endDate = nil
                            try m.update(db)
                        }
                    }

                    let transcribing = try Meeting
                        .filter(Meeting.Columns.status == MeetingStatus.transcribing.rawValue)
                        .fetchAll(db)

                    return (toTranscribe, transcribing)
                }

                let total = recoveredForTranscription.count + stuckTranscribing.count
                if total > 0 {
                    fileLog("Startup cleanup: found \(total) stuck meetings — \(recoveredForTranscription.count) recovered recordings, \(stuckTranscribing.count) stuck transcribing")
                    loadMeetings()
                }

                // ── Enqueue stuck meetings into the persistent task queue ──
                // The TaskQueueManager handles model loading, retries, and crash recovery.
                // No inline batchTranscribe() — everything goes through the queue.

                var seen = Set<String>()
                var enqueued = 0
                for m in recoveredForTranscription + stuckTranscribing {
                    guard seen.insert(m.id).inserted else { continue }

                    // Only enqueue if the meeting has a real audio file
                    if let path = m.audioFilePath,
                       FileManager.default.fileExists(atPath: path) {
                        await taskQueueManager.enqueue(type: .transcription, meetingId: m.id, priority: 2)
                        enqueued += 1
                    } else {
                        // No audio — mark complete directly
                        try? await database.writer.write { db in
                            var meeting = m
                            meeting.status = .complete
                            try meeting.update(db)
                        }
                    }
                }

                if enqueued > 0 {
                    fileLog("Startup cleanup: enqueued \(enqueued) meetings for transcription via task queue")
                    loadMeetings()
                }

                // Drain any legacy UserDefaults-based pending transcriptions
                if transcriptionService.isModelLoaded {
                    await processPendingTranscriptions()
                }
            } catch {
                Logger.general.error("Startup cleanup failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Meeting Creation

    /// Serialization flag — prevents concurrent meeting-start attempts from racing.
    /// The state machine's `currentMeeting == nil` guard is necessary but not sufficient
    /// because multiple async Tasks can read it as nil before any of them set it.
    /// `private(set)` so the sidebar can show a "Starting recording…" banner while a
    /// start is in flight; the audio stack takes 1–3 s to come up and otherwise the
    /// recording UI appears with no preceding feedback.
    private(set) var isStartingMeeting = false

    /// Mirror of `isStartingMeeting` for the stop side — user Stop, silence
    /// auto-stop, and the ⌘-shortcut notification can race.
    private var isStoppingMeeting = false

    /// Bundle identifier of the call app that triggered the current
    /// detector-started recording. The `.callAppTerminated` auto-stop only
    /// fires when THIS app terminates — Teams self-updating in the background
    /// must not kill a Zoom recording.
    private var autoRecordTriggerBundleId: String?

    /// Last instant the system (remote) audio level was above the noise
    /// floor. Used as a keep-alive for browser-call end detection: while
    /// recording, the mic-usage probe is suppressed and title probes go
    /// blind when the meeting tab is minimized or backgrounded — but a live
    /// call keeps producing remote audio.
    private var lastActiveSystemAudioAt: Date?

    /// Create an ad-hoc meeting and start recording. Called from the sidebar "New Meeting"
    /// button, menu bar, Home view, and the `.createNewMeeting` notification observer.
    ///
    /// Behaviour:
    /// 1. Switches `sidebarDestination` to `.meetings` synchronously for immediate visual feedback.
    /// 2. If a scheduled meeting starts within ±5 minutes, records against that one instead of
    ///    creating a duplicate ad-hoc entry.
    /// 3. After recording starts, sets `focusTitleForRename` so the meeting view auto-focuses
    ///    the title field for easy rename (ad-hoc meetings only).
    /// 4. Surfaces guard-rail failures (already recording, start in progress) as `lastUserError`
    ///    so the user gets a visible alert instead of a silent no-op.
    /// P4-T01: Cycle to the previous (-1) or next (+1) meeting in the currently sorted
    /// list. No-op if no meeting is selected or the list is empty. Used by the
    /// ⌘[ / ⌘] keyboard shortcuts in MeetingDetailView.
    @MainActor
    func selectAdjacentMeeting(direction: Int) {
        let sorted = meetings.sorted {
            ($0.scheduledStartDate ?? $0.startDate ?? .distantPast)
                > ($1.scheduledStartDate ?? $1.startDate ?? .distantPast)
        }
        guard !sorted.isEmpty else { return }
        guard let currentId = selectedMeetingId,
              let idx = sorted.firstIndex(where: { $0.id == currentId }) else {
            // No selection → land on the first meeting.
            selectedMeetingId = sorted.first?.id
            return
        }
        let newIdx = max(0, min(sorted.count - 1, idx + direction))
        guard newIdx != idx else { return }
        selectedMeetingId = sorted[newIdx].id
    }

    @MainActor
    /// Quick voice memo (TASK-052): mic-only capture into a normal meeting
    /// row (templateId "memo") that runs the FULL standard pipeline —
    /// transcript, summary, action items, embedding (review M7: extraction
    /// lives inside the summary handler, so skipping summaries would skip
    /// items too). Never re-attaches to calendar meetings.
    /// Catch-me-up (TASK-053): on-demand only. Transcribes the last ~3
    /// minutes from the live ring with the already-loaded WhisperKit and
    /// summarizes with the already-RESIDENT qwen3 (never force-loads a
    /// second model mid-recording — review B2). Returns nil with a reason
    /// in lastUserError when preconditions fail.
    // EXEMPT: user-driven, modal-scoped result — not post-meeting pipeline work.
    func catchMeUp() async -> String? {
        guard isRecording else { return nil }
        guard transcriptionService.isModelLoaded, !transcriptionService.isTranscribing else {
            lastUserError = "Transcription is busy — try again in a moment."
            return nil
        }
        guard !taskQueueManager.isProcessing else {
            lastUserError = "AI is finishing the previous meeting — try again shortly."
            return nil
        }
        let samples = audioCaptureService.catchUpSnapshot(seconds: 180)
        guard samples.count > 16_000 * 10 else {
            lastUserError = "Not enough audio yet — give it a minute."
            return nil
        }
        do {
            let segments = try await transcriptionService.transcribe(samples: samples)
            let text = segments.map(\.text).joined(separator: " ")
            guard text.count > 40 else { return "Mostly silence in the last few minutes." }
            guard let model = await ollamaService.residentQwen3() else {
                lastUserError = "No local model available for the recap."
                return nil
            }
            let recap = try await ollamaService.generate(
                systemPrompt: "Summarize the last few minutes of a live meeting in at most 5 short bullets. Plain language, names when stated, no preamble.",
                userPrompt: text,
                model: model,
                maxOutputTokens: 400
            )
            // One semantic connection when the index has one (best-effort).
            var connection = ""
            if let hit = try? await embeddingService.topK(query: String(text.prefix(800)), k: 1,
                                                          sourceTypes: ["summary"]).first,
               let mid = hit.meetingId, hit.score > 0.55,
               let related = try? await meetingRepository.find(id: mid), related.id != activeMeeting?.id {
                connection = "\n\n_Relates to: \(related.title) (\(related.effectiveDate.formatted(date: .abbreviated, time: .omitted)))_"
            }
            return recap + connection
        } catch {
            lastUserError = "Catch-up failed: \(error.localizedDescription)"
            return nil
        }
    }

    /// TASK-054: build a reversible PII redactor from the People directory
    /// + a scan of the outgoing text, when the privacy toggle is on.
    /// Attribution and title calls deliberately never use this.
    func cloudRedactorIfEnabled(texts: [String]) async -> PIIRedactor? {
        guard PIIRedactor.isEnabled else { return nil }
        let persons = (try? await PersonRepository(database: AppDatabase.shared).allPersons()) ?? []
        var known: [String] = []
        for p in persons {
            known.append(p.canonicalName)
            known.append(contentsOf: p.aliases)
        }
        let redactor = PIIRedactor.build(knownNames: known, texts: texts)
        return redactor.isEmpty ? nil : redactor
    }

    /// TASK-072: show the "looks like you left" prompt and arm the
    /// grace-period auto-end. No-ops while suppressed ("I'm still here"),
    /// already prompting, or not recording.
    private func beginDepartureConfirmation() {
        guard isRecording, departurePrompt == nil else { return }
        if let until = departureSuppressedUntil, until > Date() { return }
        let title = activeMeeting?.title ?? "this meeting"
        departurePrompt = DeparturePrompt(meetingTitle: title, firedAt: Date())
        fileLog("Departure: call ended while manually recording '\(title)' — confirming (auto-end in \(Int(Self.departureGraceSeconds))s)")
        departureAutoEndTask?.cancel()
        departureAutoEndTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.departureGraceSeconds))
            guard !Task.isCancelled, let self, self.isRecording, self.departurePrompt != nil else { return }
            self.fileLog("Departure: grace expired — auto-ending recording")
            self.departurePrompt = nil
            self.stopRecording()
        }
    }

    /// User confirmed they're still in the meeting — clear the prompt and
    /// suppress re-prompts for 10 minutes (detector flaps shouldn't nag).
    func dismissDeparturePrompt(stillHere: Bool) {
        departureAutoEndTask?.cancel()
        departureAutoEndTask = nil
        departurePrompt = nil
        if stillHere {
            departureSuppressedUntil = Date().addingTimeInterval(600)
            fileLog("Departure: user is still in the meeting — suppressing prompts for 10 min")
        } else {
            fileLog("Departure: user confirmed end")
            stopRecording()
        }
    }

    /// A call is live again — cancel any pending departure prompt.
    func cancelDeparturePromptOnCallActivity() {
        guard departurePrompt != nil else { return }
        departureAutoEndTask?.cancel()
        departureAutoEndTask = nil
        departurePrompt = nil
        fileLog("Departure: call activity resumed — prompt cancelled")
    }

    func startQuickMemo() {
        guard !isRecording else {
            lastUserError = "A recording is already running. Stop it before starting a memo."
            return
        }
        guard !isStartingMeeting else { return }
        isStartingMeeting = true
        sidebarDestination = .meetings
        fileLog("startQuickMemo invoked")
        Task { @MainActor in
            defer { self.isStartingMeeting = false }
            do {
                self.audioCaptureService.nextCaptureSkipsSystemAudio = true
                let title = "Memo — \(Date().formatted(date: .abbreviated, time: .shortened))"
                var meeting = try await self.stateMachine.createAndStartMeeting(title: title)
                meeting.templateId = "memo"
                try? await self.meetingRepository.save(&meeting)
                await self.wireActiveRecordingSession()
                self.selectedMeetingId = meeting.id
                self.loadMeetings()
            } catch {
                self.audioCaptureService.nextCaptureSkipsSystemAudio = false
                self.lastUserError = "Couldn't start the memo: \(error.localizedDescription)"
            }
        }
    }

    func startNewMeeting() {
        guard !isRecording else {
            lastUserError = "A meeting is already recording. Stop it before starting a new one."
            fileLog("startNewMeeting: skipped — already recording")
            return
        }
        guard !isStartingMeeting else {
            fileLog("startNewMeeting: skipped — another start in progress (debounce)")
            return
        }

        // Flip the detail pane immediately so the user sees *something* change even before
        // audio services spin up.
        sidebarDestination = .meetings
        isStartingMeeting = true
        fileLog("startNewMeeting invoked")

        Task { @MainActor in
            defer { self.isStartingMeeting = false }
            do {
                // A restart during a still-active meeting must re-attach to
                // the meeting it belongs to — not to whatever calendar block
                // happens to be "current" (TASK-032: a 1:1's real transcript
                // landed on an untitled focus-time event because the 1:1 was
                // already complete and its scheduled window had passed).
                // Reopenable = complete + inside its scheduled window (+1 h
                // grace), so this appends a session to the original meeting,
                // keeping series history, prep, and the RSVP attendee gate.
                if let reopenable = try await self.bestReopenableMeeting() {
                    self.fileLog("startNewMeeting: re-attaching to reopenable '\(reopenable.title)' — appending a session")
                    self.isStartingMeeting = false   // reopenRecording has its own debounce
                    self.reopenRecording(for: reopenable)
                    self.selectedMeetingId = reopenable.id
                    self.loadMeetings()
                    return
                }

                let nearby = try await self.meetingRepository.meetingsNearDate(Date(), windowMinutes: 5)
                let scheduledMatch = nearby.first(where: { Self.isRecordableCalendarMatch($0) })

                let meeting: Meeting
                let isAdHoc: Bool
                if let scheduled = scheduledMatch {
                    self.fileLog("startNewMeeting: matched scheduled '\(scheduled.title)' — starting it")
                    try await self.stateMachine.startRecording(meeting: scheduled)
                    meeting = self.stateMachine.currentMeeting ?? scheduled
                    isAdHoc = false
                } else {
                    meeting = try await self.stateMachine.createAndStartMeeting(title: "New Meeting")
                    isAdHoc = true
                }

                await self.wireActiveRecordingSession()
                self.selectedMeetingId = meeting.id
                self.fileLog("Meeting started: \(meeting.id) ('\(meeting.title)')")
                self.loadMeetings()

                // Only auto-focus the title when the meeting was created ad-hoc; for a scheduled
                // meeting we want to keep the calendar-provided title as-is.
                if isAdHoc {
                    self.focusTitleForRename = true
                }
            } catch {
                Logger.general.error("Failed to start meeting: \(error.localizedDescription)")
                self.lastUserError = "Couldn't start recording: \(error.localizedDescription)"
            }
        }
    }

    /// A scheduled meeting that a fresh recording should attach to. Filters
    /// out location/availability calendar blocks ("Home" work-location
    /// events, untitled focus time): an event with no attendees AND no
    /// meeting link isn't a meeting, and attaching ambient recordings to
    /// them filled the history list with debris rows (TASK-033).
    nonisolated static func isRecordableCalendarMatch(_ meeting: Meeting) -> Bool {
        guard meeting.status == .scheduled || meeting.status == .notified else { return false }
        guard !meeting.isAllDay else { return false }
        let hasParticipants = !(meeting.participants ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        let hasLink = !(meeting.meetLink ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        return hasParticipants || hasLink
    }

    /// The most recently ended meeting that can still be reopened (complete,
    /// inside its scheduled window + 1 h grace — see Meeting.isReopenable).
    /// Used by the record-start choosers so a mid-meeting restart appends to
    /// the original meeting instead of spawning a new row.
    private func bestReopenableMeeting() async throws -> Meeting? {
        let candidates = try await database.writer.read { db in
            try Meeting
                .filter(Meeting.Columns.status == MeetingStatus.complete.rawValue)
                .order(Meeting.Columns.endDate.desc)
                .limit(12)
                .fetchAll(db)
        }
        return candidates.first(where: { $0.isReopenable && !$0.isAllDay })
    }

    func createMeeting(title: String, scheduledStart: Date? = nil, scheduledEnd: Date? = nil) async throws -> Meeting {
        var meeting = Meeting(
            title: title,
            scheduledStartDate: scheduledStart,
            scheduledEndDate: scheduledEnd,
            status: scheduledStart != nil ? .scheduled : .recording
        )

        if scheduledStart == nil {
            meeting.startDate = Date()
        }

        try await meetingRepository.save(&meeting)
        loadMeetings()
        return meeting
    }

    /// Debounce an in-app mic-picker change, then apply it to the live recording.
    /// 400ms coalesces picker scrubbing; the capture service coalesces again at the
    /// engine level. Passing the override-resolved UID (nil when the override is
    /// off) means toggling the override off mid-meeting switches back to auto.
    private func scheduleMicSwitch() {
        micSwitchDebounceTask?.cancel()
        micSwitchDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self, self.isRecording else { return }
            let uid = self.audioCaptureService.preferredInputDeviceIDProvider?()
            await self.audioCaptureService.switchMicrophone(toUID: uid)
        }
    }

    /// Start recording — delegates to the state machine. No live transcription needed —
    /// we transcribe the complete recording after the meeting ends for much better accuracy.
    func startRecording(for meeting: Meeting) {
        guard !isRecording else {
            Logger.general.info("startRecording(for:) skipped — already recording")
            return
        }
        guard !isStartingMeeting else {
            Logger.general.info("startRecording(for:) skipped — another start in progress")
            return
        }
        isStartingMeeting = true
        Task {
            defer { self.isStartingMeeting = false }
            do {
                try await stateMachine.startRecording(meeting: meeting)
                await self.wireActiveRecordingSession()
                self.detectedCallApp = nil

                // One last attempt to refresh the pre-meeting brief now
                // that the meeting is actually starting. If the previous
                // attempt couldn't synthesize a brief (e.g. AI was offline,
                // KB folder hadn't indexed yet, related meetings were just
                // added), this catches it. Replaces the placeholder brief
                // when real content can now be produced. Runs in the
                // background — recording is already underway.
                Task.detached { [weak self] in
                    await self?.refreshContextForMeetingStart(meetingId: meeting.id)
                }

                loadMeetings()
                fileLog("Recording started for meeting \(self.stateMachine.currentMeeting?.id ?? "?")")
                // TASK-080: optional video capture — no-op unless the user
                // opted in (off by default); fail-safe, never touches audio.
                // Detached so the start path doesn't block on SCShareableContent/
                // startCapture; safe because start() now guards on lifecycle and
                // awaits any in-flight teardown (C1).
                if let mid = self.stateMachine.currentMeeting?.id {
                    Task { await VideoCaptureService.shared.start(meetingId: mid) }
                }
            } catch {
                Logger.general.error("Failed to start recording: \(error.localizedDescription)")
                self.lastUserError = error.localizedDescription
            }
        }
    }

    /// Per-recording wiring shared by EVERY start path — manual, ad-hoc
    /// (`startNewMeeting`), auto-record (`handleCallDetected`), reopen, and
    /// the `.startRecording` notification. Historically only
    /// `startRecording(for:)` did this, so auto-recorded meetings never got
    /// write-error surfacing, the Apple Speech fallback, or screen-based
    /// participant detection.
    private func wireActiveRecordingSession() async {
        guard let current = stateMachine.currentMeeting else { return }

        self.activeMeeting = current
        self.isRecording = stateMachine.isRecording
        self.selectedMeetingId = current.id
        if self.isRecording { self.startAudioLevelPolling() }

        // Warm the transcription model during the meeting so it's ready the
        // moment recording stops (no-op when already loaded; the idle-unload
        // policy makes "unloaded" a normal steady state).
        autoLoadTranscriptionModel()

        // Surface audio write errors to the user (e.g. disk full)
        self.audioCaptureService.onWriteError = { [weak self] error in
            Task { @MainActor [weak self] in
                self?.lastUserError = "Audio write error: \(error.localizedDescription). Recording may be incomplete."
            }
        }

        // Surface a non-fatal warning when the preferred recording location
        // wasn't writable and capture fell back to a temporary folder.
        self.audioCaptureService.onStorageWarning = { [weak self] message in
            Task { @MainActor [weak self] in
                self?.lastUserError = message
            }
        }

        // Wire Apple Speech fallback if WhisperKit is unavailable.
        // SFSpeechRecognizer produces nothing until the user grants
        // Speech access, so request it before starting the recognizer.
        if self.transcriptionService.transcriptionMode == .appleSpeech {
            if await AppleSpeechSupport.ensureAuthorized() {
                self.audioCaptureService.onRawMicBuffer = { [weak self] buffer in
                    self?.appleSpeechTranscriber.appendBuffer(buffer)
                }
                self.appleSpeechTranscriber.start(meetingId: current.id, repository: self.transcriptRepository)
                self.fileLog("Apple Speech fallback wired for meeting \(current.id)")
            } else {
                self.lastUserError = "Speech Recognition access is off. Live transcription is unavailable until you enable it in System Settings → Privacy & Security → Speech Recognition."
                self.fileLog("Apple Speech fallback: Speech authorization denied")
            }
        }

        // Start participant detection if calendar didn't provide attendees.
        // Calendar attendees are written to meeting.participants during sync;
        // if still empty here, fall back to screen/window title detection.
        // Defensive stop: if a prior stop's Task errored before its teardown
        // lines ran, the old service's 30s poll timer would leak for the app
        // lifetime and stack with this one.
        self.participantDetectionService?.stop()
        let service = ParticipantDetectionService(
            meetingRepository: self.meetingRepository,
            database: self.database
        )
        self.participantDetectionService = service
        service.start(meetingId: current.id, existingParticipants: current.participantList)

        // Resolve template: use meeting's own templateId, or inherit from series.
        self.activeTemplate = await self.resolveTemplate(for: current)
    }

    /// Resolves the template for a meeting:
    /// 1. If the meeting has a templateId, load that template.
    /// 2. Otherwise, check the series (same title) for a recently-used template.
    /// Returns nil if no template is found or loading fails.
    private func resolveTemplate(for meeting: Meeting) async -> MeetingTemplate? {
        let templateRepo = MeetingTemplateRepository(database: database)

        // 1. Explicit templateId on the meeting
        if let templateId = meeting.templateId {
            return try? await templateRepo.find(id: templateId)
        }

        // 2. Inherit from the most recent meeting in the same series
        if let inheritedId = try? await meetingRepository.templateIdForSeries(title: meeting.title) {
            return try? await templateRepo.find(id: inheritedId)
        }

        return nil
    }

    /// Re-open a completed meeting to append more audio.
    ///
    /// Creates a new audio capture session; the resulting audio file is appended
    /// to `meeting.audioFilePaths`. Transcript segments from this session are
    /// saved with the same `meetingId` and appended to the existing transcript.
    func reopenRecording(for meeting: Meeting) {
        guard !isRecording else {
            Logger.general.info("reopenRecording(for:) skipped — already recording")
            return
        }
        guard !isStartingMeeting else {
            Logger.general.info("reopenRecording(for:) skipped — another start in progress")
            return
        }
        isStartingMeeting = true
        Task {
            defer { self.isStartingMeeting = false }
            do {
                try await stateMachine.reopenRecording(meeting: meeting)
                await self.wireActiveRecordingSession()
                self.isReopening = true
                loadMeetings()
                fileLog("Reopen recording started for meeting \(self.stateMachine.currentMeeting?.id ?? "?")")
            } catch {
                Logger.general.error("Failed to reopen recording: \(error.localizedDescription)")
                self.lastUserError = error.localizedDescription
            }
        }
    }

    /// Start or reopen a meeting depending on its current state and the time window.
    ///
    /// - If the meeting is complete and `isReopenable`, appends (no confirmation needed).
    /// - Otherwise starts a fresh recording.
    func startOrReopenRecording(for meeting: Meeting) {
        if meeting.isReopenable {
            reopenRecording(for: meeting)
        } else {
            startRecording(for: meeting)
        }
    }

    /// Stop the current recording and start a new one for `meeting`.
    /// Drives the "Switch meetings" banner — opens the new meet link and
    /// kicks off recording in one user-visible step. Idempotent: if no
    /// recording is active, just starts the new one.
    func switchActiveMeeting(to meeting: Meeting) async {
        fileLog("Switch: switching active meeting to '\(meeting.title)' (was '\(activeMeeting?.title ?? "none")')")

        // Clear pending state up front so the banner dismisses immediately.
        pendingSwitchMeetingId = nil
        NotificationCenter.default.post(name: .meetingSwitchDismiss, object: nil)

        if isRecording {
            stopRecording()
            // Wait for the state machine to actually flip isRecording=false
            // before starting the new one. stopRecording is fire-and-forget
            // (an internal Task), so poll briefly. 3s upper bound — if it
            // hasn't flipped by then something else is wrong.
            let deadline = Date().addingTimeInterval(3)
            while isRecording && Date() < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }

        if let link = meeting.meetLink, !link.isEmpty, let url = URL(string: link) {
            NSWorkspace.shared.open(url)
        }
        startRecording(for: meeting)
    }

    /// Stop recording — then run batch transcription on the complete audio file.
    /// Batch transcription is dramatically more accurate than live streaming because
    /// Whisper can use the full audio context and sequential decoding.
    ///
    /// IMPORTANT: State updates and notifications fire IMMEDIATELY so the UI and
    /// menu bar reflect the correct state. Batch transcription runs in a separate
    /// detached task so it never interferes with a subsequent recording.
    func stopRecording() {
        // Serialize: user Stop, silence auto-stop, capacity auto-stop, and the
        // ⌘-shortcut notification can all fire near-simultaneously. A second
        // stateMachine.stopRecording() throws noActiveMeeting, which used to
        // surface as a spurious user-facing alert.
        guard !isStoppingMeeting else { return }
        isStoppingMeeting = true
        // TASK-080: finalize any video capture (no-op when off). Synchronous
        // trigger creates the teardown handle on the main actor *now* so a
        // back-to-back meeting's start() can observe and await it (the actual
        // teardown still runs off the synchronous path, so the UI isn't blocked).
        VideoCaptureService.shared.beginStop(database: database)
        // Recording end is a governor re-evaluation point (TASK-055):
        // background work deferred during capture can run again.
        taskQueueManager.reevaluate()
        departureAutoEndTask?.cancel()
        departureAutoEndTask = nil
        departurePrompt = nil
        departureSuppressedUntil = nil

        // Warn user if transcription model isn't ready yet
        if !transcriptionService.isModelLoaded {
            lastUserError = "The transcription model is still downloading. Your audio has been saved and will be transcribed once the download completes."
        }

        Task {
            defer { self.isStoppingMeeting = false }
            do {
                // Save references before stopRecording clears them
                let stoppedMeeting = stateMachine.currentMeeting
                let stoppedMeetingId = stoppedMeeting?.id
                let audioURL = audioCaptureService.currentAudioFileURL

                try await stateMachine.stopRecording()
                self.activeMeeting = self.stateMachine.currentMeeting
                self.isRecording = self.stateMachine.isRecording
                self.recordingStartedByDetector = false
                self.autoRecordTriggerBundleId = nil
                self.isReopening = false
                self.stopAudioLevelPolling()

                // Teardown Apple Speech fallback if it was active
                self.audioCaptureService.onRawMicBuffer = nil
                if self.appleSpeechTranscriber.isActive {
                    self.appleSpeechTranscriber.stop()
                }

                // Stop participant detection
                self.participantDetectionService?.stop()
                self.participantDetectionService = nil

                // ── Immediate: UI + notifications (fire NOW, not after transcription) ──

                NotificationCenter.default.post(name: .stopRecording, object: nil)
                self.sendMeetingEndedNotification(meetingTitle: stoppedMeeting?.title)
                loadMeetings()

                // ── Enqueue transcription via persistent task queue ──
                // The task queue handles retries, crash recovery, and auto-enqueues
                // a summary task after transcription completes.

                if let meetingId = stoppedMeetingId {
                    self.fileLog("Meeting stopped. Enqueuing transcription for \(meetingId)")
                    await self.taskQueueManager.enqueue(
                        type: .transcription,
                        meetingId: meetingId,
                        priority: 0  // Highest priority — user is waiting
                    )
                }
            } catch {
                if case MeetingStateMachineError.noActiveMeeting = error {
                    // Benign: a concurrent stop already won. Nothing to surface.
                    Logger.general.info("stopRecording: no active meeting — already stopped")
                } else {
                    Logger.general.error("Failed to stop recording: \(error.localizedDescription)")
                    self.lastUserError = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Auto-Summary
    //
    // P2-T04: Summary generation fires IMMEDIATELY after transcription completes —
    // no delay, no separate user trigger. The flow is:
    //
    //   1. Recording stops → transcription task enqueued (priority 0).
    //   2. transcriptionHandler runs batchTranscribe(), commits transcripts,
    //      then awaits autoTitleIfNeeded() (P1-T06).
    //   3. TaskQueueManager.processLoop() observes the transcription task completed
    //      and immediately enqueues a summary task (priority 5) for the same meeting,
    //      provided segments exist. See TaskQueueManager.processLoop().
    //   4. summaryHandler invokes generateSummaryForTask, which is notes-anchored
    //      when the user captured notes during the meeting (P2-T03).
    //
    // Order is therefore: transcribe → auto-title → summary, with no artificial wait.
    // generateSummaryForTask is idempotent in the sense that the regeneration UI uses
    // the same code path; the queue itself dedupes pending summary tasks per meeting.

    /// Which hint family applies to the prepared diarization source. The hint
    /// values themselves are computed on the MainActor (they need
    /// googleAuthManager); the detached loader only reports which one to use.
    private enum BatchHintKind: Sendable { case systemOnly, mixed }

    /// Decoded + trimmed audio for one batch transcription run. Pure value
    /// type so it crosses from the detached loader back to the MainActor.
    private struct PreparedBatchAudio: Sendable {
        let samples: [Float]              // trimmed mixed (WhisperKit input)
        let diarizationSamples: [Float]   // trimmed system-only, or mixed fallback
        let diarizationSource: String
        let hintKind: BatchHintKind
        let trimOffsetSeconds: Double
        let rawSampleCount: Int
        let rawSeconds: Double
    }

    /// Decode both WAVs, silence-trim, and select the diarization source —
    /// the gigabyte-scale synchronous work of a batch run. nonisolated so it
    /// runs in a detached task instead of stalling the MainActor; the interim
    /// full-file copies also stay scoped to this frame instead of living
    /// across the whole transcription.
    ///
    /// Returns nil for refuse-to-transcribe conditions (wrong sample rate,
    /// unreadable buffer); throws only for AVAudioFile I/O errors so the
    /// task-queue retry path can engage.
    /// Meaningful audio in, zero transcript rows out. Thrown (rather than
    /// returning []) so the failure is VISIBLE — a failed task with a Retry
    /// button — instead of a meeting silently marked complete with an empty
    /// page (TASK-031). The relaunch drain drops these instead of re-running
    /// them forever: the result is deterministic until the user retries.
    struct TranscriptionEmptyResultError: LocalizedError {
        let rawSeconds: Double
        var errorDescription: String? {
            "Transcription produced no text from \(max(1, Int(rawSeconds / 60))) minute(s) of audio. "
            + "The recording may be mostly silence or very quiet — Retry runs it again."
        }
    }

    private nonisolated static func prepareBatchAudio(audioURL: URL) throws -> PreparedBatchAudio? {
        func log(_ msg: String) { AppFileLogger.shared.log(msg) }

        // Read the WAV file into Float32 samples
        let audioFile = try AVAudioFile(forReading: audioURL)
        let fileFormat = audioFile.processingFormat
        let frameCount = AVAudioFrameCount(audioFile.length)

        // A crash husk (header-only WAV) or a recording that died at spin-up
        // has zero frames. Reading into a zero-capacity buffer throws the
        // cryptic CoreAudio -50, the task retries forever, and every relaunch
        // resurrects a FAILED badge (TASK-031). Refuse instead: nil completes
        // without a retry storm and the pending-queue entry is dropped.
        guard frameCount > 0 else {
            log("Batch transcribe: \(audioURL.lastPathComponent) contains no audio frames (crash husk) — refusing to transcribe")
            Logger.transcription.error("Batch transcribe: zero-frame audio file \(audioURL.lastPathComponent) — refusing")
            return nil
        }

        // WhisperKit expects 16 kHz mono Float32. AudioCaptureService is
        // responsible for writing the WAV at that rate; if the upstream
        // capture ever changes, the model would silently get the wrong
        // audio (time-stretched transcripts, garbage segments). Bail out
        // explicitly instead, so the failure is loud.
        let expectedSampleRate: Double = 16_000
        guard fileFormat.sampleRate == expectedSampleRate else {
            log("Batch transcribe: unexpected sample rate \(fileFormat.sampleRate) Hz (expected \(expectedSampleRate)) — refusing to transcribe")
            Logger.transcription.error("Batch transcribe sample-rate mismatch for \(audioURL.lastPathComponent): \(fileFormat.sampleRate) Hz")
            return nil
        }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: frameCount) else {
            log("Batch transcribe: failed to create buffer")
            return nil
        }
        try audioFile.read(into: buffer)

        guard let channelData = buffer.floatChannelData else {
            log("Batch transcribe: no channel data")
            return nil
        }
        let allSamples = Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))
        let rawSampleCount = allSamples.count
        let rawSeconds = Double(rawSampleCount) / fileFormat.sampleRate

        // Trim leading and trailing silence to improve transcription quality.
        // WhisperKit hallucinates on long silent sections. Compute the
        // bounds once so we can apply the same window to the system-only
        // WAV below, keeping the diarization timeline aligned with the
        // WhisperKit timeline.
        let silenceThreshold: Float = 0.005
        let windowSize = Int(fileFormat.sampleRate) // 1-second windows
        let trimBounds = trimSilenceBounds(allSamples, threshold: silenceThreshold, windowSize: windowSize)
        let samples = Array(allSamples[trimBounds.start..<trimBounds.end])
        // Offset between the trimmed in-memory timeline (WhisperKit,
        // diarization, RMS checks) and the on-disk file timeline. Added
        // back when persisting transcript rows.
        let trimOffsetSeconds = Double(trimBounds.start) / fileFormat.sampleRate

        // Pick the diarization source. Prefer the system-only WAV (call
        // participant voices, no local mic) when AudioBufferManager wrote
        // one alongside the mixed WAV; fall back to the mixed buffer
        // otherwise. Diarizing on system-only avoids the false splits at
        // speaker overlaps that happen when the local user's mic is in the
        // input. Both buffers share a sample clock, so applying the same
        // `trimBounds` window keeps timestamps aligned with the WhisperKit
        // segments. Clamp defensively in case the system file is shorter
        // than the mixed (e.g. system tap failed partway through).
        let systemURL = AudioBufferManager.systemAudioURL(for: audioURL)
        guard FileManager.default.fileExists(atPath: systemURL.path),
              let systemFile = try? AVAudioFile(forReading: systemURL),
              systemFile.processingFormat.sampleRate == expectedSampleRate,
              let systemBuffer = AVAudioPCMBuffer(
                  pcmFormat: systemFile.processingFormat,
                  frameCapacity: AVAudioFrameCount(systemFile.length)
              ),
              (try? systemFile.read(into: systemBuffer)) != nil,
              let systemChannelData = systemBuffer.floatChannelData else {
            return PreparedBatchAudio(
                samples: samples, diarizationSamples: samples,
                diarizationSource: "mixed (system WAV missing)", hintKind: .mixed,
                trimOffsetSeconds: trimOffsetSeconds,
                rawSampleCount: rawSampleCount, rawSeconds: rawSeconds
            )
        }
        let allSystemSamples = Array(UnsafeBufferPointer(
            start: systemChannelData[0],
            count: Int(systemBuffer.frameLength)
        ))
        let sStart = min(trimBounds.start, allSystemSamples.count)
        let sEnd = min(trimBounds.end, allSystemSamples.count)
        guard sStart < sEnd else {
            return PreparedBatchAudio(
                samples: samples, diarizationSamples: samples,
                diarizationSource: "mixed (system WAV too short)", hintKind: .mixed,
                trimOffsetSeconds: trimOffsetSeconds,
                rawSampleCount: rawSampleCount, rawSeconds: rawSeconds
            )
        }
        let systemSamples = Array(allSystemSamples[sStart..<sEnd])

        // The system track can EXIST yet be effectively silent — an
        // in-person/hybrid meeting where no remote audio played through
        // the speakers. Diarizing that silence collapses every voice
        // (all captured on the mic, i.e. in the MIXED track) into one
        // "Speaker" — the dominant cause of all-generic meetings. Detect
        // a silent system track by its speech-window fraction and fall
        // back to diarizing the MIXED audio so in-room speakers split.
        let sysSpeechFloor: Float = 0.005
        let win = Int(expectedSampleRate) // 1s windows
        var activeWindows = 0, totalWindows = 0, w = 0
        while w + win <= systemSamples.count {
            var sum: Float = 0, i = w
            while i < w + win { sum += systemSamples[i] * systemSamples[i]; i += 1 }
            if sqrtf(sum / Float(win)) > sysSpeechFloor { activeWindows += 1 }
            totalWindows += 1
            w += win
        }
        let activeFraction = totalWindows > 0 ? Double(activeWindows) / Double(totalWindows) : 0
        if activeFraction < 0.02 {
            // Essentially silent system → in-person/hybrid. Diarize the
            // mixed track; everyone (incl. the user) is an in-room
            // speaker to be named by attribution.
            log("Diarization: system track silent (\(String(format: "%.1f", activeFraction * 100))% active) — diarizing MIXED audio instead")
            return PreparedBatchAudio(
                samples: samples, diarizationSamples: samples,
                diarizationSource: "mixed (system silent)", hintKind: .mixed,
                trimOffsetSeconds: trimOffsetSeconds,
                rawSampleCount: rawSampleCount, rawSeconds: rawSeconds
            )
        }

        // System-only buffer: user's mic isn't in it. The hint is the
        // remote-speaker count, computed identically to runDiarization.
        return PreparedBatchAudio(
            samples: samples, diarizationSamples: systemSamples,
            diarizationSource: "system-only", hintKind: .systemOnly,
            trimOffsetSeconds: trimOffsetSeconds,
            rawSampleCount: rawSampleCount, rawSeconds: rawSeconds
        )
    }

    /// Hallucination filtering, local-user labelling, and Transcript row
    /// construction for one batch run. Pure function of its inputs —
    /// nonisolated so the per-segment RMS scans over the full sample buffers
    /// run off the MainActor.
    ///
    /// Local-user detection: diarization runs on the system-only audio
    /// (remote voices), so the user (whose voice is only on the mic) never
    /// forms a cluster. But the mic signal exists implicitly — it's whatever
    /// is in the MIXED audio but not in the SYSTEM audio. A segment where the
    /// mixed track is clearly louder than the system track is the user
    /// talking over a quiet/silent system stream. Comparing levels (rather
    /// than "system silent") also survives call apps that echo the mic
    /// faintly into system output. Only meaningful when a real system-only
    /// stream was diarized.
    ///
    /// Rows persist FILE-ABSOLUTE times (trim offset added back): all
    /// in-memory work is trimmed-relative, but every later consumer of row
    /// times reads the FULL on-disk WAV — voice profile match/learn, the
    /// energy anchor. Trimmed-relative rows sliced audio shifted early by
    /// the leading silence, folding the wrong speaker's audio into voice
    /// fingerprints (a standing profile-poisoning vector).
    private nonisolated static func buildTranscriptRows(
        meetingId: String,
        segments: [TranscriptSegment],
        speakerMap: [Int: String],
        samples: [Float],
        diarizationSamples: [Float],
        diarizationSource: String,
        trimOffsetSeconds: Double
    ) -> (rows: [Transcript], userSegmentCount: Int, skippedCount: Int) {
        let userDisplayName: String = {
            let n = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
            return n.isEmpty ? "Me" : n
        }()
        let canDetectUser = (diarizationSource == "system-only")
        let userSpeechFloor: Float = 0.005   // mixed must carry real speech
        let userDominanceRatio: Float = 0.5  // system < half of mixed ⇒ mic dominates
        func windowRMS(_ buf: [Float], _ startSec: Double, _ endSec: Double) -> Float {
            let sr = 16_000.0
            let s = max(0, Int(startSec * sr))
            let e = min(buf.count, Int(endSec * sr))
            guard s < e else { return 0 }
            var sum: Float = 0
            var i = s
            while i < e { sum += buf[i] * buf[i]; i += 1 }
            return sqrtf(sum / Float(e - s))
        }
        var userSegmentCount = 0

        // WhisperKit hallucinates on silent/noisy audio — common patterns:
        // - Single word repeated across many segments ("you", "the", "I", "thank you")
        // - Bracketed noise markers: [BLANK_AUDIO], [inaudible], (silence)
        // - Very short segments with low confidence
        // - Repetitive text within a single segment (same phrase 3+ times)
        let hallucinationPhrases: Set<String> = [
            "you", "the", "i", "a", "it", "so", "we", "he", "she", "they",
            "thank you", "thanks", "bye", "okay", "ok", "um", "uh", "hmm",
            "thank you for watching", "thanks for watching",
            "subscribe", "like and subscribe",
            "see you next time", "see you in the next video",
            "please subscribe", "thanks for listening",
        ]

        // First pass: count how often each unique text appears across segments
        var textCounts: [String: Int] = [:]
        for seg in segments {
            let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            textCounts[text, default: 0] += 1
        }

        // If a single phrase accounts for >40% of all segments, it's hallucination
        let hallucinationThreshold = max(3, Int(Double(segments.count) * 0.4))

        var toSave: [Transcript] = []
        var skippedCount = 0
        for seg in segments {
            let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = text.lowercased()

            // Skip empty or single-character
            if text.isEmpty || text.count <= 1 {
                skippedCount += 1; continue
            }

            // Skip bracketed/parenthesized noise markers
            if text.hasPrefix("[") && text.hasSuffix("]") { skippedCount += 1; continue }
            if text.hasPrefix("(") && text.hasSuffix(")") { skippedCount += 1; continue }

            // Skip known hallucination phrases
            if hallucinationPhrases.contains(lower) {
                skippedCount += 1; continue
            }

            // Skip if this exact text repeats too many times (cross-segment hallucination)
            if let count = textCounts[lower], count >= hallucinationThreshold {
                skippedCount += 1; continue
            }

            // Skip intra-segment repetition (same phrase repeated within one segment)
            if text.count > 50 {
                let words = text.components(separatedBy: .whitespaces)
                if words.count > 10 && Double(Set(words).count) / Double(words.count) < 0.2 {
                    skippedCount += 1; continue
                }
            }

            // Label the user's own turns first (mic-dominant windows), then
            // fall back to the diarization cluster for remote speakers.
            let speaker: String
            if canDetectUser {
                let mixedRMS = windowRMS(samples, seg.startTime, seg.endTime)
                let systemRMS = windowRMS(diarizationSamples, seg.startTime, seg.endTime)
                if mixedRMS > userSpeechFloor && systemRMS < mixedRMS * userDominanceRatio {
                    speaker = userDisplayName
                    userSegmentCount += 1
                } else {
                    speaker = speakerMap[Int(seg.startTime)] ?? "Speaker"
                }
            } else {
                speaker = speakerMap[Int(seg.startTime)] ?? "Speaker"
            }

            toSave.append(Transcript(
                meetingId: meetingId,
                speakerLabel: speaker,
                text: text,
                startTime: seg.startTime + trimOffsetSeconds,
                endTime: seg.endTime + trimOffsetSeconds,
                confidence: seg.confidence
            ))
        }
        return (toSave, userSegmentCount, skippedCount)
    }

    /// Highest N across "Speaker N" labels in `labels` (0 when none).
    /// Extracted for testability — append-mode session namespacing depends
    /// on it.
    nonisolated static func maxSpeakerNumber(in labels: [String]) -> Int {
        labels.compactMap { label -> Int? in
            guard label.hasPrefix("Speaker ") else { return nil }
            return Int(label.dropFirst("Speaker ".count))
        }.max() ?? 0
    }

    /// Shift every "Speaker N" label by `shift` (mic/resolved-name rows are
    /// untouched). Append-mode namespacing: a reopened session's diarization
    /// numbers clusters from "Speaker 1" again, colliding with session 1's
    /// labels — and a later fill-only pass would stamp session-2 names onto
    /// session-1's still-anonymous rows.
    nonisolated static func shiftSessionSpeakerLabels(_ transcripts: [Transcript], by shift: Int) -> [Transcript] {
        guard shift > 0 else { return transcripts }
        return transcripts.map { t in
            guard let label = t.speakerLabel, label.hasPrefix("Speaker "),
                  let n = Int(label.dropFirst("Speaker ".count)) else { return t }
            var copy = t
            copy.speakerLabel = "Speaker \(n + shift)"
            return copy
        }
    }

    /// Partition audio paths into usable sessions vs husks. A crash husk is
    /// AVAudioFile's header scaffolding (~4 KB, data chunk at offset 4088)
    /// with zero samples — the old `> 44` check made the husk branch
    /// near-dead. Missing files (nil size) count as husks.
    nonisolated static func partitionUsableAudioPaths(
        _ paths: [String],
        sizeOf: (String) -> Int?
    ) -> (usable: [String], husks: [String]) {
        var usable: [String] = []
        var husks: [String] = []
        for path in paths where !path.isEmpty {
            if let size = sizeOf(path), size > 4200 {
                usable.append(path)
            } else {
                husks.append(path)
            }
        }
        return (usable, husks)
    }

    /// Batch-transcribe a complete WAV file using WhisperKit's sequential
    /// long-form algorithm. Returns the filtered transcript rows; the caller
    /// (transcriptionHandler) is responsible for the atomic DB write.
    ///
    /// Throws ONLY for audio-preparation I/O failures (unreadable WAV) so the
    /// task queue's retry path engages — a crash-recovered file may not have
    /// had its header repaired yet on the first attempt. Transcription/
    /// diarization failures still degrade to empty results (model problems
    /// don't get better with a blind retry; the user-facing recovery is the
    /// re-transcribe flow).
    ///
    /// `timebaseOffset` shifts every persisted row's timestamps — used by
    /// append-mode (reopened meetings) so a second session's rows sort after
    /// the first session's timeline.
    private func batchTranscribe(meetingId: String, audioURL: URL?, timebaseOffset: Double = 0) async throws -> [Transcript] {
        guard let audioURL else {
            fileLog("Batch transcribe: no audio file URL")
            return []
        }

        if !transcriptionService.isModelLoaded {
            // The idle-unload policy makes "not loaded" a normal steady state,
            // not just a launch race — actively kick a load, don't only wait.
            autoLoadTranscriptionModel()
            fileLog("Batch transcribe: model not loaded — load kicked, waiting up to 5 min...")
            for _ in 0..<300 {
                try? await Task.sleep(for: .seconds(1))
                if transcriptionService.isModelLoaded { break }
            }
        }
        guard transcriptionService.isModelLoaded else {
            fileLog("Batch transcribe: model not loaded after 5 min — queuing for later")
            addPendingTranscription(meetingId: meetingId, audioURL: audioURL)
            lastUserError = "Transcription queued — will process when model loads."
            return []
        }

        fileLog("Batch transcribe: processing \(audioURL.lastPathComponent)...")

        // The hint helpers are MainActor and cheap — resolve both up
        // front so the heavy audio preparation can run detached.
        let meeting = try? await self.meetingRepository.find(id: meetingId)
        let remoteHint = remoteParticipantHint(for: meeting)
        let mixedHint = mixedAudioHint(for: meeting)

        // Decode both WAVs, silence-trim, and pick the diarization source
        // OFF the main actor. A 2-hour meeting is ~460 MB per Float
        // buffer; the synchronous read/copy/RMS work used to beachball
        // the UI for seconds right after every meeting ended. Only
        // Sendable value types cross back. I/O errors rethrow (see doc
        // comment); refuse-conditions (wrong sample rate) return nil and
        // complete without a retry storm.
        let maybePrepared: PreparedBatchAudio?
        do {
            maybePrepared = try await Task.detached(priority: .userInitiated, operation: {
                try Self.prepareBatchAudio(audioURL: audioURL)
            }).value
        } catch {
            fileLog("Batch transcribe: audio preparation FAILED — \(error.localizedDescription)")
            throw error
        }
        guard let prepared = maybePrepared else {
            return []
        }

        do {
            let samples = prepared.samples
            let diarizationSamples = prepared.diarizationSamples
            let diarizationSource = prepared.diarizationSource
            let trimOffsetSeconds = prepared.trimOffsetSeconds
            let participantHint: Int? = prepared.hintKind == .systemOnly ? remoteHint : mixedHint
            fileLog("Batch transcribe: \(prepared.rawSampleCount) samples (\(String(format: "%.0f", prepared.rawSeconds))s raw), trimmed to \(samples.count) (\(String(format: "%.0f", Double(samples.count) / 16_000))s speech)")

            // Step 1: Transcribe the trimmed audio with WhisperKit
            let segments = try await transcriptionService.transcribe(samples: samples)
            fileLog("Batch transcribe: WhisperKit returned \(segments.count) segments")

            var speakerMap: [Int: String] = [:] // startTime (seconds, rounded) → "Speaker 1"
            do {
                // Diarize through the engine the flag selects. Both engines emit
                // 1-based "Speaker N" labels; FluidAudio normalizes its string
                // cluster ids in FluidDiarizationResult, SpeakerKit's are 0-based
                // here (hence +1). Energy-aware source selection (above) is
                // engine-agnostic and applies to whichever runs.
                let segments: [(sid: Int, start: Float, end: Float)]
                if settings.useFluidAudioDiarization {
                    let r = try await FluidAudioDiarizationService.shared.diarize(
                        audioArray: diarizationSamples,
                        participantCount: participantHint
                    )
                    segments = r.segments.map { (sid: $0.speakerId, start: $0.startTime, end: $0.endTime) }
                } else {
                    let r = try await SpeakerDiarizationService.shared.diarize(
                        audioArray: diarizationSamples,
                        participantCount: participantHint
                    )
                    segments = r.segments.map { (sid: ($0.speaker.speakerId ?? 0) + 1, start: $0.startTime, end: $0.endTime) }
                }
                fileLog("Diarization: \(segments.count) speaker segments from \(diarizationSource) input (engine: \(settings.useFluidAudioDiarization ? "FluidAudio" : "SpeakerKit"), hint: \(participantHint.map(String.init) ?? "auto"))")

                // Build a lookup: for each second, which speaker is active
                for seg in segments {
                    let label = "Speaker \(seg.sid)"
                    var t = Int(seg.start)
                    while t < Int(seg.end) + 1 {
                        speakerMap[t] = label
                        t += 1
                    }
                }

                let uniqueSpeakers = Set(segments.map { $0.sid })
                fileLog("Diarization: \(uniqueSpeakers.count) unique speaker(s)")
            } catch {
                fileLog("Diarization failed (continuing without speaker labels): \(error.localizedDescription)")
            }

            // Step 3: hallucination filtering + speaker labelling + row
            // construction — pure CPU over the full sample buffers, so it
            // runs detached like the audio preparation above.
            // Row timestamps = file-absolute (trim offset) + timebase offset
            // (append mode shifts session 2 past session 1's timeline).
            let totalOffset = trimOffsetSeconds + timebaseOffset
            let built = await Task.detached(priority: .userInitiated, operation: {
                Self.buildTranscriptRows(
                    meetingId: meetingId,
                    segments: segments,
                    speakerMap: speakerMap,
                    samples: samples,
                    diarizationSamples: diarizationSamples,
                    diarizationSource: diarizationSource,
                    trimOffsetSeconds: totalOffset
                )
            }).value
            fileLog("Batch transcribe: prepared \(built.rows.count) segments, skipped \(built.skippedCount) hallucinations, \(built.userSegmentCount) labeled as user")
            Logger.transcription.info("Batch transcription ready: \(built.rows.count) segments for meeting \(meetingId)")

            // Honesty gate (TASK-031): meaningful audio that produced zero
            // rows is a FAILURE the user must see — not a meeting silently
            // marked complete with an empty page (the June 1 "Prospecting
            // Review": 7 minutes of audio, zero rows, no error, no retry).
            // Stamp transcriptionAttemptedAt first so the startup orphan
            // scan doesn't re-enqueue forever — the visible failed task
            // (with its Retry button) is the user-facing surface now.
            // Re-transcriptions of meetings that already have rows are
            // exempt: the existing transcript is preserved by the commit
            // logic and an alarm would be noise.
            if built.rows.isEmpty, prepared.rawSeconds >= 30 {
                let existingRows = (try? await database.writer.read { db in
                    try Transcript.filter(Transcript.Columns.meetingId == meetingId).fetchCount(db)
                }) ?? 0
                if existingRows == 0 {
                    if var m = try? await meetingRepository.find(id: meetingId) {
                        m.transcriptionAttemptedAt = Date()
                        try? await meetingRepository.save(&m)
                    }
                    throw TranscriptionEmptyResultError(rawSeconds: prepared.rawSeconds)
                }
            }
            return built.rows

        } catch {
            // Rethrow — the old `return []` here swallowed WhisperKit and
            // diarization failures into a "successful" empty transcription,
            // which the handler committed and marked complete. The task
            // queue's retry + failed-task surface is the honest path.
            fileLog("Batch transcribe: ERROR — \(error.localizedDescription)")
            Logger.transcription.error("Batch transcription failed: \(error.localizedDescription)")
            throw error
        }
    }

    // MARK: - Speaker Attribution (v3.1 Layer 2)

    /// Run LLM-based cluster -> name attribution on freshly diarized
    /// transcripts. Returns the (possibly relabelled) transcripts plus a
    /// meeting whose `speakerMap` has been populated when the LLM produced
    /// any mappings. No-op (returns inputs unchanged) when:
    ///   - the meeting has no other named participants,
    ///   - Ollama is unreachable and no fallback is wired,
    ///   - the LLM returns invalid JSON or only "Unknown" verdicts.
    ///
    /// The hook fires AFTER WhisperKit + SpeakerKit have produced raw
    /// `Speaker N` labels but BEFORE persistence so the rewritten labels land
    /// in the DB on the first save.
    /// Confidence assigned to a cluster that FluidAudio matched to a known
    /// person via Phase-2 enrollment. This is the highest NON-manual signal:
    /// it sits above vocative (≤0.85) and LLM (≤0.78) but below a manual
    /// rename (1.0). The match is audio-grounded AND already RSVP-gated to this
    /// meeting (only accepted attendees are enrolled), so the attendance gate is
    /// moot. Default ~0.85 per the Phase-0 spike; FluidAudio doesn't expose a
    /// per-match score, so we use a fixed tier rather than a similarity value.
    static let enrollmentMatchConfidence: Float = 0.85

    /// - Parameter enrollmentMatches: clusters FluidAudio pre-named via Phase-2
    ///   enrollment (`["Speaker N": personName]`). Treated as the highest
    ///   non-manual signal — seeded into the mapping above vocative/LLM and
    ///   scored at `enrollmentMatchConfidence`. Empty on the SpeakerKit path and
    ///   on retry (where transcripts are already relabelled and the pass is
    ///   fill-only). These clusters' transcript rows are relabelled upstream in
    ///   `runDiarization`, so passing them here is what gets them into the
    ///   persisted `speakerMap`/`speakerConfidenceMap` with a real score.
    /// - Parameter existingAssignments: the meeting's already-persisted
    ///   cluster→name map, passed by RE-RUN paths (retry, Re-run AI, series
    ///   propagation). Resolved rows hide their clusters from this pass, so
    ///   without it elimination can re-assign a name the first pass already
    ///   used — minting a duplicate at 0.8 confidence — and the duplicate-name
    ///   flag can't fire.
    private func applySpeakerAttribution(
        transcripts: [Transcript],
        meeting: Meeting,
        enrollmentMatches: [String: String] = [:],
        existingAssignments: [String: String] = [:]
    ) async -> (transcripts: [Transcript], meeting: Meeting) {
        // v3.10 #1 RSVP gate: never consider declined attendees as candidates.
        // Falls back to the full participant list when no RSVP data is present
        // (manual ad-hoc meetings, calendars that don't expose responseStatus).
        // P5: clean the candidate pool — drop bots/notetakers/rooms and
        // distribution lists, dedupe near-identical entries — so elimination
        // isn't corrupted by phantom "attendees" that never speak.
        let participants = SpeakerNamingEngine.cleanCandidates(meeting.acceptedParticipantList)
        guard !participants.isEmpty else { return (transcripts, meeting) }
        if meeting.declinedAttendeeList.count > 0 {
            Logger.general.info("[RSVP] excluding \(meeting.declinedAttendeeList.count) declined attendee(s) from attribution candidates for meeting \(meeting.id, privacy: .public)")
        }

        let userFirst = NSFullUserName()
            .components(separatedBy: .whitespacesAndNewlines)
            .first
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }

        // v3.1 Layer 3: pre-seed the LLM with renames the user has already
        // confirmed in prior meetings of the same series. Empty when this is
        // a one-off meeting or the user hasn't renamed anyone yet.
        let seriesKey = MeetingSeriesService.shared.seriesKey(for: meeting)
        let priorAliasRows = (try? await SpeakerAliasRepository(database: database)
            .aliases(forSeriesKey: seriesKey)) ?? []
        let priorAliases = Dictionary(
            priorAliasRows.map { ($0.clusterId, $0.resolvedName) },
            uniquingKeysWith: { _, new in new }
        )

        let claudeForAttribution: ClaudeService? = {
            guard let key = try? KeychainHelper.loadString(forKey: KeychainHelper.Key.claudeAPIKey),
                  !key.isEmpty else { return nil }
            return ClaudeService()
        }()

        // v3.10 #2: aggregate confidence per cluster from every signal.
        // Initialised here so each branch below can contribute its score.
        var clusterConfidence: [String: Float] = [:]

        // Voice-profile pre-match — checks each Speaker N cluster against the
        // stored voice fingerprint DB before the LLM is invoked. The dynamic
        // per-profile threshold (0.82 normally, 0.87 for LLM-only profiles)
        // gates each match, and we capture the cosine similarity as confidence.
        var voiceMatches: [String: String] = [:]
        // #3 — keep each signal's own confidence so agreeing signals can be
        // combined later (not just first-writer-wins).
        var voiceConfidence: [String: Float] = [:]
        if let audioPath = meeting.audioFilePath {
            let systemURL = AudioBufferManager.systemAudioURL(for: URL(fileURLWithPath: audioPath))
            if FileManager.default.fileExists(atPath: systemURL.path) {
                // Group time ranges by Speaker N cluster id (skip mic/system/other).
                var clusterRanges: [String: [(start: Float, end: Float)]] = [:]
                for t in transcripts {
                    let raw = (t.speakerLabel ?? "").trimmingCharacters(in: .whitespaces)
                    guard raw.lowercased().hasPrefix("speaker ") else { continue }
                    clusterRanges[raw, default: []].append((Float(t.startTime), Float(t.endTime)))
                }
                if !clusterRanges.isEmpty {
                    let vpRepo = VoiceProfileRepository(database: database)
                    let pRepo  = PersonRepository(database: database)
                    let stored = (try? await vpRepo.allProfilesResolved(personRepo: pRepo)) ?? []
                    let result = await VoiceProfileService.shared.matchProfilesWithConfidence(
                        audioURL: systemURL,
                        clusterRanges: clusterRanges,
                        stored: stored
                    )
                    voiceMatches = result.mapping
                    voiceConfidence = result.confidence
                    // Voice match confidence = cosine similarity (already in [0, 1]).
                    for (cluster, sim) in result.confidence {
                        clusterConfidence[cluster] = sim
                    }
                    if !voiceMatches.isEmpty {
                        Logger.general.info("Voice pre-match: \(voiceMatches.count) cluster(s) recognised before LLM for meeting \(meeting.id, privacy: .public)")
                    }
                }
            }
        }

        // ─── L1: Calendar-attendance gate ──────────────────────────────
        // A poisoned voice profile (e.g. user mislabelled their own voice
        // as "Sam" in a past meeting) will return high-similarity matches
        // for "Sam" in EVERY future meeting, even ones Sam isn't part
        // of. Reject any voice match whose name isn't a calendar attendee
        // of THIS meeting. Drop-ins are a rare false-negative — the user
        // can still apply the name manually via the Speakers tab.
        //
        // Comparison is case-insensitive and tolerant of partial matches
        // ("Sam" matches "Sam Carter <sam@…>" and vice versa).
        let attendeeNamesLower = participants.map { $0.lowercased() }
        let userFirstLower = userFirst?.lowercased()
        let droppedMatches = voiceMatches.filter { (_, name) in
            let lower = name.lowercased()
            // Always allow the user — mic channel is ground truth. First-token
            // equality, not substring: a poisoned profile name merely
            // CONTAINING the user's first name must not skip the gate.
            if let uf = userFirstLower,
               lower.components(separatedBy: .whitespacesAndNewlines).first == uf { return false }
            // Keep when name fuzzy-matches any attendee.
            let isAttendee = attendeeNamesLower.contains { att in
                att.contains(lower) || lower.contains(att)
            }
            return !isAttendee
        }
        for (cluster, name) in droppedMatches {
            Logger.general.warning("[AttendanceGate] dropping voice match \(cluster, privacy: .public) → \(name, privacy: .public) — not in attendees \(participants.joined(separator: ", "), privacy: .public)")
            voiceMatches.removeValue(forKey: cluster)
            voiceConfidence.removeValue(forKey: cluster)
            clusterConfidence.removeValue(forKey: cluster)
        }

        // Merge prior-aliases (series memory) with voice matches. Voice wins on
        // collision because it's audio-grounded, not just label-name memory.
        var combinedPriorAliases = priorAliases
        for (cluster, name) in voiceMatches { combinedPriorAliases[cluster] = name }

        // ─── Vocative mining (transcript-grounded identification) ──────
        // Scan the transcript for "Hey Dana" / "Thanks Sam" / "Priya, can
        // you…" patterns. The next utterance from a different cluster is
        // overwhelmingly likely to be that named person. Hallucination-proof
        // because names come only from the calendar attendee list — the
        // model isn't picking from training data.
        // Pass ONLY the series-alias memory as the skip-set — NOT the voice
        // matches. Vocative evaluating voice-matched clusters is what makes
        // genuine cross-signal corroboration possible (the confidence combine
        // below); skipping them made every cluster a single-signal verdict.
        let vocativeResult = VocativeMiningService.attributeWithConfidence(
            transcripts: transcripts,
            attendees: participants,
            userFirstName: userFirst,
            existingMapping: priorAliases
        )
        for (cluster, name) in vocativeResult.mapping where combinedPriorAliases[cluster] == nil {
            Logger.general.info("[Vocative] mined \(cluster, privacy: .public) → \(name, privacy: .public)")
            combinedPriorAliases[cluster] = name
            // Record vocative confidence (0.55 / 0.70 / 0.85) only for
            // clusters that didn't already have a stronger voice match.
            if clusterConfidence[cluster] == nil,
               let conf = vocativeResult.confidence[cluster] {
                clusterConfidence[cluster] = conf
            }
        }

        let outcome = await SpeakerAttributionService.shared.attribute(
            transcripts: transcripts,
            participantNames: participants,
            userFirstName: userFirst,
            priorAliases: combinedPriorAliases,
            ollama: ollamaService,
            claude: claudeForAttribution
        )

        // Signal precedence on a per-cluster collision: the gated voice
        // fingerprint (cosine ≥ 0.82, attendance-checked) outranks the LLM
        // tier (0.62–0.78) — see speaker-id-pipeline.md "higher signal wins".
        // Compare actual confidences so an escalated LLM verdict can still
        // beat a borderline voice match if tiers ever shift.
        var mapping = outcome.mapping
        for (cluster, name) in voiceMatches {
            if let llmName = mapping[cluster], llmName.lowercased() != name.lowercased() {
                let llmConf = outcome.confidenceMap[cluster] ?? 0
                if (voiceConfidence[cluster] ?? 0) >= llmConf {
                    Logger.general.info("[Precedence] voice match overrides LLM for \(cluster, privacy: .public): \(llmName, privacy: .public) → \(name, privacy: .public)")
                    mapping[cluster] = name
                }
            } else if mapping[cluster] == nil {
                mapping[cluster] = name
            }
        }

        // Vocative mining is a direct signal (signal 3 of 5), not just a
        // prompt hint. Fill clusters the LLM and voice match left empty —
        // without this, a local-only setup with Ollama unreachable drops
        // every vocative hit on the floor.
        for (cluster, name) in vocativeResult.mapping where mapping[cluster] == nil {
            mapping[cluster] = name
        }

        // #3 — combine AGREEING signals instead of first-writer-wins. For each
        // finally-mapped cluster, gather the confidence from every independent
        // signal (voice / vocative / LLM) that proposed the SAME resolved name,
        // and combine them probabilistically: 1 − ∏(1 − cᵢ). Two mediocre
        // signals that agree (e.g. a 0.58 voice match and a 0.62 LLM verdict)
        // now clear the review bar together, where previously whichever wrote
        // first masked the corroboration. A lone signal keeps its own score
        // (single term → unchanged). Disagreeing signals don't contribute —
        // only the signals backing the chosen name count. The LLM's verdict is
        // NOT independent when the prompt already seeded the same name for the
        // cluster (prior alias / voice / vocative) — an echo must not inflate
        // the combined score, so it's excluded.
        for (cluster, finalName) in mapping {
            let finalLower = finalName.lowercased()
            var contributions: [Float] = []
            if let n = voiceMatches[cluster], n.lowercased() == finalLower,
               let c = voiceConfidence[cluster] { contributions.append(c) }
            if let n = vocativeResult.mapping[cluster], n.lowercased() == finalLower,
               let c = vocativeResult.confidence[cluster] { contributions.append(c) }
            if let n = outcome.mapping[cluster], n.lowercased() == finalLower,
               let c = outcome.confidenceMap[cluster],
               combinedPriorAliases[cluster]?.lowercased() != finalLower {
                contributions.append(c)
            }
            guard !contributions.isEmpty else {
                // Echo-only cluster (e.g. series-alias seed the LLM confirmed):
                // keep the plain LLM tier rather than combining — confirmed,
                // not corroborated.
                if clusterConfidence[cluster] == nil,
                   outcome.mapping[cluster]?.lowercased() == finalLower,
                   let c = outcome.confidenceMap[cluster] {
                    clusterConfidence[cluster] = c
                }
                continue
            }
            let combined = 1 - contributions.reduce(Float(1)) { $0 * (1 - $1) }
            clusterConfidence[cluster] = min(1.0, combined)
        }

        // Enrollment matches (FluidAudio Phase-2) are the highest NON-manual
        // signal: audio-grounded and already RSVP-gated to this meeting. They
        // win over vocative/LLM on a name collision and are scored at the fixed
        // enrollment tier. Applied AFTER the combine step so the tier isn't
        // diluted by a weaker corroborating signal. Their transcript rows were
        // relabelled upstream in runDiarization; seeding the mapping here is what
        // persists them in the meeting's speakerMap + speakerConfidenceMap.
        for (cluster, name) in enrollmentMatches {
            mapping[cluster] = name
            clusterConfidence[cluster] = Self.enrollmentMatchConfidence
            Logger.general.info("[Enrollment] cluster \(cluster, privacy: .public) → \(name, privacy: .public) (conf \(Self.enrollmentMatchConfidence))")
        }

        // Auto-map the user's own mic cluster (if any). Mic-tagged turns are
        // labelled "mic" by the capture pipeline, never "Speaker N", so they
        // don't go through the LLM. Surface the user's name on those rows by
        // mapping "mic" -> their full name (or first name if that's all we have).
        if let userFirst = userFirst {
            let fullName = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
            let displayName = fullName.isEmpty ? userFirst : fullName
            mapping["mic"] = displayName
            // Mic stream is ground-truth — full confidence.
            clusterConfidence["mic"] = 1.0
        }

        let allClusters = Set(transcripts.compactMap { $0.speakerLabel })
            .filter { $0 != "mic" && $0 != "system" && $0.hasPrefix("Speaker ") }

        // ─── P1: energy "you" anchor ───────────────────────────────────
        // On the FluidAudio mixed-audio path the local user is a "Speaker N"
        // cluster (no "mic" label), so nothing above identified them. Pin the
        // user's cluster by mic-vs-system energy. SOFT signal: validated at
        // ~57% precision when it fires (harness/evaluations/2026-05-31), so
        // it is (a) gated to the FluidAudio path it was built for — on the
        // default SpeakerKit path diarization runs on system-only audio where
        // every cluster is remote by construction, making any fire a wrong
        // name — (b) capped below the 0.60 review threshold so the amber dot
        // shows, and (c) excluded from seeding P2 elimination. Re-raise after
        // it re-validates ≥90% on correctly-captured recordings.
        var energyAnchorCluster: String? = nil
        if settings.useFluidAudioDiarization, let audioPath = meeting.audioFilePath {
            let mixedURL = URL(fileURLWithPath: audioPath)
            let systemURL = AudioBufferManager.systemAudioURL(for: mixedURL)
            if FileManager.default.fileExists(atPath: systemURL.path) {
                var ranges: [String: [(start: Float, end: Float)]] = [:]
                for t in transcripts {
                    let raw = (t.speakerLabel ?? "").trimmingCharacters(in: .whitespaces)
                    guard raw.hasPrefix("Speaker "), mapping[raw] == nil else { continue }
                    ranges[raw, default: []].append((Float(t.startTime), Float(t.endTime)))
                }
                if !ranges.isEmpty {
                    let detachedRanges = ranges
                    let hit = await Task.detached(priority: .userInitiated) {
                        Self.identifyUserClusterByEnergy(clusterRanges: detachedRanges, mixedURL: mixedURL, systemURL: systemURL)
                    }.value
                    if let hit, mapping[hit.cluster] == nil {
                        let fullName = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
                        let displayName = fullName.isEmpty ? (userFirst ?? "Me") : fullName
                        mapping[hit.cluster] = displayName
                        clusterConfidence[hit.cluster] = min(hit.confidence, 0.55)
                        energyAnchorCluster = hit.cluster
                        Logger.general.info("[Energy] local user cluster \(hit.cluster, privacy: .public) → \(displayName, privacy: .public) (soft, conf capped at 0.55)")
                    }
                }
            }
        }

        // ─── P2: margin-guarded elimination (generalizes the old 2-person
        // auto-assign to N people). Assigns only when exactly one cluster and
        // one candidate remain — never forces a guess when counts are ambiguous.
        // The soft energy-anchor cluster is removed from BOTH sides: it must
        // not drive elimination (57% precision would cascade a second wrong
        // name), and it must not be treated as an open cluster either.
        // First-token equality, not substring — a user named "Sam" must not
        // remove attendee "Samantha Jones" from the elimination roster.
        let nonUserParticipants = participants.filter { name in
            guard let userFirst = userFirst else { return true }
            let firstToken = name.lowercased()
                .components(separatedBy: .whitespacesAndNewlines).first ?? ""
            return firstToken != userFirst.lowercased()
        }
        let eliminationClusters = allClusters.subtracting(energyAnchorCluster.map { [$0] } ?? [])
        let eliminated = SpeakerNamingEngine.eliminate(
            allClusters: eliminationClusters,
            candidates: nonUserParticipants,
            // Existing assignments (re-run paths) consume their names too —
            // a name used by an already-resolved cluster must not be minted
            // again for the lone remaining anonymous cluster. EXISTING wins
            // on a key collision: the persist step is fill-only, so on disk
            // the existing entry survives — elimination must consume the name
            // that will actually be persisted.
            assigned: mapping.filter { $0.key.hasPrefix("Speaker ") && $0.key != energyAnchorCluster }
                .merging(existingAssignments) { _, existing in existing }
        )
        for (cluster, asg) in eliminated {
            mapping[cluster] = asg.name
            clusterConfidence[cluster] = asg.confidence
            Logger.general.info("[Elimination] \(cluster, privacy: .public) → \(asg.name, privacy: .public) (conf \(asg.confidence))")
        }

        // ─── P3: contradiction flags — persisted on the meeting (migration
        // v45 attributionFlags) and surfaced in the Speakers tab. Flags don't
        // change the mapping — they record where a result needs human
        // confirmation.
        var namingFlags = SpeakerNamingEngine.flags(
            // Existing wins on collision — mirrors the fill-only persist (see
            // the elimination merge above).
            finalMapping: mapping.filter { $0.key.hasPrefix("Speaker ") }
                .merging(existingAssignments) { _, existing in existing },
            allClusters: allClusters,
            acceptedCandidates: participants,
            userNames: [NSFullUserName(), userFirst ?? ""]
        )
        // P4 advisory: a name resting ONLY on cross-meeting voice/enrollment
        // (no independent signal agrees, confidence below the strong bar) is
        // ~57% reliable on this audio — flag it for review rather than trust it.
        for (cluster, name) in mapping where cluster.hasPrefix("Speaker ") {
            let nl = name.lowercased()
            let fromVoice = (voiceMatches[cluster]?.lowercased() == nl)
                || (enrollmentMatches[cluster]?.lowercased() == nl)
            guard fromVoice else { continue }
            // An LLM verdict that merely echoes the prompt-seeded name is not
            // independent corroboration.
            let llmAgreesIndependently = (outcome.mapping[cluster]?.lowercased() == nl)
                && combinedPriorAliases[cluster]?.lowercased() != nl
            let corroborated = (vocativeResult.mapping[cluster]?.lowercased() == nl)
                || llmAgreesIndependently
                || ((clusterConfidence[cluster] ?? 0) >= 0.95)
            if !corroborated {
                namingFlags.append(SpeakerNamingEngine.Flag(
                    kind: .voiceMatchAdvisory,
                    reason: "“\(name)” was matched only by voice (no other signal agrees) — please confirm."))
            }
        }
        for f in namingFlags {
            Logger.general.info("[NamingFlag] \(f.kind.rawValue, privacy: .public): \(f.reason, privacy: .public)")
        }

        // Persist the diagnostic reason to the in-memory cache so the
        // FullTranscriptView banner can surface a specific message instead of
        // a generic "couldn't attribute". Keyed by meeting id.
        Self.lastAttributionReason[meeting.id] = outcome.reason

        guard !mapping.isEmpty else {
            Logger.general.info("Speaker attribution outcome=\(String(describing: outcome.reason), privacy: .public) for meeting \(meeting.id, privacy: .public)")
            return (transcripts, meeting)
        }

        // Rewrite each transcript's speakerLabel in place when the cluster id
        // is in the map. Clusters that came back "Unknown" stay as Speaker N.
        let relabelled: [Transcript] = transcripts.map { t in
            guard let label = t.speakerLabel,
                  let mapped = mapping[label] else { return t }
            var copy = t
            copy.speakerLabel = mapped
            return copy
        }

        var updated = meeting
        updated.setSpeakerMap(mapping)
        // v3.10 #2: persist per-cluster confidence so the UI can surface
        // low-trust attributions for review without re-running attribution.
        // Only keep entries that ended up in the final mapping.
        let finalConfidence = clusterConfidence.filter { mapping[$0.key] != nil }
        updated.setSpeakerConfidenceMap(finalConfidence)
        // P3: persist contradiction flags so the Speakers tab can surface them.
        updated.setAttributionFlags(namingFlags)
        Logger.general.info("Speaker attribution: mapped \(mapping.count) cluster(s) (outcome=\(String(describing: outcome.reason), privacy: .public)) for meeting \(meeting.id, privacy: .public)")
        return (relabelled, updated)
    }

    /// Load a 16 kHz mono WAV into a [Float] sample buffer (nil if unreadable
    /// or not 16 kHz). Used by the energy-based local-user identifier.
    private nonisolated static func loadSamples16k(_ url: URL) -> [Float]? {
        guard let f = try? AVAudioFile(forReading: url) else { return nil }
        let fmt = f.processingFormat
        guard fmt.sampleRate == 16000,
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(f.length)) else { return nil }
        do { try f.read(into: buf) } catch { return nil }
        guard let ch = buf.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(buf.frameLength)))
    }

    /// P1 (naming design): identify which "Speaker N" cluster is the LOCAL USER
    /// by mic-vs-system energy. The user is on the mic and (near-)absent from the
    /// system track, so their cluster's segments carry mixed energy while the
    /// system track is quiet. Returns nil when the system track has no speech
    /// (in-person — every cluster looks "mic-only", can't distinguish) or no
    /// cluster is clearly mic-dominant. This is what lets a 1:1 recorded as two
    /// "Speaker N" clusters (FluidAudio mixed-audio path) get the user pinned so
    /// elimination can name the other person.
    /// nonisolated static: decodes BOTH full WAVs and RMS-scans every cluster
    /// range — called via Task.detached so the scan never runs on the MainActor.
    private nonisolated static func identifyUserClusterByEnergy(
        clusterRanges: [String: [(start: Float, end: Float)]],
        mixedURL: URL,
        systemURL: URL
    ) -> (cluster: String, confidence: Float)? {
        guard let mixed = Self.loadSamples16k(mixedURL),
              let system = Self.loadSamples16k(systemURL),
              !mixed.isEmpty, !system.isEmpty else { return nil }
        let sr = 16000.0
        let speechFloor: Float = 0.005
        let userRatio: Float = 0.35  // system < 35% of mixed ⇒ mic-dominant (user)
        // The persisted mixed and system WAVs do NOT share a sample timeline:
        // the manual resamplers in MicrophoneCapture/SystemAudioTap land them at
        // different effective lengths (observed mixed ≈ 3× system frames despite
        // both being labeled 16 kHz). Indexing system by the mixed sample index
        // reads ~3× off in real time. Map the system index by PROPORTION — both
        // tracks span the same recording wall-clock, just at different effective
        // rates. (Validated 2026-05-31: lifts gold precision 25% → 57%.)
        // TODO: the real fix is capture-side parity (AVAudioConverter); until
        // then this anchor remains a soft signal, not an auto-naming source.
        let systemScale = Double(system.count) / Double(mixed.count)
        func rms(_ b: [Float], _ s: Int, _ e: Int) -> Float {
            guard s < e, s >= 0, e <= b.count else { return -1 }
            var sum: Float = 0; var i = s
            while i < e { sum += b[i] * b[i]; i += 1 }
            return sqrtf(sum / Float(e - s))
        }
        var bestCluster: String?
        var bestFrac: Float = 0
        var anySystemSpeech = false
        for (cluster, ranges) in clusterRanges {
            var userWin = 0, totalWin = 0
            for r in ranges {
                let s = Int(Double(r.start) * sr), e = Int(Double(r.end) * sr)
                let m = rms(mixed, s, e)
                if m < 0 || m <= speechFloor { continue }
                let ss = Int(Double(s) * systemScale), se = Int(Double(e) * systemScale)
                let sy = rms(system, min(ss, system.count), min(se, system.count))
                if sy < 0 { continue }
                if sy > speechFloor { anySystemSpeech = true }
                totalWin += 1
                if sy <= m * userRatio { userWin += 1 }
            }
            guard totalWin >= 3 else { continue }
            let frac = Float(userWin) / Float(totalWin)
            if frac > bestFrac { bestFrac = frac; bestCluster = cluster }
        }
        // Need real remote audio to contrast against AND a clearly mic-dominant cluster.
        guard anySystemSpeech, let c = bestCluster, bestFrac >= 0.7 else { return nil }
        return (c, 0.9)
    }

    // MARK: - Retry Attribution (v3.10 #7)

    /// In-memory guard so a meeting's retryAttribution task is enqueued at most
    /// once per session. Prevents an infinite loop if the retry itself produces
    /// no new mappings. Cleared on app restart, which is fine — at worst a
    /// meeting gets one more retry attempt the next time the user opens it.
    @MainActor
    private static var retryAttributionAttempted: Set<String> = []

    /// Enqueue a retryAttribution task if and only if:
    ///   1. The meeting has accepted attendees (no point retrying with no candidates)
    ///   2. There are still "Speaker N" rows in the transcript that haven't
    ///      been mapped to a real name
    ///   3. We haven't already retried this meeting in the current session
    private func maybeEnqueueRetryAttribution(meetingId: String) async {
        if Self.retryAttributionAttempted.contains(meetingId) { return }

        guard let meeting = try? await meetingRepository.find(id: meetingId),
              !meeting.acceptedParticipantList.isEmpty else { return }

        let transcripts = (try? await transcriptRepository.transcriptsForMeeting(meetingId, limit: 100_000)) ?? []
        // Are there transcript rows whose label still looks like "Speaker N"?
        let hasUnresolved = transcripts.contains { t in
            (t.speakerLabel ?? "").lowercased().hasPrefix("speaker ")
        }
        guard hasUnresolved else { return }

        Self.retryAttributionAttempted.insert(meetingId)
        Logger.general.info("[RetryAttribution] enqueueing second-pass for meeting \(meetingId, privacy: .public)")
        _ = await taskQueueManager.enqueue(
            type: .retryAttribution,
            meetingId: meetingId,
            priority: 4
        )
    }

    /// Second-pass attribution — runs `applySpeakerAttribution` against the
    /// full, post-cleanup transcript. Same pipeline, more data.
    ///
    /// IMPORTANT: `applySpeakerAttribution` only attributes clusters whose
    /// speakerLabel still starts with "Speaker N" (the voice/vocative paths
    /// gate on this). So its returned `speakerMap` reflects ONLY the new
    /// mappings the retry produced. We MERGE those into the existing map
    /// rather than replacing — otherwise a 3-of-5 first-pass map would be
    /// overwritten by a 1-entry retry-pass map, losing 2 good attributions.
    /// (QA finding #3.)
    func runRetryAttribution(meetingId: String) async {
        guard let meeting = try? await meetingRepository.find(id: meetingId) else { return }
        let transcripts = (try? await transcriptRepository.transcriptsForMeeting(meetingId, limit: 100_000)) ?? []
        guard !transcripts.isEmpty else { return }

        let existingMap = meeting.speakerMapDictionary
        let existingConf = meeting.speakerConfidenceMapDictionary
        let beforeCount = existingMap.count

        let (_, attributed) = await applySpeakerAttribution(
            transcripts: transcripts,
            meeting: meeting,
            existingAssignments: existingMap
        )
        let newMap = attributed.speakerMapDictionary
        let newConf = attributed.speakerConfidenceMapDictionary

        // Merge: retry only FILLS clusters that were unresolved on the first
        // pass. We deliberately never overwrite an existing mapping, even
        // with higher confidence — silent name flips ("Alice" → "Bob" with
        // no UI signal) erode user trust faster than a slightly stale label.
        // (VP review concern.) If the user explicitly wants to re-attribute,
        // they can delete the speakerMap and rerun.
        var mergedMap = existingMap
        var mergedConf = existingConf
        var newCount = 0
        for (cluster, name) in newMap where mergedMap[cluster] == nil {
            mergedMap[cluster] = name
            if let c = newConf[cluster] { mergedConf[cluster] = c }
            newCount += 1
        }

        guard newCount > 0 else {
            Logger.general.info("[RetryAttribution] no new mappings for \(meetingId, privacy: .public) — keeping existing")
            return
        }

        // Rewrite rows from the MERGED map so rows can never disagree with the
        // persisted map (the raw re-run output could propose a different name
        // for a cluster the merge kept). Only rows still labelled "Speaker N"
        // or the raw mic bucket are touched — user renames stay untouched.
        let safeRelabelled: [Transcript] = transcripts.compactMap { t in
            guard let old = t.speakerLabel else { return nil }
            let oldLower = old.lowercased()
            guard oldLower.hasPrefix("speaker ") || oldLower == "mic" || oldLower == "system",
                  let newName = mergedMap[old], newName != old else { return nil }
            var copy = t
            copy.speakerLabel = newName
            return copy
        }

        var updatedMeeting = meeting
        updatedMeeting.setSpeakerMap(mergedMap)
        updatedMeeting.setSpeakerConfidenceMap(mergedConf)
        // Fresh flags were computed WITH existingAssignments merged in —
        // replace the stale first-pass flags.
        updatedMeeting.setAttributionFlags(attributed.attributionFlagList)
        let meetingToSave = updatedMeeting

        do {
            try await database.writer.write { db in
                var m = meetingToSave
                try m.update(db)
                for transcript in safeRelabelled {
                    var t = transcript
                    try t.update(db)
                }
            }
            Logger.general.info("[RetryAttribution] mapped \(newCount) new cluster(s) for \(meetingId, privacy: .public) (total \(beforeCount + newCount))")
            loadMeetings()
        } catch {
            Logger.general.error("[RetryAttribution] persist failed for \(meetingId, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Run the transcript-cleanup pipeline (stitch + best-effort AI pass)
    /// for one meeting and persist the result. Called from the TaskQueue
    /// after batch transcription completes. Idempotent — safe to call
    /// multiple times; replaces the previous cleaned blob.
    func runTranscriptCleanup(meetingId: String) async {
        let segments = (try? await transcriptRepository.transcriptsForMeeting(meetingId, limit: 100_000)) ?? []
        guard !segments.isEmpty else {
            Logger.ai.info("[TranscriptCleanup] no segments for \(meetingId, privacy: .public) — skipping")
            return
        }

        // Best-effort AI: hand the LLM in if one is configured. Service
        // gracefully falls back to stitch-only when nil or when the call
        // throws. Cleanup output ≈ input length (it's editing text, not
        // generating new content), so budget 4096 output tokens to handle
        // 30-60 min meetings without truncation.
        let textGen = await makeTextGenerator(maxOutputTokens: 4096)
        let (text, method) = await TranscriptCleanupService.clean(
            transcripts: segments,
            textGenerator: textGen
        )
        guard !text.isEmpty else {
            Logger.ai.warning("[TranscriptCleanup] empty output for \(meetingId, privacy: .public) — not persisting")
            return
        }

        let cleaned = CleanedTranscript(
            meetingId: meetingId,
            text: text,
            generatedAt: Date(),
            method: method
        )
        do {
            try await CleanedTranscriptRepository(database: database).save(cleaned)
            Logger.ai.info("[TranscriptCleanup] saved for \(meetingId, privacy: .public) method=\(method, privacy: .public)")
        } catch {
            Logger.ai.error("[TranscriptCleanup] save failed for \(meetingId, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Learn voice profiles from a meeting's *confirmed* speakers. Walks the
    /// transcript rows, groups by speakerLabel where the label is a real name
    /// (not a generic cluster id like "Speaker N", "system", "mic"), and
    /// extracts a mel-spectrum embedding from each name's audio segments.
    /// Merges via VoiceProfileRepository.merge so repeated calls compound the
    /// fingerprint via EMA rather than overwriting.
    ///
    /// Safe to call any time. No-op when:
    ///   - the meeting has no system audio file
    ///   - no transcript row carries a real name
    ///   - audio segments for a name are < 3s total (handled inside the service)
    /// True when a speaker label is a generic/unresolved bucket that must never
    /// be learned as a real person's voice: "Speaker N", "system", "mic",
    /// "Unknown", "Everyone", "Other", "Them", or empty. Centralizes the filter
    /// used by both learning paths so junk profiles can't slip through.
    static func isGenericSpeakerLabel(_ raw: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if s.isEmpty { return true }
        if s.hasPrefix("speaker ") || s == "speaker" { return true }
        return ["system", "mic", "unknown", "other", "them", "everyone", "everybody", "all"].contains(s)
    }

    func learnVoiceProfiles(meetingId: String) async {
        guard let meeting = try? await meetingRepository.find(id: meetingId),
              let firstAudioPath = meeting.audioFilePath,
              !firstAudioPath.isEmpty else { return }

        // Voice profiles are extracted from the SYSTEM audio (other speakers) —
        // never from the mixed mic+system file. The system file is derived
        // alongside the mixed file with a "_system" suffix. Skip when missing.
        let mixedURL = URL(fileURLWithPath: firstAudioPath)
        let systemURL = AudioBufferManager.systemAudioURL(for: mixedURL)
        guard FileManager.default.fileExists(atPath: systemURL.path) else { return }

        let transcripts = (try? await transcriptRepository.transcriptsForMeeting(meetingId, limit: 10_000)) ?? []
        guard !transcripts.isEmpty else { return }

        // Group time ranges by confirmed speaker name. We define "confirmed" as
        // any label that isn't a generic cluster bucket — no Speaker N, no
        // system, no mic, no Unknown, and not the user themselves (their
        // turns are tagged "mic" anyway, but be defensive).
        let userFirst = NSFullUserName()
            .components(separatedBy: .whitespacesAndNewlines).first?.lowercased() ?? ""

        var rangesByName: [String: [(start: Float, end: Float)]] = [:]
        for t in transcripts {
            let raw = (t.speakerLabel ?? "").trimmingCharacters(in: .whitespaces)
            guard !Self.isGenericSpeakerLabel(raw) else { continue }
            let lower = raw.lowercased()
            if !userFirst.isEmpty, lower.contains(userFirst) { continue }
            // Treat the speaker name as the canonical key.
            rangesByName[raw, default: []].append((Float(t.startTime), Float(t.endTime)))
        }
        guard !rangesByName.isEmpty else { return }

        let voiceService = VoiceProfileService.shared
        let repo = VoiceProfileRepository(database: database)
        let personRepo = PersonRepository(database: database)
        let sampleRepo = VoiceSampleRepository(database: database)

        // v3.10 source tagging (QA finding #6): a name in this transcript
        // could have come from a manual rename OR an LLM attribution. Only
        // treat it as `.manual` when there's a confirmed alias row for the
        // current series — otherwise default to `.llm` (low trust). This
        // prevents LLM-attributed names from sneaking into the high-trust
        // pool via the rerun/rebuild paths.
        let seriesKey = MeetingSeriesService.shared.seriesKey(for: meeting)
        let aliasRows = (try? await SpeakerAliasRepository(database: database)
            .aliases(forSeriesKey: seriesKey)) ?? []
        let manuallyConfirmedNames = Set(aliasRows.map { $0.resolvedName.lowercased() })

        // #4 — confidence floor against profile poisoning. Build name → min
        // attribution confidence from the meeting's cluster maps (confidence is
        // keyed by cluster id; speakerMap maps cluster id → resolved name). A
        // name attributed only by a low-confidence LLM guess must NOT be folded
        // into the voice DB — otherwise one wrong guess teaches a fingerprint
        // that then auto-mis-matches that voice forever. Manual confirmations
        // (alias row + confidence 1.0 in this meeting) bypass the floor.
        let learnConfidenceFloor: Float = 0.70
        let confByCluster = meeting.speakerConfidenceMapDictionary
        let clusterToName = meeting.speakerMapDictionary
        var confidenceByName: [String: Float] = [:]
        for (cluster, name) in clusterToName {
            guard let c = confByCluster[cluster] else { continue }
            let key = name.lowercased()
            confidenceByName[key] = min(confidenceByName[key] ?? .greatestFiniteMagnitude, c)
        }

        for (name, ranges) in rangesByName {
            let nameKey = name.lowercased()
            let conf = confidenceByName[nameKey]
            // `.manual` requires BOTH a series alias row AND confidence 1.0 in
            // THIS meeting's map — only a manual rename writes 1.0. The alias
            // alone proves a rename in SOME meeting of the series; a later LLM
            // mis-attribution of a different voice to that same name must not
            // learn at manual trust (α 0.40) or flip the profile to the laxer
            // 0.82 match threshold.
            let isManual = manuallyConfirmedNames.contains(nameKey) && conf == 1.0
            if !isManual {
                // Every auto signal writes a cluster confidence (LLM, vocative,
                // voice, elimination, energy anchor). A missing entry means a
                // stale or replaced map — treat it as below the floor, not as
                // trusted.
                guard let conf, conf >= learnConfidenceFloor else {
                    Logger.general.info("Voice learn skipped (confidence \(conf.map { String($0) } ?? "missing")): \(name, privacy: .public) for meeting \(meetingId, privacy: .public)")
                    continue
                }
            }
            guard let embedding = await voiceService.extractEmbedding(audioURL: systemURL, timeRanges: ranges) else { continue }
            let person = try? await personRepo.findOrCreate(for: name)
            let source: VoiceProfileRepository.EmbeddingSource = isManual ? .manual : .llm
            try? await repo.merge(
                personName: name,
                newEmbedding: embedding,
                personRepo: personRepo,
                source: source
            )
            // Phase 4: persist the individual utterance sample for provenance
            if let pid = person?.id, !ranges.isEmpty {
                let span = ranges.reduce((min: Float.infinity, max: Float(0))) {
                    (min($0.min, $1.start), max($0.max, $1.end))
                }
                var sample = VoiceSample(
                    id: nil,
                    personId: pid,
                    meetingId: meetingId,
                    startTime: Double(span.min),
                    endTime: Double(span.max),
                    embeddingData: Data(),
                    source: source.rawValue,
                    createdAt: Date()
                )
                sample.embedding = embedding
                try? await sampleRepo.save(sample)
            }
            Logger.general.info("Voice profile learned: \(name, privacy: .public) (\(ranges.count) range(s)) for meeting \(meetingId, privacy: .public)")
        }
    }

    /// HARD RESET of the voice-identity system, then re-transcribe + re-identify
    /// EVERY meeting that has audio on disk, so both transcripts and voice
    /// profiles are rebuilt by the current (WhisperKit 1.0 + fixed) pipeline.
    /// Better transcription quality improves attribution across the board, so
    /// the scope is all meetings — not just small ones.
    ///
    /// Steps:
    ///   1. Wipe voiceProfile, voiceSample, and speakerAlias — every learned
    ///      fingerprint and manual alias is cleared (the user chose a clean
    ///      slate). Person rows are kept; they're rebuilt by attribution.
    ///   2. Select every meeting whose primary audio file exists on disk,
    ///      most-recent first (so the meetings the user is most likely to open
    ///      are rebuilt first). Capped by `maxMeetings` when set.
    ///   3. For each, enqueue a .transcription task tagged "retranscribe". The
    ///      handler REPLACES that meeting's transcripts atomically only once the
    ///      new pass succeeds — old transcripts stay visible until then, so the
    ///      app is fully usable while the rebuild runs in the background. The
    ///      queue re-transcribes, diarizes the system WAV (when present),
    ///      attributes, and rebuilds the profile DB via learnVoiceProfiles.
    ///
    /// Returns the number of meetings enqueued. The work runs asynchronously on
    /// the task queue and can take a long time (hours for a large history).
    func runFullVoiceProfileReset(maxMeetings: Int? = nil) async -> Int {
        // 1. Hard wipe of the voice-identity tables.
        do {
            try await database.writer.write { db in
                try db.execute(sql: "DELETE FROM voiceProfile")
                try db.execute(sql: "DELETE FROM voiceSample")
                try db.execute(sql: "DELETE FROM speakerAlias")
            }
            fileLog("VoiceReset: wiped voiceProfile + voiceSample + speakerAlias")
        } catch {
            fileLog("VoiceReset: wipe failed — \(error.localizedDescription)")
            return 0
        }

        // 2. Every meeting with a real audio file on disk, most-recent first.
        let candidates = meetings
            .filter { m in
                guard let path = m.audioFilePath, !path.isEmpty else { return false }
                return FileManager.default.fileExists(atPath: path)
            }
            .sorted { ($0.startDate ?? $0.createdAt) > ($1.startDate ?? $1.createdAt) }
        let targets = maxMeetings.map { Array(candidates.prefix($0)) } ?? candidates
        fileLog("VoiceReset: \(candidates.count) meeting(s) with audio, enqueuing \(targets.count)")

        // 3. Enqueue re-transcription. No pre-deletion — the handler swaps each
        //    meeting's transcripts atomically when its turn completes, keeping
        //    the old transcript readable until then.
        var enqueued = 0
        for m in targets {
            await taskQueueManager.enqueue(
                type: .transcription,
                meetingId: m.id,
                priority: 2,
                metadata: "retranscribe"
            )
            enqueued += 1
        }
        fileLog("VoiceReset: enqueued \(enqueued) meeting(s) for re-transcription + rebuild")
        return enqueued
    }

    /// One-shot rebuild of the entire voice-profile database from history.
    /// Walks every meeting, extracts embeddings for every confirmed speaker,
    /// merges into the profile DB. Useful after a v3.5.0 upgrade so the
    /// previously-collected manual renames suddenly pay off as cross-meeting
    /// recognition. Polite 200ms delay between meetings.
    func rebuildVoiceProfilesFromHistory() async -> Int {
        let allMeetings = meetings.filter { $0.audioFilePath != nil }
        var processed = 0
        for m in allMeetings {
            await learnVoiceProfiles(meetingId: m.id)
            processed += 1
            try? await Task.sleep(for: .milliseconds(200))
        }
        Logger.general.info("Voice profile rebuild: processed \(processed) meeting(s)")
        return processed
    }

    /// In-memory cache of the most recent attribution outcome per meeting.
    /// Read by FullTranscriptView's diagnostic banner. Not persisted — rebuilt
    /// on each attribution run, which is fine because the banner is only
    /// meaningful right after a run.
    @MainActor
    static var lastAttributionReason: [String: AttributionReason] = [:]

    // MARK: - Speaker Diarization

    /// Run SpeakerKit diarization on the system audio file, update transcript speaker
    /// labels in the DB, then run LLM attribution to map cluster IDs → real names.
    /// Re-run diarization for a meeting, resolving the system audio URL
    /// from the meeting's stored audio paths. Called from the Speakers tab's
    /// "Re-analyze speakers" button.
    // EXEMPT: user-driven re-analysis — the Speakers tab awaits completion
    // inline to refresh its cluster cards, so it can't be a fire-and-forget
    // queue task. Serialized against queued diarization via the
    // `diarizationInFlight` per-meeting guard, and the idle model unload
    // skips while `inFlightDiarizations > 0`.
    func rerunDiarization(meetingId: String) async {
        guard let meeting = try? await meetingRepository.find(id: meetingId),
              let firstPath = meeting.audioFilePaths.first,
              !firstPath.isEmpty else {
            fileLog("Diarization re-run: no audio path for \(meetingId)")
            lastUserError = "Can't re-analyze speakers — this meeting has no audio file on disk."
            return
        }
        let mixedURL = URL(fileURLWithPath: firstPath)
        let systemURL = AudioBufferManager.systemAudioURL(for: mixedURL)
        do {
            try await runDiarization(meetingId: meetingId, systemAudioURL: systemURL)
        } catch {
            lastUserError = "Re-analyze speakers failed: \(error.localizedDescription)"
        }
    }

    /// Speaker-count hint passed to Pyannote when diarizing a SYSTEM-ONLY
    /// audio buffer. Returns the number of expected REMOTE speakers — accepted
    /// attendees minus the local user, who isn't in the system-only stream.
    ///
    /// Pyannote treats `numberOfSpeakers` as an EXACT count, not an upper
    /// bound: when its own clustering disagrees it re-runs K-Means forced to
    /// exactly that many clusters. So an over-count splits one real speaker
    /// into several. Returns nil for 0–1 expected remote speakers and lets
    /// Pyannote's own clustering decide, rather than forcing a possibly-wrong
    /// exact count.
    private func remoteParticipantHint(for meeting: Meeting?) -> Int? {
        guard let m = meeting else { return nil }
        let accepted = m.acceptedParticipantList
        guard !accepted.isEmpty else { return nil }

        let userEmail = googleAuthManager.userEmail?
            .lowercased().trimmingCharacters(in: .whitespaces)
        let userName = NSFullUserName()
            .lowercased().trimmingCharacters(in: .whitespaces)
        func isLocalUser(_ raw: String) -> Bool {
            let s = raw.lowercased().trimmingCharacters(in: .whitespaces)
            if let e = userEmail, !e.isEmpty, s == e { return true }
            if !userName.isEmpty, s == userName { return true }
            return false
        }

        // #5 — only hint when we can positively identify and subtract the
        // local user. The old `accepted.count - 1` guess fired when the user
        // ISN'T in their own attendee list (common for externally-organized
        // invites): it under-counted by one, and since Pyannote treats the
        // hint as an EXACT count, two real remote speakers collapsed into one
        // cluster (under-split). When we can't find the user, return nil and
        // let Pyannote's own clustering decide rather than force a wrong count.
        guard accepted.contains(where: isLocalUser) else { return nil }
        let remote = accepted.filter { !isLocalUser($0) }.count
        return remote >= 2 ? remote : nil
    }

    /// Speaker-count hint when diarizing MIXED audio (mic + system fallback
    /// paths). Expected voices = accepted attendees — but only when the local
    /// user can be positively identified in the list. Otherwise the count is
    /// off by one in an unknown direction, and Pyannote treats the hint as
    /// EXACT (an over-count force-splits a real speaker — the regression the
    /// old `attendeeCount + 1` caused on every 1:1 fallback). nil lets the
    /// clusterer decide.
    private func mixedAudioHint(for meeting: Meeting?) -> Int? {
        guard let m = meeting else { return nil }
        let accepted = m.acceptedParticipantList
        guard !accepted.isEmpty else { return nil }

        let userEmail = googleAuthManager.userEmail?
            .lowercased().trimmingCharacters(in: .whitespaces)
        let userName = NSFullUserName()
            .lowercased().trimmingCharacters(in: .whitespaces)
        func isLocalUser(_ raw: String) -> Bool {
            let s = raw.lowercased().trimmingCharacters(in: .whitespaces)
            if let e = userEmail, !e.isEmpty, s == e { return true }
            if !userName.isEmpty, s == userName { return true }
            return false
        }
        guard accepted.contains(where: isLocalUser) else { return nil }
        return accepted.count >= 2 ? accepted.count : nil
    }

    /// Meetings with a diarization pass currently executing. The queued
    /// `.diarization` task and the user's Re-analyze button (which runs
    /// outside the queue — see the EXEMPT note at its call site) can target
    /// the same meeting; without this guard they become concurrent writers
    /// relabelling the same rows.
    private var diarizationInFlight: Set<String> = []

    private func runDiarization(meetingId: String, systemAudioURL: URL?) async throws {
        guard !diarizationInFlight.contains(meetingId) else {
            fileLog("Diarization: already running for \(meetingId) — skipping duplicate")
            lastUserError = "Speaker analysis is already running for this meeting — give it a moment to finish."
            return
        }
        diarizationInFlight.insert(meetingId)
        defer { diarizationInFlight.remove(meetingId) }

        let service = SpeakerDiarizationService.shared
        let transcriptRepo = TranscriptRepository(database: database)

        guard let audioURL = systemAudioURL,
              FileManager.default.fileExists(atPath: audioURL.path) else {
            fileLog("Diarization: no system audio file for \(meetingId) — skipping")
            return
        }

        // Load the meeting to know how many remote participants to hint the clusterer.
        let meeting = try? await database.writer.read { db in
            try Meeting.fetchOne(db, key: meetingId)
        }
        // Cluster-count hint for diarization. Diarization runs on the
        // SYSTEM-ONLY audio, which contains the remote participants — NOT the
        // local user (they're on the mic stream). Pyannote treats
        // `numberOfSpeakers` as an EXACT count: when its own clustering
        // disagrees it re-runs K-Means forced to exactly that many clusters
        // (see SpeakerKit VBxClustering). So an over-count splits one real
        // speaker into several. The previous `max(2, acceptedCount + 1)` both
        // counted the user (who isn't in this audio) AND added another +1,
        // overshooting by ~2 — every 1:1 had its single remote speaker split
        // into the forced minimum of 2 clusters.
        //
        // Correct hint = number of expected REMOTE speakers = accepted
        // attendees minus the local user. Declined attendees are already
        // excluded by `acceptedParticipantList`. Only hint when we expect ≥2
        // remote speakers (where a count genuinely prevents under-merge); for
        // 0–1, pass nil and let Pyannote's clustering decide rather than force
        // a possibly-wrong exact count.
        let participantCount = remoteParticipantHint(for: meeting)

        do {
            taskQueueManager.reportCurrentProgress(stage: "Running diarization")

            // FluidAudio path is diarization-only in Phase 1: it produces the
            // cluster alignment but doesn't feed the SpeakerKit-shaped voice
            // profile match/learn (FluidAudio enrollment replaces that in
            // Phase 2). SpeakerKit path is unchanged. `resultBox`/`voiceService`
            // are only built on the SpeakerKit path.
            let useFluid = settings.useFluidAudioDiarization

            // Fetch all transcript rows for alignment and echo suppression.
            // Re-diarizable rows are the legacy "system" bucket AND anonymous
            // "Speaker N"/"Speaker" labels — the batch path stopped writing
            // "system" rows in v4.0, which silently turned this whole function
            // (queued diarization task, Re-analyze button, FluidAudio
            // enrollment) into dead code. Resolved-name rows (manual renames,
            // prior attributions) and "mic" rows are never re-labelled.
            let transcripts = try await transcriptRepo.transcriptsForMeeting(meetingId, limit: Int.max)
            func isReDiarizable(_ label: String?) -> Bool {
                let l = (label ?? "").lowercased().trimmingCharacters(in: .whitespaces)
                return l == "system" || l == "speaker" || l.hasPrefix("speaker ")
            }
            let systemTranscripts = transcripts.filter { isReDiarizable($0.speakerLabel) }
            let micTranscripts = transcripts.filter {
                ($0.speakerLabel ?? "").lowercased() == "mic"
            }
            guard !systemTranscripts.isEmpty else {
                fileLog("Diarization: no re-diarizable transcript rows for \(meetingId)")
                return
            }

            let profileRepo = VoiceProfileRepository(database: database)
            let voiceService = VoiceProfileService.shared
            var speakerCount = 0
            var labelMapping: [Int64: String]
            var voiceMatches: [String: String] = [:]
            var resultBox: DiarizationResultBox? = nil
            // Phase 2 — held when the FluidAudio path runs so confirmed clusters
            // can have their per-Person voice reference (re)built after attribution.
            var fluidResult: FluidDiarizationResult? = nil
            var enrolledSpeakers: [EnrolledSpeaker] = []
            // FluidAudio enrollment matches ("Speaker N" → person), passed to
            // applySpeakerAttribution as the highest non-manual signal. Distinct
            // from `voiceMatches` (which also carries SpeakerKit mel-spectrum
            // matches) so the SpeakerKit path doesn't get an enrollment tier.
            var enrollmentMatches: [String: String] = [:]

            if useFluid {
                // Phase 2 — seed cross-meeting voice identity: enroll the known
                // references of this meeting's RSVP-accepted attendees so matching
                // clusters come back already named (audio-grounded, highest signal).
                let enrollPersonRepo = PersonRepository(database: database)
                let referenceRepo = VoiceReferenceRepository(database: database)
                if let m = meeting {
                    enrolledSpeakers = await SpeakerEnrollmentService.shared.enrolledSpeakers(
                        for: m,
                        personRepo: enrollPersonRepo,
                        referenceRepo: referenceRepo
                    )
                }

                let result = try await FluidAudioDiarizationService.shared.diarize(
                    systemAudioURL: audioURL,
                    participantCount: participantCount,
                    enrolledSpeakers: enrolledSpeakers
                )
                guard result.speakerCount > 0 else {
                    fileLog("Diarization: 0 speakers detected for \(meetingId) (FluidAudio)")
                    return
                }
                speakerCount = result.speakerCount
                fluidResult = result
                labelMapping = FluidAudioDiarizationService.shared.alignToTranscripts(
                    systemTranscripts, result: result
                )

                // Clusters FluidAudio matched to an enrolled reference resolve
                // straight to a name — treat as voice matches (the attendance gate
                // is moot since enrollment is already RSVP-gated to this meeting).
                let enrolledNames = SpeakerEnrollmentService.shared.enrolledClusterNames(
                    result: result,
                    enrolledSpeakers: enrolledSpeakers
                )
                if !enrolledNames.isEmpty {
                    voiceMatches = enrolledNames
                    enrollmentMatches = enrolledNames
                    fileLog("Diarization: enrollment matched \(enrolledNames.count) cluster(s) for \(meetingId) (FluidAudio)")
                }
            } else {
                let result = try await service.diarize(
                    systemAudioURL: audioURL,
                    participantCount: participantCount
                )
                guard result.speakerCount > 0 else {
                    fileLog("Diarization: 0 speakers detected for \(meetingId)")
                    return
                }
                speakerCount = result.speakerCount

                taskQueueManager.reportCurrentProgress(stage: "Matching voice profiles")

                let box = DiarizationResultBox(result)
                resultBox = box

                // Phase 3 — match stored voice profiles before LLM attribution.
                // Clusters that match a known voice are pre-assigned, skipping the LLM entirely.
                // Use allProfilesResolved so each profile's personName reflects the
                // Person's current canonical name (Phase 2: personId-keyed matching).
                let personRepo2 = PersonRepository(database: database)
                let storedProfiles = (try? await profileRepo.allProfilesResolved(personRepo: personRepo2)) ?? []
                // 1-based to match the batch path's "Speaker N" convention
                // (SpeakerKit ids are 0-based; parseSpeakerId subtracts 1).
                let clusterLabels = Set(result.segments.compactMap { $0.speaker.speakerId }.map { "Speaker \($0 + 1)" })
                voiceMatches = await voiceService.matchProfiles(
                    clusters: Array(clusterLabels),
                    audioURL: audioURL,
                    diarizationResult: box,
                    stored: storedProfiles
                )
                if !voiceMatches.isEmpty {
                    fileLog("Diarization: voice profiles pre-matched \(voiceMatches.count) cluster(s) for \(meetingId)")
                }

                // ATTENDANCE GATE (ADR-004): the pre-match relabels transcript
                // rows directly below, so it must pass the same gate as the
                // attribution-path voice match — a poisoned profile must not
                // stamp a non-attendee's name into rows with no review signal.
                // With NO attendee list at all (participant-less ad-hoc
                // meetings) there is nothing to gate against, so nothing is
                // stamped — that is exactly the unattended scenario the
                // poisoned-profile failure mode lives in.
                let accepted = meeting?.acceptedParticipantList ?? []
                if accepted.isEmpty {
                    if !voiceMatches.isEmpty {
                        fileLog("Diarization: [AttendanceGate] no attendee list — dropping \(voiceMatches.count) ungated voice pre-match(es)")
                        voiceMatches = [:]
                    }
                } else {
                    let acceptedLower = accepted.map { $0.lowercased() }
                    let userLower = NSFullUserName().lowercased()
                    for (cluster, name) in voiceMatches {
                        let lower = name.lowercased()
                        let isUser = !userLower.isEmpty && (lower.components(separatedBy: .whitespacesAndNewlines).first == userLower.components(separatedBy: .whitespacesAndNewlines).first)
                        let isAttendee = acceptedLower.contains { $0.contains(lower) || lower.contains($0) }
                        if !isUser && !isAttendee {
                            fileLog("Diarization: [AttendanceGate] dropping pre-match \(cluster) → \(name) — not an attendee")
                            voiceMatches.removeValue(forKey: cluster)
                        }
                    }
                }

                labelMapping = service.alignToTranscripts(systemTranscripts, result: result)
            }

            guard !labelMapping.isEmpty else {
                fileLog("Diarization: alignment produced no matches for \(meetingId)")
                return
            }

            // Echo suppression: call apps (Zoom, Meet, Teams) often mix the
            // user's mic audio into their output stream. ScreenCaptureKit
            // captures this mixed output, so system-audio segments can contain
            // the user's own voice. Cross-reference: any system transcript
            // that overlaps >50% with a mic transcript is likely the user's
            // echo — relabel it as the user instead of "Speaker N".
            let userName = NSFullUserName()
            if !micTranscripts.isEmpty {
                var echoCount = 0
                for (txId, _) in labelMapping {
                    guard let sysTx = systemTranscripts.first(where: { $0.id == txId }) else { continue }
                    let sysLen = sysTx.endTime - sysTx.startTime
                    guard sysLen > 0 else { continue }

                    for micTx in micTranscripts {
                        let overlapStart = max(sysTx.startTime, micTx.startTime)
                        let overlapEnd = min(sysTx.endTime, micTx.endTime)
                        let overlap = max(0, overlapEnd - overlapStart)
                        if overlap / sysLen >= 0.5 {
                            labelMapping[txId] = userName.isEmpty ? "Me" : userName
                            echoCount += 1
                            break
                        }
                    }
                }
                if echoCount > 0 {
                    fileLog("Diarization: suppressed \(echoCount) echo segment(s) (user voice in system audio) for \(meetingId)")
                }
            }

            // Apply voice-profile pre-assignments: replace "Speaker N" with real name
            // where we have a confident match, so the LLM doesn't need to guess.
            if !voiceMatches.isEmpty {
                labelMapping = labelMapping.mapValues { label in
                    voiceMatches[label] ?? label
                }
            }

            try await transcriptRepo.updateSpeakerLabels(labelMapping)
            fileLog("Diarization: labelled \(labelMapping.count) transcript rows for \(meetingId) (\(speakerCount) speakers)")

            // Now run LLM attribution for any remaining "Speaker N" clusters.
            if let m = meeting {
                let freshRows = try await transcriptRepo.transcriptsForMeeting(meetingId, limit: Int.max)
                let (attributedRows, attributed) = await applySpeakerAttribution(
                    transcripts: freshRows,
                    meeting: m,
                    enrollmentMatches: enrollmentMatches,
                    // Names already resolved on rows (clusters this pass can't
                    // see) must still consume elimination candidates and feed
                    // the duplicate-name flag.
                    existingAssignments: m.speakerMapDictionary
                )

                // Preserve manual renames across a re-analysis: diarization
                // re-shuffles cluster ids, so the new map replaces anonymous
                // entries — but confidence-1.0 entries (only manual renames
                // write 1.0) survive UNLESS the new clustering re-issued the
                // same cluster id to a DIFFERENT name. In that case the old
                // entry describes a cluster that no longer exists; keeping it
                // would override the fresh assignment in the map while the
                // rows (written in this same transaction) carry the new name
                // — the exact map/row divergence the atomic write prevents.
                // The manual name itself is safe either way: its rows are
                // resolved labels this pass never touches, and the series
                // alias row preserves the memory.
                var mergedMap = attributed.speakerMapDictionary
                var mergedConf = attributed.speakerConfidenceMapDictionary
                let oldConf = m.speakerConfidenceMapDictionary
                for (cluster, name) in m.speakerMapDictionary where (oldConf[cluster] ?? 0) >= 1.0 {
                    if let reissued = mergedMap[cluster],
                       reissued.lowercased() != name.lowercased() {
                        continue
                    }
                    mergedMap[cluster] = name
                    mergedConf[cluster] = 1.0
                }

                // Persist the attribution's row relabels TOGETHER with the
                // meeting maps — the old code persisted only the meeting (and
                // with try?, silently), leaving rows stuck at "Speaker N"
                // while the map claimed names: sparkles badge on an anonymous
                // label, names never visible in transcript or exports.
                let changedRows: [Transcript] = zip(freshRows, attributedRows).compactMap { old, new in
                    guard old.speakerLabel != new.speakerLabel else { return nil }
                    return new
                }
                var updated = attributed
                updated.setSpeakerMap(mergedMap)
                updated.setSpeakerConfidenceMap(mergedConf)
                let toPersist = updated
                try await database.writer.write { db in
                    for row in changedRows {
                        var copy = row
                        try copy.update(db)
                    }
                    var meetingCopy = toPersist
                    try meetingCopy.update(db)
                }

                // Phase 3 — save voice embeddings for newly-identified speakers
                // so future meetings can match them without the LLM.
                // v3.10 #4: source-tag each merge. If the same cluster was in
                // the pre-match voice dictionary, treat as voiceMatch (high
                // trust); otherwise it came from the LLM (low trust, stricter
                // future threshold to prevent drift).
                // SpeakerKit-only: the mel-spectrum embedding extractor consumes
                // a SpeakerKit-shaped `resultBox`. On the FluidAudio path this is
                // skipped (FluidAudio enrollment replaces voice-profile learning
                // in Phase 2).
                if let box = resultBox {
                    let finalSpeakerMap = attributed.speakerMapDictionary
                    let personRepo = PersonRepository(database: database)
                    for (clusterLabel, personName) in finalSpeakerMap {
                        guard !personName.isEmpty else { continue }
                        // Never learn a generic/unresolved label as a person — this is
                        // what produced junk "Speaker 3" / "Everyone" voice profiles.
                        guard !Self.isGenericSpeakerLabel(personName) else { continue }
                        let source: VoiceProfileRepository.EmbeddingSource =
                            voiceMatches[clusterLabel] != nil ? .voiceMatch : .llm
                        if let embedding = await voiceService.extractEmbedding(
                            forSpeaker: clusterLabel,
                            from: audioURL,
                            diarizationResult: box
                        ) {
                            try? await profileRepo.merge(
                                personName: personName,
                                newEmbedding: embedding,
                                personRepo: personRepo,
                                source: source
                            )
                            fileLog("Diarization: updated voice profile for \(personName) (source=\(source.rawValue))")
                        }
                    }
                }

                // Phase 2 — FluidAudio path: (re)build each confirmed speaker's
                // per-Person voice reference from this meeting's highest-confidence
                // segment embeddings, so future meetings match the voice via
                // enrollment instead of falling back to vocative/LLM. Only rebuild
                // for clusters whose final attribution is high-confidence (≥ 0.85,
                // the audio-grounded tier) — low-confidence LLM guesses must not
                // poison the reference. Enrollment matches are already confident.
                if let fr = fluidResult {
                    let finalSpeakerMap = attributed.speakerMapDictionary
                    let confidence = attributed.speakerConfidenceMapDictionary
                    let referenceRepo = VoiceReferenceRepository(database: database)
                    let personRepo = PersonRepository(database: database)
                    for (clusterLabel, personName) in finalSpeakerMap {
                        guard !personName.isEmpty,
                              !Self.isGenericSpeakerLabel(personName) else { continue }
                        guard (confidence[clusterLabel] ?? 0) >= 0.85 else { continue }
                        await SpeakerEnrollmentService.shared.rebuildReference(
                            personName: personName,
                            clusterLabel: clusterLabel,
                            result: fr,
                            personRepo: personRepo,
                            referenceRepo: referenceRepo
                        )
                    }
                }
            }

            loadMeetings()
        } catch {
            fileLog("Diarization: failed for \(meetingId): \(error.localizedDescription)")
            Logger.general.error("Diarization failed for \(meetingId): \(error.localizedDescription)")
            // Rethrow — the task queue owns retry/failure bookkeeping. A
            // swallowed error here reported "completed" for a run that did
            // nothing, and the queue's retry machinery never engaged.
            throw error
        }
    }

    // MARK: - Transcription Lifecycle

    /// Automatically load the default WhisperKit model at app startup.
    /// Retries up to 3 times with 10s delay between attempts.
    /// Hard-stopped after `modelLoadHardMax` total attempts to prevent infinite background retries.
    private func autoLoadTranscriptionModel() {
        Task {
            guard !transcriptionService.isModelLoaded else { return }
            guard modelLoadTotalAttempts < modelLoadHardMax else {
                fileLog("Model: hard stop after \(modelLoadHardMax) total attempts — use retryModelLoad() to try again")
                lastUserError = "Transcription model failed to load. Tap to retry."
                return
            }

            // Use the user's selected model (defaults to turbo for best performance).
            let model = WhisperModel(rawValue: settings.whisperModel) ?? .largev3turbo
            let maxRetries = 3

            Logger.transcription.info("Auto-loading WhisperKit model: \(model.rawValue)")
            fileLog("Model: loading \(model.rawValue)...")
            isLoadingModel = true
            modelDownloadProgress = 0

            // Start a synthetic progress timer — WhisperKit only reports 0.05 then 1.0,
            // so we use an exponential curve to show continuous progress to the user.
            let startTime = Date()
            let estimatedDuration: TimeInterval = 180 // ~3 min estimate for first download
            modelProgressCancellable = Timer.publish(every: 0.5, on: .main, in: .common)
                .autoconnect()
                .sink { [weak self] _ in
                    guard let self, self.isLoadingModel else {
                        self?.modelProgressCancellable = nil
                        return
                    }
                    let elapsed = Date().timeIntervalSince(startTime)
                    // Asymptotically approach 0.9 — real completion snaps to 1.0
                    let synthetic = 0.9 * (1.0 - exp(-elapsed / estimatedDuration))
                    let real = self.transcriptionService.downloadProgress
                    self.modelDownloadProgress = max(synthetic, real)
                }

            let loadStart = Date()
            var lastError: Error?
            for attempt in 1...maxRetries {
                modelLoadTotalAttempts += 1
                do {
                    try await transcriptionService.loadModel(model)
                    // The hard cap is a runaway-FAILURE backstop, not a
                    // lifetime budget: the idle-unload policy makes reloads
                    // routine, so a success must reset the counter.
                    modelLoadTotalAttempts = 0
                    modelProgressCancellable = nil
                    modelDownloadProgress = 1.0
                    // Flip the "loading" flag immediately so the sidebar
                    // banner dismisses the moment the model is ready. The
                    // pending-transcription pass below can run for many
                    // minutes (a full WhisperKit pass per queued meeting),
                    // and gating the banner on it leaves a "100%" bar stuck
                    // on screen long after transcription is actually working.
                    isLoadingModel = false

                    Logger.transcription.info("WhisperKit model loaded — transcription is ready")
                    fileLog("Model: LOADED successfully — ready for transcription")

                    // Notify user if this was a real download (not a cache load)
                    let loadDuration = Date().timeIntervalSince(loadStart)
                    if loadDuration > 30 {
                        sendModelReadyNotification()
                    }

                    // Kick pending transcriptions off without awaiting — the
                    // outer function returns immediately so the UI updates,
                    // and the queue drains in the background like any other
                    // post-meeting work.
                    Task { [weak self] in
                        await self?.processPendingTranscriptions()
                    }

                    lastError = nil
                    break
                } catch {
                    lastError = error
                    if attempt < maxRetries {
                        fileLog("Model: retry \(attempt)/\(maxRetries) failed — \(error.localizedDescription). Retrying in 10s...")
                        try? await Task.sleep(for: .seconds(10))
                        modelDownloadProgress = 0
                    }
                }
            }

            if let lastError {
                modelProgressCancellable = nil
                modelDownloadProgress = 0

                Logger.transcription.error("Failed to auto-load WhisperKit model after \(maxRetries) attempts: \(lastError.localizedDescription)")
                fileLog("Model: FAILED to load after \(maxRetries) attempts — \(lastError.localizedDescription)")

                // Schedule a background retry in 5 minutes
                Task {
                    try? await Task.sleep(for: .seconds(300))
                    if !self.transcriptionService.isModelLoaded {
                        fileLog("Model: background retry after 5 min...")
                        self.autoLoadTranscriptionModel()
                    }
                }
            }
            isLoadingModel = false
        }
    }

    /// Retry loading the WhisperKit model after a failure.
    /// Resets the hard-stop counter so the user can trigger fresh attempts.
    func retryModelLoad() {
        modelLoadTotalAttempts = 0
        transcriptionService.clearError()
        autoLoadTranscriptionModel()
    }

    // MARK: - Pending Transcription Queue

    /// Queue a meeting for transcription when the model becomes available.
    private func addPendingTranscription(meetingId: String, audioURL: URL) {
        var pending = UserDefaults.standard.dictionary(forKey: Self.pendingTranscriptionKey) as? [String: String] ?? [:]
        pending[meetingId] = audioURL.path
        UserDefaults.standard.set(pending, forKey: Self.pendingTranscriptionKey)
        fileLog("Pending transcription queued: \(meetingId)")
    }

    /// Process any meetings queued for transcription.
    private func processPendingTranscriptions() async {
        guard transcriptionService.isModelLoaded else { return }
        guard let pending = UserDefaults.standard.dictionary(forKey: Self.pendingTranscriptionKey) as? [String: String],
              !pending.isEmpty else { return }

        fileLog("Processing \(pending.count) pending transcription(s)...")

        // Entries whose prepare failed are written BACK for the next launch —
        // the old wholesale removeObject at the end dropped them despite the
        // "leave it for next launch" intent.
        var remaining: [String: String] = [:]

        for (meetingId, path) in pending {
            let audioURL = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else {
                fileLog("Pending transcription: audio file missing for \(meetingId), removing from queue")
                continue
            }
            // Use same atomic-write pattern as transcriptionHandler
            let rawTranscripts: [Transcript]
            do {
                rawTranscripts = try await batchTranscribe(meetingId: meetingId, audioURL: audioURL)
            } catch {
                // Deterministic empty result: re-running next launch can't
                // change it — drop the entry (attemptedAt was stamped before
                // the throw, so the orphan scan won't resurrect it either)
                // and tell the user once.
                if error is TranscriptionEmptyResultError {
                    fileLog("Pending transcription: \(meetingId) produced no text — dropping from the relaunch queue")
                    lastUserError = error.localizedDescription
                    continue
                }
                // Legacy UserDefaults drain path has no queue retry — log and
                // keep the entry for the next launch.
                fileLog("Pending transcription: prepare failed for \(meetingId) — \(error.localizedDescription)")
                remaining[meetingId] = path
                continue
            }
            if var meeting = try? await meetingRepository.find(id: meetingId) {
                // Speaker labels are NOT written to meeting.participants — real
                // attendee names (from calendar) must not be overwritten by
                // "Speaker N" labels. Labels live only in transcript.speakerLabel.

                // v3.1 Layer 2: attribute Speaker N clusters before persistence.
                let (transcripts, attributedMeeting) = await applySpeakerAttribution(
                    transcripts: rawTranscripts,
                    meeting: meeting
                )
                meeting = attributedMeeting

                if meeting.status == .transcribing { meeting.status = .complete }
                try? await database.writer.write { db in
                    for var t in transcripts { try t.save(db) }
                    try meeting.save(db)
                }

                // P1-T06: auto-title ad-hoc meetings on the recovery path too.
                await autoTitleIfNeeded(meeting: meeting, transcripts: transcripts)
            }
        }

        // Clear processed entries; failed ones stay for the next launch.
        // Merge with anything added DURING the drain — batchTranscribe
        // self-requeues via addPendingTranscription when the model unloads
        // mid-run, and a plain set/remove here would clobber that entry.
        var toKeep = remaining
        let addedDuringDrain = (UserDefaults.standard.dictionary(forKey: Self.pendingTranscriptionKey) as? [String: String]) ?? [:]
        for (meetingId, path) in addedDuringDrain where pending[meetingId] == nil {
            toKeep[meetingId] = path
        }
        if toKeep.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.pendingTranscriptionKey)
            fileLog("Pending transcription queue cleared")
        } else {
            UserDefaults.standard.set(toKeep, forKey: Self.pendingTranscriptionKey)
            fileLog("Pending transcription queue: \(toKeep.count) entr(y/ies) kept for next launch")
        }
    }

    // MARK: - Auto-title (P1-T06)

    /// If the meeting still has the default/empty title and is not tied to a
    /// calendar event, generate an ≤8-word title from the transcript (local
    /// Ollama first, Claude haiku as fallback, then the summary's first sentence).
    /// Falls through silently when no provider is available — the meeting just
    /// keeps its default title until the user (or summary) renames it.
    private func autoTitleIfNeeded(meeting: Meeting, transcripts: [Transcript]) async {
        // Calendar meetings already have a meaningful title from the event.
        guard meeting.calendarEventId == nil else { return }

        let defaultTitles: Set<String> = ["New Meeting", "Untitled Meeting", ""]
        let trimmedTitle = meeting.title.trimmingCharacters(in: .whitespaces)
        guard defaultTitles.contains(meeting.title) || trimmedTitle.isEmpty else { return }

        let transcriptText = transcripts.map { $0.text }.joined(separator: " ")
        guard !transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let claudeKey = (try? KeychainHelper.loadString(forKey: KeychainHelper.Key.claudeAPIKey)) ?? nil
        let resolvedTitle: String?
        if let generated = await TitleGenerationService.shared.generate(
            fromTranscript: transcriptText,
            claudeAPIKey: claudeKey,
            ollama: ollamaService
        ) {
            resolvedTitle = generated
        } else if let summary = try? await summaryRepository.latestSummary(meetingId: meeting.id),
                  !summary.summaryText.isEmpty {
            resolvedTitle = TitleGenerationService.shared.extractFromSummary(summary.summaryText)
        } else {
            resolvedTitle = nil
        }

        guard let generated = resolvedTitle else {
            Logger.general.info("Auto-title: no title generated for \(meeting.id, privacy: .public) (Ollama unavailable, no summary fallback)")
            return
        }

        var updated = meeting
        updated.title = generated
        do {
            try await meetingRepository.update(updated)
            Logger.general.info("Auto-titled meeting \(meeting.id, privacy: .public): \(generated, privacy: .public)")
        } catch {
            Logger.general.error("Auto-title persist failed for \(meeting.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Send a macOS notification that the transcription model is ready.
    private func sendModelReadyNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Meeting Manager"
        content.body = "Transcription model downloaded and ready. You can now record and transcribe meetings."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "model-download-complete",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Logger.general.error("Failed to send model-ready notification: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Call Detection Response

    /// Called when a call app or browser meeting is detected.
    /// Respects `autoRecord` and `autoInvite` settings.
    @MainActor
    private func handleCallDetected(appName: String, bundleId: String? = nil) {
        guard !isRecording else {
            Logger.general.info("Call detected (\(appName)) but already recording — ignoring")
            return
        }
        guard !isStartingMeeting else {
            Logger.general.info("Call detected (\(appName)) but another start in progress — ignoring")
            return
        }

        // Deduplicate rapid-fire detections within 10 seconds.
        // Both CallDetectionService and BrowserCallDetector can fire for the same
        // meeting (e.g., Zoom.app launches AND "Zoom Meeting" appears in a browser tab).
        if let lastTime = lastCallDetectionTime, Date().timeIntervalSince(lastTime) < 10 {
            Logger.general.info("Call detected (\(appName)) but duplicate within 10s — ignoring")
            return
        }
        lastCallDetectionTime = Date()
        cancelDeparturePromptOnCallActivity()

        // Show the in-app indicator whenever a call is detected but we haven't started recording.
        detectedCallApp = appName

        if settings.autoRecord {
            // Auto-record: immediately create meeting and start recording.
            // First, check if there's a scheduled meeting within 5 minutes — use that instead of creating ad-hoc.
            isStartingMeeting = true
            fileLog("handleCallDetected: autoRecord=true, looking for scheduled meeting for \(appName)")
            Task { @MainActor in
                defer { self.isStartingMeeting = false }
                do {
                    // Re-attach first: if the meeting for this call already
                    // recorded and is still inside its reopen window, append
                    // a session instead of spawning a new row (TASK-032 —
                    // same rule as startNewMeeting).
                    if let reopenable = try await self.bestReopenableMeeting() {
                        self.fileLog("handleCallDetected: re-attaching to reopenable '\(reopenable.title)' — appending a session")
                        self.isStartingMeeting = false   // reopenRecording has its own debounce
                        self.reopenRecording(for: reopenable)
                        self.selectedMeetingId = reopenable.id
                        self.detectedCallApp = nil
                        self.loadMeetings()
                        return
                    }

                    // Look for a scheduled meeting within ±5 minutes
                    let nearbyMeetings = try await self.meetingRepository.meetingsNearDate(Date(), windowMinutes: 5)
                    let scheduledMatch = nearbyMeetings.first(where: { Self.isRecordableCalendarMatch($0) })

                    let meeting: Meeting
                    if let scheduled = scheduledMatch {
                        // Start the scheduled meeting instead of creating a new one
                        fileLog("handleCallDetected: matched scheduled meeting '\(scheduled.title)' — starting it")
                        try await self.stateMachine.startRecording(meeting: scheduled)
                        meeting = self.stateMachine.currentMeeting ?? scheduled
                    } else {
                        // No nearby scheduled meeting — create ad-hoc
                        let enriched = CalendarMeetingMatcher.enrichFromBrowserTitle(appName)
                        let title = enriched?.title ?? "\(appName) Meeting"
                        let created = try await self.stateMachine.createAndStartMeeting(title: title)

                        // Attach participant info if we got it from the browser title
                        if let participants = enriched?.participants {
                            var updated = created
                            updated.participants = participants
                            try? await self.meetingRepository.save(&updated)
                        }
                        meeting = created
                    }

                    await self.wireActiveRecordingSession()
                    self.selectedMeetingId = meeting.id
                    self.detectedCallApp = nil
                    self.recordingStartedByDetector = self.isRecording
                    self.autoRecordTriggerBundleId = self.isRecording ? bundleId : nil
                    self.loadMeetings()
                    self.fileLog("handleCallDetected: recording started for \(meeting.id) ('\(meeting.title)') trigger=\(bundleId ?? "unknown")")

                    // Notify the user that auto-recording has started
                    self.sendAutoRecordStartedNotification(meetingTitle: meeting.title)
                } catch {
                    self.fileLog("handleCallDetected: FAILED — \(error.localizedDescription)")
                    self.lastUserError = error.localizedDescription
                }
            }
        } else if settings.autoInvite {
            // Auto-invite: show a notification asking the user to start recording
            Logger.general.info("Sending recording invite for detected call: \(appName)")
            fileLog("Detection: sending notification for \(appName) (autoInvite=true)")
            sendMeetingDetectedNotification(appName: appName)
        } else {
            Logger.general.info("Call detected (\(appName)) but auto-invite and auto-record are both off")
        }
    }

    /// Send a macOS notification inviting the user to start recording.
    private func sendMeetingDetectedNotification(appName: String) {
        let content = UNMutableNotificationContent()
        content.title = "\(appName) detected"
        content.body = "Tap to start recording this meeting."
        content.sound = .default
        content.categoryIdentifier = NotificationActions.meetingDetectedCategory

        let request = UNNotificationRequest(
            identifier: "meeting-detected-\(UUID().uuidString)",
            content: content,
            trigger: nil  // deliver immediately
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Logger.general.error("Failed to send meeting notification: \(error.localizedDescription)")
            }
        }
    }

    /// Send a macOS notification that auto-recording has started.
    private func sendAutoRecordStartedNotification(meetingTitle: String) {
        let content = UNMutableNotificationContent()
        content.title = "Recording Started"
        content.body = "Now recording: \(meetingTitle)"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "auto-record-started-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Logger.general.error("Failed to send auto-record notification: \(error.localizedDescription)")
            }
        }
    }

    /// Send a macOS notification that a meeting summary is ready to share.
    func sendSummaryReadyNotification(meetingId: String, meetingTitle: String) {
        let content = UNMutableNotificationContent()
        content.title = "Summary Ready"
        content.body = "\(meetingTitle) — Tap to share the recap"
        content.sound = .default
        content.categoryIdentifier = NotificationActions.summaryReadyCategory
        content.userInfo = ["meetingId": meetingId]

        let request = UNNotificationRequest(
            identifier: "summary-ready-\(meetingId)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Logger.general.error("Failed to send summary-ready notification: \(error.localizedDescription)")
            }
        }
    }

    /// Send a macOS notification that a meeting has ended.
    private func sendMeetingEndedNotification(meetingTitle: String?) {
        let content = UNMutableNotificationContent()
        content.title = "Meeting Ended"
        if let title = meetingTitle, !title.isEmpty {
            content.body = "\(title) — recording saved. Transcribing..."
        } else {
            content.body = "Recording saved. Transcribing..."
        }
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "meeting-ended-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Logger.general.error("Failed to send meeting-ended notification: \(error.localizedDescription)")
            }
        }
    }

    // Live transcription removed — batch transcription after meeting ends is dramatically more accurate.
    // See batchTranscribe() which runs WhisperKit's sequential long-form algorithm on the complete WAV.

    // MARK: - Audio Processing

    /// Find the head/tail sample indices that bound the non-silent region of
    /// `samples`. The same bounds are applied to a parallel buffer (the
    /// system-only WAV) — keeping the diarization timeline aligned with the
    /// WhisperKit timeline after both are sliced to the same window.
    ///
    /// Returns `(0, samples.count)` when the buffer is shorter than one window
    /// or when no non-silent region is found, so callers always get a valid
    /// half-open range. nonisolated: called from the detached audio loader.
    private nonisolated static func trimSilenceBounds(_ samples: [Float], threshold: Float, windowSize: Int) -> (start: Int, end: Int) {
        guard samples.count > windowSize else { return (0, samples.count) }

        let windowCount = samples.count / windowSize

        // Find first non-silent window
        var firstNonSilent = 0
        for i in 0..<windowCount {
            let start = i * windowSize
            let end = min(start + windowSize, samples.count)
            let window = samples[start..<end]
            let rms = sqrt(window.reduce(0.0) { $0 + $1 * $1 } / Float(window.count))
            if rms > threshold {
                // Start 2 seconds before speech to give context
                firstNonSilent = max(0, (i - 2) * windowSize)
                break
            }
        }

        // Find last non-silent window
        var lastNonSilent = samples.count
        for i in stride(from: windowCount - 1, through: 0, by: -1) {
            let start = i * windowSize
            let end = min(start + windowSize, samples.count)
            let window = samples[start..<end]
            let rms = sqrt(window.reduce(0.0) { $0 + $1 * $1 } / Float(window.count))
            if rms > threshold {
                // End 2 seconds after last speech
                lastNonSilent = min(samples.count, (i + 3) * windowSize)
                break
            }
        }

        guard firstNonSilent < lastNonSilent else { return (0, samples.count) }
        return (firstNonSilent, lastNonSilent)
    }

    // MARK: - File Logging (delegates to AppFileLogger for thread-safe, date-rotated output)

    func fileLog(_ message: String) {
        AppFileLogger.shared.log(message)
    }

    // MARK: - Audio Level Polling

    /// Start a ~10Hz Combine timer that copies audio levels from AudioCaptureService into
    /// AppState properties so SwiftUI views can observe them through @Observable.
    /// AppState is @MainActor so the sink fires directly on the main queue — no Task hop needed.
    private func startAudioLevelPolling() {
        stopAudioLevelPolling()
        fileLog("Audio level polling: STARTING (isCapturing=\(audioCaptureService.isCapturing))")
        var logCounter = 0
        levelPollingCancellable = Timer.publish(every: 0.1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                // Read directly from atomic storage — bypasses @Published / MainActor scheduling
                self.micLevel = self.audioCaptureService.latestMicLevel
                self.systemLevel = self.audioCaptureService.latestSystemLevel
                // Mirror the signal-independent mic-health snapshot (TASK-095) so
                // the recording bar shows live/identity/muted status while silent.
                if self.audioCaptureService.micHealth != self.micHealth {
                    self.micHealth = self.audioCaptureService.micHealth
                }
                // Track when remote audio was last genuinely active — the
                // browser call-end keep-alive reads this (title probes can't
                // see a minimized/tab-switched meeting, but a live call keeps
                // producing system audio).
                if self.systemLevel > 0.01 {
                    self.lastActiveSystemAudioAt = Date()
                }
                // Log every ~5 seconds (50 ticks) for debugging
                logCounter += 1
                if logCounter % 50 == 1 {
                    self.fileLog("Audio levels: mic=\(String(format: "%.4f", self.micLevel)) sys=\(String(format: "%.4f", self.systemLevel)) engine.running=\(self.audioCaptureService.micCapture.engine.isRunning)")
                }
            }
    }

    private func stopAudioLevelPolling() {
        levelPollingCancellable = nil
        micLevel = 0
        systemLevel = 0
        micHealth = .unknown
    }

    // MARK: - Prep Context Pre-Computation

    /// Proactively enriches context for meetings starting in the near future
    /// so the brief is ready BEFORE the user enters the meeting.
    ///
    /// Cadence (changed from every-5-min after user feedback that 5-min was
    /// overkill — briefs only change when calendar events change):
    ///   - Once at startup
    ///   - Once on calendar-sync completion (new meeting? new brief)
    ///   - Hourly safety net for cases where the sync hook didn't fire
    ///     (long sleep/wake, app suspended, etc.)
    private func startPrepContextTimer() {
        preComputePrepContext() // Run immediately on startup
        enqueueWeeklyDigestIfDue()
        enqueueGardenerIfDue()
        enqueueGlossaryIfDue()
        // TASK-080: prune video past the retention window (no-op when the
        // feature was never used).
        Task { [weak self] in
            guard let self else { return }
            await VideoCaptureService.shared.sweepRetention(database: self.database)
        }
        // PRJ-016: prune audio past the retention window. No-op at 0 (Forever,
        // the default), so existing installs delete nothing until the user
        // opts in. Runs after cleanupStuckMeetings (init) recovered any stuck
        // recording into a non-prunable status, so in-flight audio is safe.
        Task { [weak self] in
            guard let self else { return }
            let days = self.settings.audioRetentionDays
            guard days > 0 else { return }
            _ = await AudioRetention.sweep(database: self.database, retentionDays: days)
            self.loadMeetings()
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))   // let refreshStatus land
            await self?.enqueueEmbeddingBackfillIfNeeded()
            await self?.enqueueFactBackfillIfNeeded()
            await self?.enqueueSpeechStatsBackfillIfNeeded()
            await self?.enqueueSentimentBackfillIfNeeded()
        }

        // Hourly safety net — tighter than once-a-day so a missed sync hook
        // doesn't leave the user without a brief for their afternoon meeting.
        prepContextTimerCancellable = Timer.publish(every: 3600, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.preComputePrepContext()
                self?.enqueueWeeklyDigestIfDue()
                self?.enqueueGardenerIfDue()
                self?.enqueueGlossaryIfDue()
                // Backfill re-check (TASK-045): the launch-time check can
                // lose the race against Ollama's first model-list refresh —
                // the hourly tick self-heals within the session.
                Task {
                    await self?.enqueueEmbeddingBackfillIfNeeded()
                    await self?.enqueueFactBackfillIfNeeded()
                    await self?.enqueueSpeechStatsBackfillIfNeeded()
                    await self?.enqueueSentimentBackfillIfNeeded()
                }
                // Governor backstop (TASK-055): wake any due deferred work.
                self?.taskQueueManager.reevaluate()
            }

        // Run on every calendar sync completion. This is the primary trigger:
        // when calendar sync brings in a new meeting, we want the brief ready
        // by the time the user notices the meeting in the sidebar. The
        // `.calendarBackfillCompleted` notification is posted by the existing
        // CalendarSyncManager.performSync after upserting events.
        NotificationCenter.default.publisher(for: .calendarBackfillCompleted)
            .sink { [weak self] _ in
                self?.preComputePrepContext()
            }
            .store(in: &cancellables)
    }

    /// Coalescing flag: the pre-compute pass fires from the 15-min timer AND
    /// every calendar-sync completion. A slow pass (each KB-less brief is an
    /// LLM call) can outlive the trigger interval — without this guard the
    /// passes stack and double-fire the same syntheses.
    private var isPreComputingPrepContext = false

    @MainActor
    private func preComputePrepContext() {
        // Governed caller (TASK-055 / review B2 note): this is batch LLM
        // work outside the task queue. Never contend with a live recording —
        // the recording-stop hook re-triggers via the next tick/sync.
        guard !isRecording else {
            Logger.ai.info("preComputePrepContext: recording in progress — deferred")
            return
        }
        guard !isPreComputingPrepContext else {
            Logger.ai.info("preComputePrepContext: pass already running — skipping trigger")
            return
        }
        isPreComputingPrepContext = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isPreComputingPrepContext = false }
            do {
                // 48-hour window — broad enough that "tomorrow's meetings"
                // get briefed today, narrow enough that a calendar with
                // hundreds of recurring future events doesn't flood the
                // LLM at every sync. Meetings further out get briefed
                // when they enter the 48-hour window via the next
                // calendar-sync hook or the hourly safety net.
                let upcoming = try await self.meetingRepository.meetingsStartingWithin(minutes: 48 * 60)
                let service = RelevantMeetingService(database: self.database)
                let textGen = await self.makeTextGenerator()
                var enrichedCount = 0
                for meeting in upcoming {
                    // Pass the LLM closure so the brief is actually
                    // synthesized — earlier the synthesizer was nil so the
                    // user's contextJSON had a related-meetings list but no
                    // brief prose. enrichContext writes a "Not enough
                    // information…" placeholder when neither brief nor
                    // related meetings could be produced.
                    do {
                        try await service.enrichContext(
                            meetingId: meeting.id,
                            briefSynthesizer: textGen
                        )
                        enrichedCount += 1
                    } catch {
                        Logger.ai.warning("preComputePrepContext: enrich failed for \(meeting.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    }
                }
                if enrichedCount > 0 {
                    fileLog("Prep: enriched context for \(enrichedCount)/\(upcoming.count) upcoming meeting(s)")
                }

                // Update daily brief badge so the sidebar count is accurate on launch
                // and every 5 minutes without requiring DailyBriefView to be opened first.
                let brief = try await DailyBriefService().buildBrief(for: Date())
                await MainActor.run {
                    self.dailyBriefMeetingsNeedingPrep = brief.meetingsNeedingPrep
                }

                // Regenerate the AI brief when the underlying inputs have
                // changed. Cheap when the signature is unchanged — the cache
                // already has a fresh entry, so this is just a no-op.
                await self.maybeRegenerateDailyBrief(brief: brief, force: false)
            } catch {
                fileLog("Prep: context pre-computation failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Daily AI Brief Scheduler

    /// Loads any cached AI brief for today into `dailyBriefAIText` so the
    /// view paints with content on first render. Called once at startup.
    @MainActor
    func loadCachedDailyBriefForToday() {
        let date = Date()
        guard let entry = DailyBriefCache.load(date: date) else {
            self.dailyBriefAIText = nil
            self.dailyBriefGeneratedAt = nil
            self.dailyBriefModel = nil
            self.dailyBriefKBSources = []
            self.currentDailyBriefSignature = nil
            return
        }
        self.dailyBriefAIText = entry.text
        self.dailyBriefGeneratedAt = entry.generatedAt
        self.dailyBriefModel = entry.model
        self.dailyBriefKBSources = entry.kbSources ?? []
        self.currentDailyBriefSignature = entry.signature
    }

    /// Build today's brief data and (re)generate the AI text in the background
    /// when its input signature has changed or `force` is set. Safe to call
    /// from any trigger — it coalesces concurrent calls, skips when nothing
    /// changed, and persists the result to `DailyBriefCache` on success.
    ///
    /// Triggers wired in this file:
    ///   - `preComputePrepContext` (calendar sync + hourly safety net + launch)
    ///   - `summaryCompletedHandler` (a meeting today just got a fresh summary)
    ///   - "Regenerate" button in DailyBriefView (passes `force: true`)
    @MainActor
    func maybeRegenerateDailyBrief(brief precomputed: DailyBrief? = nil, force: Bool = false) async {
        // Build the brief data if the caller didn't pre-compute it.
        let brief: DailyBrief
        if let p = precomputed { brief = p }
        else {
            do {
                brief = try await DailyBriefService().buildBrief(for: Date())
            } catch {
                Logger.ai.warning("DailyBrief: failed to assemble brief data: \(error.localizedDescription, privacy: .public)")
                return
            }
        }
        // Don't even ask the LLM if there's nothing on today's calendar.
        if brief.meetings.isEmpty {
            self.dailyBriefAIText = nil
            self.dailyBriefGeneratedAt = nil
            self.dailyBriefModel = nil
            self.dailyBriefKBSources = []
            self.currentDailyBriefSignature = nil
            DailyBriefCache.clear(date: Date())
            return
        }

        let signature = DailyBriefCache.signature(for: brief)
        if !force, signature == currentDailyBriefSignature, dailyBriefAIText != nil {
            return // Cache hit — nothing changed.
        }

        // Make sure AI is even configured before spinning up a task.
        let claudeKey = (try? KeychainHelper.loadString(forKey: KeychainHelper.Key.claudeAPIKey)) ?? ""
        let hasClaude = !claudeKey.isEmpty
        let hasOllama = ollamaService.isReachable
        guard hasClaude || hasOllama || settings.useLocalLLM else {
            // No path to a model — leave whatever is on disk and bail.
            return
        }

        // Cancel any in-flight gen with a stale signature.
        dailyBriefGenerationTask?.cancel()
        isGeneratingDailyBrief = true
        dailyBriefError = nil
        dailyBriefQueued = false

        let service = self.dailyBriefAIService
        let ollama = self.ollamaService
        let ollamaModel = settings.ollamaModel
        let claudeModel = settings.claudeModel
        let date = Date()

        dailyBriefGenerationTask = Task { [weak self] in
            do {
                let result = try await service.generate(
                    for: brief,
                    claudeAPIKey: hasClaude ? claudeKey : nil,
                    claudeModel: claudeModel,
                    ollama: ollama,
                    ollamaModel: ollamaModel,
                    date: date
                )
                guard !Task.isCancelled else { return }
                let entry = DailyBriefCache.Entry(
                    date: DailyBriefCache.dayString(for: date),
                    signature: signature,
                    text: result.text,
                    model: result.model,
                    generatedAt: Date(),
                    kbSources: result.kbSources.isEmpty ? nil : result.kbSources
                )
                DailyBriefCache.save(entry)
                await MainActor.run {
                    guard let self else { return }
                    self.dailyBriefAIText = entry.text
                    self.dailyBriefGeneratedAt = entry.generatedAt
                    self.dailyBriefModel = entry.model
                    self.dailyBriefKBSources = entry.kbSources ?? []
                    self.currentDailyBriefSignature = entry.signature
                    self.isGeneratingDailyBrief = false
                    self.dailyBriefError = nil
                    self.dailyBriefQueued = false
                }
                Logger.ai.info("DailyBrief: generated \(entry.text.count) chars via \(entry.model, privacy: .public)")
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    if error is CancellationError || (error as? URLError)?.code == .cancelled {
                        // Stale-signature cancel — a newer generation superseded
                        // this one. URLSession surfaces a cancelled in-flight
                        // request as URLError.cancelled, NOT CancellationError.
                        // Touch NO shared state here (including the
                        // isGeneratingDailyBrief flag) — it belongs to the
                        // newer run now.
                        return
                    }
                    self.isGeneratingDailyBrief = false
                    // If the task queue is busy (e.g. a bulk re-transcription is
                    // monopolizing the local model), the AI backend was reachable
                    // but couldn't serve the brief in time. Present this as
                    // "queued" rather than a hard error — it will retry once the
                    // queue drains (see the transcription handler).
                    if self.taskQueueManager.isProcessing || self.taskQueueManager.pendingCount > 0
                        || self.ollamaService.inFlightCount > 0 {
                        // TASK-071: the broker owns deferred-brief retries now
                        // (the old onQueueIdle retry was removed with it).
                        self.dailyBriefQueued = true
                        self.dailyBriefError = nil
                        self.interactiveAIBroker.submit(label: "Daily brief") { [weak self] in
                            await self?.maybeRegenerateDailyBrief(force: true)
                        }
                        Logger.ai.info("DailyBrief: deferred via broker — backend busy (\(self.ollamaService.inFlightLabel ?? "queued tasks"))")
                    } else {
                        self.dailyBriefQueued = false
                        self.dailyBriefError = error.localizedDescription
                        Logger.ai.error("DailyBrief: generation failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
        }
    }

    /// Force a single fresh enrichment pass for one meeting — used when
    /// recording starts so the brief is as up-to-date as possible going
    /// into the meeting (e.g. notes added to the calendar event in the
    /// last hour). Replaces a prior placeholder brief if a real one can
    /// now be synthesized.
    @MainActor
    func refreshContextForMeetingStart(meetingId: String) async {
        let service = RelevantMeetingService(database: self.database)
        let textGen = await self.makeTextGenerator()
        do {
            try await service.enrichContext(meetingId: meetingId, briefSynthesizer: textGen)
            Logger.ai.info("[refreshContextForMeetingStart] enriched on start for \(meetingId, privacy: .public)")
        } catch {
            Logger.ai.warning("[refreshContextForMeetingStart] enrich failed for \(meetingId, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Meeting Proximity Detection

    /// True when a meeting has at least one attendee besides the local user.
    /// Gates time-based auto-start: solo calendar blocks, focus time, and
    /// reminders (no other attendees) shouldn't auto-record. The local user is
    /// matched by signed-in Google email or macOS full name, then excluded.
    /// (Call detection is NOT gated by this — a detected live call is ground
    /// truth that a real meeting is happening, regardless of the invite list.)
    private func meetingHasOtherAttendees(_ meeting: Meeting) -> Bool {
        let userEmail = googleAuthManager.userEmail?
            .lowercased().trimmingCharacters(in: .whitespaces)
        let userName = NSFullUserName().lowercased().trimmingCharacters(in: .whitespaces)
        return meeting.participantList.contains { raw in
            let s = raw.lowercased().trimmingCharacters(in: .whitespaces)
            if let userEmail, !userEmail.isEmpty, s == userEmail { return false }
            if !userName.isEmpty, s == userName { return false }
            return true
        }
    }

    func startProximityCheck() {
        checkUpcomingMeetings() // Run immediately
        proximityPollingCancellable = Timer.publish(every: 30, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.checkUpcomingMeetings()
            }
    }

    func stopProximityCheck() {
        proximityPollingCancellable = nil
    }

    @MainActor
    private func checkUpcomingMeetings() {
        let now = Date()
        let warningWindow: TimeInterval = Double(settings.notificationLeadTimeMinutes * 60)

        // Prune IDs that are no longer in the upcoming list
        let currentIds = Set(upcomingMeetings.map(\.id))
        notifiedMeetingIds = notifiedMeetingIds.intersection(currentIds)
        hudShownMeetingIds  = hudShownMeetingIds.intersection(currentIds)
        autoJoinedMeetingIds = autoJoinedMeetingIds.intersection(currentIds)
        dismissedSwitchMeetingIds = dismissedSwitchMeetingIds.intersection(currentIds)

        // Clear an outstanding switch offer if it no longer applies.
        if let pendingId = pendingSwitchMeetingId {
            let stillValid: Bool = {
                guard isRecording, activeMeeting?.id != pendingId else { return false }
                guard let m = upcomingMeetings.first(where: { $0.id == pendingId }),
                      let start = m.scheduledStartDate else { return false }
                let dt = start.timeIntervalSince(now)
                return dt > -300 && dt <= 75
                    && (m.status == .scheduled || m.status == .notified)
                    && (m.meetLink?.isEmpty == false)
            }()
            if !stillValid {
                pendingSwitchMeetingId = nil
                NotificationCenter.default.post(name: .meetingSwitchDismiss, object: nil)
            }
        }

        // Diagnostic: log the closest upcoming meeting on every poll so we can
        // see why the HUD isn't firing in real-world use.
        let nearest = upcomingMeetings
            .compactMap { m -> (Meeting, TimeInterval)? in
                guard let s = m.scheduledStartDate else { return nil }
                let dt = s.timeIntervalSince(now)
                return dt > -300 ? (m, dt) : nil
            }
            .min(by: { $0.1 < $1.1 })
        if let (m, dt) = nearest {
            fileLog("Proximity poll: nearest='\(m.title)' in \(Int(dt))s status=\(m.status.rawValue) hudShown=\(hudShownMeetingIds.contains(m.id)) link=\(m.meetLink?.isEmpty == false)")
        } else {
            fileLog("Proximity poll: no upcoming meetings within window (\(upcomingMeetings.count) loaded)")
        }

        for meeting in upcomingMeetings {
            guard let startDate = meeting.scheduledStartDate else { continue }
            // Same eligibility as recording attach (TASK-043): all-day blocks
            // and events with no attendees AND no meeting link are calendar
            // furniture (focus time, "Home" work-location rows, untitled
            // placeholders) — if we wouldn't attach a recording to it, we
            // don't nag about it either. "Untitled Event" got a pre-meeting
            // notification on 2026-06-09; this is what stops that.
            guard Self.isRecordableCalendarMatch(meeting) else { continue }
            let timeUntilStart = startDate.timeIntervalSince(now)

            // Meeting starting within the notification window — post only once per meeting
            if timeUntilStart > 0, timeUntilStart <= warningWindow,
               meeting.status == .scheduled || meeting.status == .notified,
               notifiedMeetingIds.insert(meeting.id).inserted {
                NotificationCenter.default.post(
                    name: .meetingStartingSoon,
                    object: nil,
                    userInfo: ["meetingId": meeting.id, "minutesUntilStart": Int(timeUntilStart / 60)]
                )
                Logger.general.debug("Meeting '\(meeting.title)' starting in \(Int(timeUntilStart / 60)) minutes")
            }

            // HUD panel: always show at ~1 minute before, independent of the
            // lead-time notification setting. Window is 120s so the 30s poll
            // reliably catches it even if a tick lands at the boundary or the
            // timer drifts. Accepts .notified status too — a call app launch
            // can advance the meeting to .notified before the window opens.
            if timeUntilStart > 0, timeUntilStart <= 120,
               meeting.status == .scheduled || meeting.status == .notified,
               hudShownMeetingIds.insert(meeting.id).inserted {
                NotificationCenter.default.post(
                    name: .meetingHUDShow,
                    object: nil,
                    userInfo: ["meetingId": meeting.id]
                )
                fileLog("HUD: posted .meetingHUDShow for '\(meeting.title)' (in \(Int(timeUntilStart))s)")
            }

            // Auto-join at lead time: if user has autoRecord on and the meeting
            // has a meet link, proactively open the link and start recording
            // ~60s before scheduled start. Falls back to nothing if no link
            // (we don't auto-record offline meetings — too aggressive).
            //
            // Window is 75s so the 30s polling cadence catches it reliably
            // even if a tick lands at the boundary. Once fired, the meeting
            // goes into autoJoinedMeetingIds and won't be retriggered by
            // the post-start auto-start path below.
            if settings.autoRecord,
               timeUntilStart > 0 && timeUntilStart <= 75,
               let meetLink = meeting.meetLink, !meetLink.isEmpty,
               meetingHasOtherAttendees(meeting),
               (meeting.status == .scheduled || meeting.status == .notified),
               !isRecording, !isStartingMeeting,
               autoJoinedMeetingIds.insert(meeting.id).inserted {
                Logger.notifications.info("[autoJoin] firing for '\(meeting.title, privacy: .public)' meetingId=\(meeting.id, privacy: .public) timeUntilStart=\(Int(timeUntilStart))s link=\(meetLink, privacy: .public)")
                if let url = URL(string: meetLink) {
                    let opened = NSWorkspace.shared.open(url)
                    Logger.notifications.info("[autoJoin] NSWorkspace.open returned \(opened)")
                } else {
                    Logger.notifications.warning("[autoJoin] meetLink is not a valid URL: \(meetLink, privacy: .public)")
                }
                startRecording(for: meeting)
            } else if settings.autoRecord,
                      timeUntilStart > -300 && timeUntilStart <= 75,
                      (meeting.status == .scheduled || meeting.status == .notified),
                      meeting.meetLink?.isEmpty == false,
                      isRecording,
                      activeMeeting?.id != meeting.id,
                      !dismissedSwitchMeetingIds.contains(meeting.id),
                      pendingSwitchMeetingId != meeting.id {
                // Already recording a different meeting; offer to switch
                // instead of silently skipping. The banner persists until
                // the user acts on it (handled by AppDelegate observer).
                pendingSwitchMeetingId = meeting.id
                fileLog("Switch: offering switch from '\(activeMeeting?.title ?? "?")' to '\(meeting.title)' (in \(Int(timeUntilStart))s)")
                NotificationCenter.default.post(
                    name: .meetingSwitchShow,
                    object: nil,
                    userInfo: ["meetingId": meeting.id]
                )
            }

            // Auto-start: if meeting should have started (within 0-5 min past start) and we're not recording.
            // The 5-minute window accommodates meetings that start slightly late.
            // Accepts .notified too — call-app-launch can advance status before the start window.
            // Skip if we already auto-joined at lead time.
            // Only auto-start meetings with at least one OTHER attendee — solo
            // calendar blocks, focus time, and reminders shouldn't auto-record.
            // (This is the at-start fallback path; the lead-time auto-join above
            // applies the same gate. Live call detection stays ungated.)
            if timeUntilStart >= -300 && timeUntilStart <= 0
                && (meeting.status == .scheduled || meeting.status == .notified)
                && meetingHasOtherAttendees(meeting)
                && !isRecording && !isStartingMeeting
                && !autoJoinedMeetingIds.contains(meeting.id) {
                Logger.general.debug("Auto-starting recording for meeting: \(meeting.title)")
                startRecording(for: meeting)
            }
        }
    }

    // MARK: - Task Notifications (PRJ-013 Phase 5)

    /// Reconcile per-task due alerts against the current live, dated, incomplete
    /// task set. Honors the "Alert me when a task is due" setting — when off, all
    /// pending per-task alerts are cancelled. Driven by `.taskDataDidChange` and
    /// run once at launch.
    func refreshTaskNotifications() async {
        let enabled = settings.taskDueAlertsEnabled
        let candidates = (try? await taskRepository.notificationCandidates()) ?? []
        await notificationService.rescheduleAllTaskNotificationsAsync(tasks: candidates, enabled: enabled)
    }

    // MARK: - Notification Observers

    private func observeNotifications() {
        // Create ad-hoc meeting via state machine (manual "New Meeting" button, menu bar,
        // HomeView, AppDelegate). All paths route through startNewMeeting() for one code path.
        NotificationCenter.default.publisher(for: .createNewMeeting)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.startNewMeeting()
                }
            }
            .store(in: &cancellables)

        // Task data changed (PRJ-013 Phase 5) — reconcile per-task due alerts.
        // Debounced so a bulk operation (e.g. accept-all) triggers one reconcile.
        NotificationCenter.default.publisher(for: .taskDataDidChange)
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    await self?.refreshTaskNotifications()
                }
            }
            .store(in: &cancellables)

        // Switch banner action: stop the current recording and start the new
        // meeting (opens its meet link too if present).
        NotificationCenter.default.publisher(for: .switchToMeeting)
            .sink { [weak self] notification in
                guard let self,
                      let meetingId = notification.userInfo?["meetingId"] as? String,
                      let meeting = self.upcomingMeetings.first(where: { $0.id == meetingId })
                else { return }
                Task { @MainActor in
                    await self.switchActiveMeeting(to: meeting)
                }
            }
            .store(in: &cancellables)

        // User dismissed the switch banner — remember it so we don't re-offer.
        NotificationCenter.default.publisher(for: .meetingSwitchDismiss)
            .sink { [weak self] notification in
                guard let self else { return }
                if let id = notification.userInfo?["dismissedByUser"] as? String {
                    self.dismissedSwitchMeetingIds.insert(id)
                }
                self.pendingSwitchMeetingId = nil
            }
            .store(in: &cancellables)

        // Settings → Prompts edits the summary prompt template directly in the
        // DB via PromptManager.saveTemplate. Refresh the in-memory snapshot so
        // the next summary generation picks up the new template instead of the
        // stale cached value.
        NotificationCenter.default.publisher(for: .summaryPromptTemplateDidChange)
            .sink { [weak self] _ in
                self?.loadSettings()
            }
            .store(in: &cancellables)

        // Calendar backfill (Settings → "Re-sync 90 days") finished — reload
        // meetings so PeopleView and the sidebar pick up freshly-attached
        // participants without requiring a navigation round-trip.
        NotificationCenter.default.publisher(for: .calendarBackfillCompleted)
            .sink { [weak self] _ in
                self?.loadMeetings()
            }
            .store(in: &cancellables)

        // Call app detected — decide auto-record vs notification based on settings
        NotificationCenter.default.publisher(for: .callAppLaunched)
            .sink { [weak self] notification in
                guard let self else { return }
                let appName = notification.userInfo?["appName"] as? String ?? "Meeting"
                let bundleId = notification.userInfo?["bundleIdentifier"] as? String
                Task { @MainActor in
                    self.handleCallDetected(appName: appName, bundleId: bundleId)
                }
            }
            .store(in: &cancellables)

        // Call app closed — auto-stop recording only if it was detector-started
        // AND the terminated app is the one that triggered the recording.
        // Manually-started recordings must never be stopped by the browser detector
        // losing signal, and an unrelated call app quitting (Teams self-updating,
        // Zoom's CptHost ending a screen share) must not kill the recording.
        NotificationCenter.default.publisher(for: .callAppTerminated)
            .sink { [weak self] notification in
                guard let self else { return }
                let terminatedBundleId = notification.userInfo?["bundleIdentifier"] as? String
                Task { @MainActor in
                    if self.isRecording && self.recordingStartedByDetector {
                        if let trigger = self.autoRecordTriggerBundleId,
                           let terminated = terminatedBundleId,
                           trigger != terminated {
                            Logger.general.info("Call app \(terminated) ended but recording was triggered by \(trigger) — keeping recording alive")
                            return
                        }
                        // Browser "ended" verdicts come from title probes,
                        // which go blind when the meeting tab is minimized or
                        // backgrounded (the mic-usage probe is suppressed
                        // while we record). A live call keeps producing
                        // remote audio — require recent system-audio silence
                        // before trusting a browser end signal.
                        if terminatedBundleId == "browser.googleMeet",
                           let lastActive = self.lastActiveSystemAudioAt,
                           Date().timeIntervalSince(lastActive) < 45 {
                            Logger.general.info("Browser call 'ended' but remote audio was active \(Int(Date().timeIntervalSince(lastActive)))s ago — keeping recording alive")
                            return
                        }
                        self.detectedCallApp = nil
                        Logger.general.info("Call ended — auto-stopping detector-started recording")
                        self.stopRecording()
                    } else {
                        self.detectedCallApp = nil
                        if self.isRecording {
                            // TASK-072: don't silently keep rolling — the call
                            // this recording was covering looks over. Same
                            // remote-audio guard as the detector path: title
                            // probes go blind on minimized tabs, but a live
                            // call keeps producing system audio.
                            if let lastActive = self.lastActiveSystemAudioAt,
                               Date().timeIntervalSince(lastActive) < 45 {
                                Logger.general.info("Call 'ended' (manual recording) but remote audio active recently — ignoring")
                            } else {
                                self.beginDepartureConfirmation()
                            }
                        }
                    }
                }
            }
            .store(in: &cancellables)

        // External start/stop requests (⌘ shortcut, menu-bar item, notification
        // actions, sidebar banner). Routed through AppState — NOT the state
        // machine — so every entry point gets the full per-recording wiring
        // (transcription enqueue on stop, level polling, participant detection).
        NotificationCenter.default.publisher(for: .startRecording)
            .sink { [weak self] notification in
                guard let self else { return }
                let meetingId = notification.userInfo?["meetingId"] as? String
                Task { @MainActor in
                    guard !self.isRecording else { return }
                    if let meetingId {
                        if let meeting = try? await self.meetingRepository.find(id: meetingId) {
                            self.startOrReopenRecording(for: meeting)
                        } else {
                            Logger.notifications.warning("startRecording notification: meeting \(meetingId, privacy: .public) not found")
                        }
                    } else {
                        self.startNewMeeting()
                    }
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .stopRecording)
            .sink { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    // AppState.stopRecording itself re-posts .stopRecording as a
                    // "recording stopped" broadcast after isRecording is already
                    // false — this guard is what breaks that cycle.
                    guard self.isRecording else { return }
                    self.stopRecording()
                }
            }
            .store(in: &cancellables)

        // Sync local state when the state machine posts a change
        NotificationCenter.default.publisher(for: .meetingStateChanged)
            .sink { [weak self] notification in
                guard let self else { return }
                Task { @MainActor in
                    let wasRecording = self.isRecording
                    self.activeMeeting = self.stateMachine.currentMeeting
                    self.isRecording = self.stateMachine.isRecording
                    self.loadMeetings()

                    // Transcription runs after meeting ends (batch mode for better accuracy)
                }
            }
            .store(in: &cancellables)

        // Thermal pressure: log escalations so ops can correlate with transcription
        // backlog / audio drop reports. At .serious or .critical we back off any
        // post-meeting transcription tasks that are still queued so the user's
        // interactive recording path stays responsive.
        NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                let state = ProcessInfo.processInfo.thermalState
                let stateName: String
                switch state {
                case .nominal: stateName = "nominal"
                case .fair: stateName = "fair"
                case .serious: stateName = "serious"
                case .critical: stateName = "critical"
                @unknown default: stateName = "unknown"
                }
                Logger.general.info("Thermal state: \(stateName, privacy: .public)")
                Task { @MainActor in
                    self.thermalState = state
                }
            }
            .store(in: &cancellables)
    }

    /// Mirrored from ProcessInfo so SwiftUI views can observe and downgrade heavy
    /// visual effects (live waveforms, animations) under thermal pressure.
    var thermalState: ProcessInfo.ThermalState = .nominal

    // MARK: - AI Text Generator Factory

    /// Creates a text generator closure that routes to Claude or Ollama based on current settings.
    /// Used by GlobalChatView and other global AI features.
    func makeTextGenerator(
        maxOutputTokens: Int = 2048,
        think: Bool = true,
        jsonMode: Bool = false,
        schemaJSON: String? = nil,  // Ollama grammar-constrained output
                                    // (TASK-046); the Claude path ignores it
                                    // — cloud callers keep prompt-only JSON.
        activityLabel: String? = nil // Activities-list label (TASK-073)
    ) async -> ((String, String) async throws -> String)? {
        let backend = await resolveAIBackend(refreshOllama: true)

        // Map the unified output budget to each backend's parameter:
        //   Ollama → num_predict
        //   Claude → max_tokens (Claude's native cap; default in API is 4096
        //            but the new Sonnet models accept up to 64K)
        // 2048 is fine for summary, action items, attribution, follow-up
        // email. The detailed outline path passes 16384 because hour-long
        // meetings produce 8–12k tokens of structured output and the prior
        // 4096/2048 caps were silently truncating mid-meeting.
        let claudeMaxTokens = max(maxOutputTokens, 4096)

        switch backend {
        case .ollama(let ollamaModel):
            let service = ollamaService
            return { sys, usr in
                try await service.generate(
                    systemPrompt: sys,
                    userPrompt: usr,
                    model: ollamaModel,
                    maxOutputTokens: maxOutputTokens,
                    think: think,
                    jsonMode: jsonMode,
                    schemaJSON: schemaJSON,
                    activityLabel: activityLabel
                )
            }
        case .claude(let claudeModel):
            let claude = ClaudeService()
            return { sys, usr in
                try await claude.sendMessage(
                    systemPrompt: sys,
                    userPrompt: usr,
                    model: claudeModel,
                    maxTokens: claudeMaxTokens,
                    redactor: await self.cloudRedactorIfEnabled(texts: [sys, usr])
                )
            }
        case .gemini(let geminiModel):
            // Mirrors the .claude branch, but threads `think` into Gemini's
            // thinkingConfig (Gemini 2.5 supports it; Claude has no such param),
            // so callers that pass think:false get fast non-thinking output.
            let gemini = GeminiService()
            return { sys, usr in
                try await gemini.sendMessage(
                    systemPrompt: sys,
                    userPrompt: usr,
                    model: geminiModel,
                    maxTokens: claudeMaxTokens,
                    thinking: think,
                    redactor: await self.cloudRedactorIfEnabled(texts: [sys, usr])
                )
            }
        case .none:
            return nil
        }
    }

    /// Groups all meetings (past + upcoming) into recurring-series "folders" by normalised base title.
    /// Result is cached and invalidated whenever `upcomingMeetings` or `pastMeetings` change.
    /// A folder is only created if 2+ meetings share the same base title.
    func meetingFolders() -> [MeetingFolder] {
        // The cache is filled from the WHOLE meeting table by loadMeetings —
        // grouping over the in-memory window (50 past meetings) hid 39 of
        // the table's 44 recurring series because instances aged out before
        // reaching the 2-instance threshold (TASK-036). The in-memory
        // grouping below is only the first-render fallback before the full
        // rebuild lands.
        if let cached = _cachedFolders { return cached }
        return MeetingFolder.group(upcomingMeetings + pastMeetings)
    }

    /// Aggregates all unique participants across all meetings, returning (name, [Meeting]) pairs.
    func allPeople() -> [(name: String, meetings: [Meeting])] {
        var map: [String: [Meeting]] = [:]
        for meeting in meetings {
            for person in meeting.participantList {
                let key = person.trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty else { continue }
                map[key, default: []].append(meeting)
            }
        }
        return map.map { (name: $0.key, meetings: $0.value) }
            .sorted { a, b in
                // Sort by most meetings, then alphabetically
                if a.meetings.count != b.meetings.count { return a.meetings.count > b.meetings.count }
                return a.name < b.name
            }
    }

    // MARK: - Calendar Sync Bootstrapping

    /// Boots the periodic calendar sync if the user has chosen a source.
    ///
    /// Runs in a detached Task so it doesn't block init: the manager itself
    /// fires its first sync immediately and schedules the recurring timer.
    /// Also subscribes to settings changes so flipping the sync interval
    /// restarts the timer with the new cadence.
    private func startCalendarSync() {
        Task {
            let source = CalendarSource.current
            guard source != .none else {
                Logger.calendar.info("Calendar sync not started — source is .none")
                return
            }
            let intervalSeconds = TimeInterval(max(1, self.settings.calendarSyncIntervalMinutes) * 60)
            await self.calendarSyncManager.startPeriodicSync(interval: intervalSeconds)
        }
    }
}

// MARK: - Sidebar Navigation Destination

enum SidebarDestination: Hashable {
    case home
    case dailyBrief
    case chat
    case people
    case activity        // background-job queue (TaskQueueManager) — renamed from .tasks (PRJ-013)
    case taskBoard       // PRJ-013: user task manager (distinct from .activity = background-job Activity)
    case search
    case meetings
    case analytics
    case keyQuotes       // TASK-078: saved clips across all meetings
    case topics          // TASK-081: topic trackers across all meetings
    case knowledgeBase   // PRJ-014: KB viewer/editor; gated on AppState.kbConfigured
    case folder(String)  // folder key = normalised base title
}

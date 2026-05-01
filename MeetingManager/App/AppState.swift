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
    var isRecording = false
    var activeMeeting: Meeting?

    /// The resolved template for the current/most-recently-started recording.
    /// Set when recording starts (from meeting.templateId or series inheritance).
    /// Read by LiveMeetingView to pre-populate the notepad.
    var activeTemplate: MeetingTemplate?

    /// True only when the current recording was auto-started by BrowserCallDetector.
    /// Used to gate `callAppTerminated` auto-stop — manually-started recordings
    /// must not be stopped just because the browser-call heuristic loses signal.
    private var recordingStartedByDetector = false

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
    private var _cachedFolders: [MeetingFolder]?
    var navigationPath = NavigationPath()

    /// The count of today's meetings that need prep (carryOver category).
    /// Updated when the Daily Brief view loads. Used for the sidebar badge.
    var dailyBriefMeetingsNeedingPrep: Int = 0

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
            if settings.notificationLeadTimeMinutes != oldValue.notificationLeadTimeMinutes {
                notificationService.rescheduleAll(
                    meetings: upcomingMeetings,
                    leadTimeMinutes: settings.notificationLeadTimeMinutes
                )
            }
            if settings.calendarSyncIntervalMinutes != oldValue.calendarSyncIntervalMinutes {
                let intervalSeconds = TimeInterval(max(1, settings.calendarSyncIntervalMinutes) * 60)
                Task {
                    await self.calendarSyncManager.startPeriodicSync(interval: intervalSeconds)
                }
            }
        }
    }

    // Services
    let database: AppDatabase
    let ollamaService: OllamaService
    let ollamaInstaller: OllamaInstaller
    let meetingRepository: MeetingRepository
    let transcriptRepository: TranscriptRepository
    let noteRepository: NoteRepository
    let summaryRepository: SummaryRepository
    let audioCaptureService: AudioCaptureService
    let transcriptionService: TranscriptionService
    let streamingTranscriber: StreamingTranscriber
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

    /// Meetings queued for transcription when model wasn't available.
    /// Persisted via UserDefaults so they survive app restarts.
    private static let pendingTranscriptionKey = "pendingTranscriptions"

    private var cancellables = Set<AnyCancellable>()
    private var proximityPollingCancellable: AnyCancellable?
    private var prepContextTimerCancellable: AnyCancellable?

    /// Tracks meetings for which a `meetingStartingSoon` notification has already been posted.
    /// Prevents posting 4+ duplicates across timer ticks for the same meeting.
    private var notifiedMeetingIds: Set<String> = []

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
            self.ollamaInstaller = existing.ollamaInstaller
            self.meetingRepository = existing.meetingRepository
            self.transcriptRepository = existing.transcriptRepository
            self.noteRepository = existing.noteRepository
            self.summaryRepository = existing.summaryRepository
            self.audioCaptureService = existing.audioCaptureService
            self.transcriptionService = existing.transcriptionService
            self.streamingTranscriber = existing.streamingTranscriber
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

            AppState.shared = self
            fileLog("AppState re-created by SwiftUI — reusing existing services (model loaded: \(transcriptionService.isModelLoaded))")
            return
        }

        self.database = AppDatabase.shared
        if let dbError = AppDatabase.initializationError {
            Logger.general.critical("AppState: database unavailable at launch — \(dbError)")
            self.lastUserError = "The database could not be opened (\(dbError.localizedDescription)). Your meeting data is unavailable. Please restart the app or contact support."
        }
        self.ollamaService = OllamaService()
        self.ollamaInstaller = OllamaInstaller()
        self.meetingRepository = MeetingRepository(database: database)
        self.transcriptRepository = TranscriptRepository(database: database)
        self.noteRepository = NoteRepository(database: database)
        self.summaryRepository = SummaryRepository(database: database)
        self.audioCaptureService = AudioCaptureService()

        let txService = TranscriptionService()
        self.transcriptionService = txService
        self.streamingTranscriber = StreamingTranscriber(transcriptionService: txService)
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

        loadMeetings()
        loadSettings()
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
        // One-shot retroactive speaker attribution scan (gated by UserDefaults
        // flag — only runs once per app upgrade). Re-attributes existing
        // meetings against the loosened fuzzy matcher + auto-mic mapping
        // introduced in v3.4.1.
        runRetroactiveSpeakerAttributionIfNeeded()

        // Knowledge Base: if the user has previously chosen a folder, start
        // its FSEvents watcher and kick off a background re-index so the FTS
        // table reflects any external edits made while the app was closed.
        if let kbRoot = KnowledgeBaseService.shared.rootURL {
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

        // Make this instance accessible to AppDelegate for the menu bar popover
        AppState.shared = self
        AppState.isInitialized = true

        fileLog("AppState initialized — starting model download")
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
                let leadTime = await MainActor.run { self.settings.notificationLeadTimeMinutes }
                self.notificationService.rescheduleAll(meetings: upcoming, leadTimeMinutes: leadTime)
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
        taskQueueManager.transcriptionHandler = { [weak self] meetingId, audioURL in
            guard let self else { return }
            self.fileLog("TaskQueue: running transcription for \(meetingId)")
            let (rawTranscripts, speakerLabels) = await self.batchTranscribe(meetingId: meetingId, audioURL: audioURL)

            // Atomically commit transcripts + meeting-status update + speaker labels in one write.
            // Previously three separate writer.write calls; now a single transaction so a crash
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
                let (transcripts, attributedMeeting) = await self.applySpeakerAttribution(
                    transcripts: rawTranscripts,
                    meeting: meeting
                )
                meeting = attributedMeeting

                let wasTranscribing = meeting.status == .transcribing
                if wasTranscribing { meeting.status = .complete }

                let commitSucceeded: Bool
                do {
                    try await self.database.writer.write { db in
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

                self.loadMeetings()
            }
        }

        taskQueueManager.summaryHandler = { [weak self] meetingId in
            guard let self else { return }
            self.fileLog("TaskQueue: running summary for \(meetingId)")
            try await self.generateSummaryForTask(meetingId: meetingId)
            self.loadMeetings()
        }

        taskQueueManager.diarizationHandler = { [weak self] meetingId, systemAudioURL in
            guard let self else { return }
            self.fileLog("TaskQueue: diarization starting for \(meetingId)")
            await self.runDiarization(meetingId: meetingId, systemAudioURL: systemAudioURL)
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
        }

        taskQueueManager.knowledgeBaseIndexHandler = {
            await KnowledgeBaseService.shared.reindex()
        }

        // Wire the KB service back to the queue so enqueueReindex() routes through it.
        KnowledgeBaseService.shared.taskQueue = taskQueueManager

        // Transcript cleanup: stitch + best-effort AI pass.
        // Runs after batch transcription completes (enqueued from the
        // transcription handler). Best-effort AI — falls back to
        // stitch-only when no model is configured or the call fails.
        taskQueueManager.transcriptCleanupHandler = { [weak self] meetingId in
            guard let self else { return }
            await self.runTranscriptCleanup(meetingId: meetingId)
        }

        // Start the queue (recovers stuck tasks, enqueues orphans, begins processing)
        Task {
            await taskQueueManager.startUp()
        }
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
        let rawTemplate: String
        if let recipeId,
           let recipe = try? await RecipeRepository(database: database).find(id: recipeId) {
            rawTemplate = recipe.promptTemplate
        } else {
            rawTemplate = settings.summaryPromptTemplate
        }

        let baseSystemPrompt = rawTemplate
            .replacingOccurrences(of: "{{meetingTitle}}", with: meeting.title)
            .replacingOccurrences(of: "{{date}}", with: meeting.startDate?.formatted() ?? "Unknown")
            .replacingOccurrences(of: "{{duration}}", with: meeting.formattedDuration)
            .replacingOccurrences(of: "{{transcript}}", with: "")
            .replacingOccurrences(of: "{{notes}}", with: "")

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
            systemPrompt = baseSystemPrompt
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
            systemPrompt = baseSystemPrompt + """


            The user captured notes during this meeting — treat these notes as ground truth and \
            anchor the summary around them. Use the transcript to fill in details, context, and \
            action items the user may have missed. Do not contradict the notes.
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

        // Determine which AI backend to use
        let hasClaudeKey = ((try? KeychainHelper.loadString(forKey: KeychainHelper.Key.claudeAPIKey)) ?? "")?.isEmpty == false
        await ollamaService.refreshStatus()
        let ollamaReachable = ollamaService.isReachable
        let useOllama = settings.useLocalLLM || (!hasClaudeKey && ollamaReachable)

        let summaryText: String
        if useOllama {
            // Use streaming for task queue — never times out, reads chunks incrementally
            summaryText = try await ollamaService.generateStreaming(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                model: settings.ollamaModel
            )
        } else if hasClaudeKey {
            let claude = ClaudeService()
            summaryText = try await claude.sendMessage(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                model: settings.claudeModel
            )
        } else {
            throw TaskQueueError.noHandler("No AI backend available (Ollama not running, no Claude key)")
        }

        // Save summary
        var summary = MeetingSummary(
            meetingId: meetingId,
            promptUsed: systemPrompt,
            summaryText: summaryText,
            modelUsed: useOllama ? "ollama/\(settings.ollamaModel)" : settings.claudeModel
        )
        try await summaryRepository.save(&summary)
        fileLog("TaskQueue: summary saved for \(meetingId) (\(summaryText.count) chars)")
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

        let (relabelled, updated) = await applySpeakerAttribution(
            transcripts: transcripts,
            meeting: meeting
        )

        // Persist relabelled transcripts + speakerMap update atomically.
        do {
            try await database.writer.write { db in
                for t in relabelled {
                    var copy = t
                    try copy.update(db)
                }
                var m = updated
                try m.update(db)
            }
            Logger.general.info("rerunSpeakerAttribution: persisted updates for \(meetingId)")
        } catch {
            Logger.general.error("rerunSpeakerAttribution: persist failed: \(error.localizedDescription, privacy: .public)")
        }

        // Cross-meeting learning: feed any newly-confirmed names into the
        // voice-profile DB so future meetings recognise them without an LLM
        // call. No-op when the meeting has no system audio file.
        await learnVoiceProfiles(meetingId: meetingId)
    }

    /// One-time retroactive speaker-attribution scan. Runs at most once per
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

    /// P5-T02: Loads open action items for a set of prior meetings, preserving order.
    /// Used by the summary prompt to carry forward unfinished items across a series.
    private func fetchOpenActionItems(for meetings: [Meeting]) async -> [(Meeting, [ActionItem])] {
        let repo = ActionItemRepository(database: database)
        var result: [(Meeting, [ActionItem])] = []
        for m in meetings {
            let items = (try? await repo.itemsForMeeting(m.id)) ?? []
            let open = items.filter { !$0.isCompleted }
            if !open.isEmpty { result.append((m, open)) }
        }
        return result
    }

    /// - Stuck recordings WITHOUT audio → cancel (nothing to transcribe)
    /// - Stuck transcribing → re-run batch transcription if audio exists, else complete
    private func cleanupStuckMeetings() {
        Task {
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
                        if let path = m.audioFilePaths.last,
                           FileManager.default.fileExists(atPath: path),
                           let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                           (attrs[.size] as? Int ?? 0) > 44 {
                            // Has audio with real content — transition to transcribing
                            m.status = .transcribing
                            try m.update(db)
                            toTranscribe.append(m)
                        } else {
                            // No audio or only WAV header — reset to scheduled so user can re-record
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
    private var isStartingMeeting = false

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
                let nearby = try await self.meetingRepository.meetingsNearDate(Date(), windowMinutes: 5)
                let scheduledMatch = nearby.first(where: { $0.status == .scheduled || $0.status == .notified })

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

                self.activeMeeting = self.stateMachine.currentMeeting
                self.isRecording = self.stateMachine.isRecording
                self.selectedMeetingId = meeting.id
                if self.isRecording { self.startAudioLevelPolling() }
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
                self.activeMeeting = self.stateMachine.currentMeeting
                self.isRecording = self.stateMachine.isRecording
                self.selectedMeetingId = self.stateMachine.currentMeeting?.id
                self.detectedCallApp = nil
                self.startAudioLevelPolling()

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

                // Surface audio write errors to the user (e.g. disk full)
                self.audioCaptureService.onWriteError = { [weak self] error in
                    Task { @MainActor [weak self] in
                        self?.lastUserError = "Audio write error: \(error.localizedDescription). Recording may be incomplete."
                    }
                }

                // Wire Apple Speech fallback if WhisperKit is unavailable
                if self.transcriptionService.transcriptionMode == .appleSpeech,
                   let meetingId = self.stateMachine.currentMeeting?.id {
                    self.audioCaptureService.onRawMicBuffer = { [weak self] buffer in
                        self?.appleSpeechTranscriber.appendBuffer(buffer)
                    }
                    self.appleSpeechTranscriber.start(meetingId: meetingId, repository: self.transcriptRepository)
                    self.fileLog("Apple Speech fallback wired for meeting \(meetingId)")
                }

                // Start participant detection if calendar didn't provide attendees.
                // Calendar attendees are written to meeting.participants during sync;
                // if still empty here, fall back to screen/window title detection.
                if let meetingId = self.stateMachine.currentMeeting?.id {
                    let currentParticipants = self.stateMachine.currentMeeting?.participantList ?? []
                    let service = ParticipantDetectionService(
                        meetingRepository: self.meetingRepository,
                        database: self.database
                    )
                    self.participantDetectionService = service
                    service.start(meetingId: meetingId, existingParticipants: currentParticipants)
                }

                // Resolve template: use meeting's own templateId, or inherit from series.
                self.activeTemplate = await self.resolveTemplate(for: meeting)

                loadMeetings()
                fileLog("Recording started for meeting \(self.stateMachine.currentMeeting?.id ?? "?")")
            } catch {
                Logger.general.error("Failed to start recording: \(error.localizedDescription)")
                self.lastUserError = error.localizedDescription
            }
        }
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
                self.activeMeeting = self.stateMachine.currentMeeting
                self.isRecording = self.stateMachine.isRecording
                self.isReopening = true
                self.selectedMeetingId = self.stateMachine.currentMeeting?.id
                self.startAudioLevelPolling()
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

    /// Stop recording — then run batch transcription on the complete audio file.
    /// Batch transcription is dramatically more accurate than live streaming because
    /// Whisper can use the full audio context and sequential decoding.
    ///
    /// IMPORTANT: State updates and notifications fire IMMEDIATELY so the UI and
    /// menu bar reflect the correct state. Batch transcription runs in a separate
    /// detached task so it never interferes with a subsequent recording.
    func stopRecording() {
        // Warn user if transcription model isn't ready yet
        if !transcriptionService.isModelLoaded {
            lastUserError = "The transcription model is still downloading. Your audio has been saved and will be transcribed once the download completes."
        }

        Task {
            do {
                // Save references before stopRecording clears them
                let stoppedMeeting = stateMachine.currentMeeting
                let stoppedMeetingId = stoppedMeeting?.id
                let audioURL = audioCaptureService.currentAudioFileURL

                try await stateMachine.stopRecording()
                self.activeMeeting = self.stateMachine.currentMeeting
                self.isRecording = self.stateMachine.isRecording
                self.recordingStartedByDetector = false
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
                Logger.general.error("Failed to stop recording: \(error.localizedDescription)")
                self.lastUserError = error.localizedDescription
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

    /// Batch-transcribe a complete WAV file using WhisperKit's sequential long-form algorithm.
    /// Returns the filtered transcripts and diarisation speaker labels to the caller, which
    /// is responsible for the atomic DB write (see transcriptionHandler in setupTaskQueue).
    private func batchTranscribe(meetingId: String, audioURL: URL?) async -> (transcripts: [Transcript], speakerLabels: String?) {
        guard let audioURL else {
            fileLog("Batch transcribe: no audio file URL")
            return ([], nil)
        }

        if !transcriptionService.isModelLoaded {
            fileLog("Batch transcribe: model not loaded, waiting up to 5 min...")
            for _ in 0..<300 {
                try? await Task.sleep(for: .seconds(1))
                if transcriptionService.isModelLoaded { break }
            }
        }
        guard transcriptionService.isModelLoaded else {
            fileLog("Batch transcribe: model not loaded after 5 min — queuing for later")
            addPendingTranscription(meetingId: meetingId, audioURL: audioURL)
            lastUserError = "Transcription queued — will process when model loads."
            return ([], nil)
        }

        var capturedSpeakerLabels: String?
        fileLog("Batch transcribe: processing \(audioURL.lastPathComponent)...")

        do {
            // Read the WAV file into Float32 samples
            let audioFile = try AVAudioFile(forReading: audioURL)
            let fileFormat = audioFile.processingFormat
            let frameCount = AVAudioFrameCount(audioFile.length)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: frameCount) else {
                fileLog("Batch transcribe: failed to create buffer")
                return ([], nil)
            }
            try audioFile.read(into: buffer)

            guard let channelData = buffer.floatChannelData else {
                fileLog("Batch transcribe: no channel data")
                return ([], nil)
            }
            let allSamples = Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))

            let totalDuration = Double(allSamples.count) / Double(fileFormat.sampleRate)
            fileLog("Batch transcribe: \(allSamples.count) samples (\(String(format: "%.0f", totalDuration))s raw)")

            // Trim leading and trailing silence to improve transcription quality.
            // WhisperKit hallucinates on long silent sections.
            let silenceThreshold: Float = 0.005
            let windowSize = Int(fileFormat.sampleRate) // 1-second windows
            let samples = trimSilence(allSamples, threshold: silenceThreshold, windowSize: windowSize)

            let trimmedDuration = Double(samples.count) / Double(fileFormat.sampleRate)
            fileLog("Batch transcribe: trimmed to \(samples.count) samples (\(String(format: "%.0f", trimmedDuration))s speech)")

            // Step 1: Transcribe the trimmed audio with WhisperKit
            let segments = try await transcriptionService.transcribe(samples: samples)
            fileLog("Batch transcribe: WhisperKit returned \(segments.count) segments")

            // Step 2: Run speaker diarization with SpeakerKit
            //
            // TODO Layer 2 follow-up (deferred): SpeakerKit currently runs on
            // the MIXED buffer that contains both mic and system audio. The
            // research note for v3.1 calls for diarizing the SYSTEM stream
            // only — mic is by definition a single speaker (the user) and
            // diarizing the mix produces false splits at speaker overlaps.
            //
            // The blocker is that AudioCaptureService writes a single
            // `{meetingId}.wav` (see AudioCaptureService.swift:130) — by the
            // time batchTranscribe loads samples, the per-source separation
            // is already lost. Splitting requires either:
            //   (a) AudioBufferManager keeping a parallel system-only file,
            //   (b) StreamingTranscriber surfacing per-source samples that
            //       batch path can reuse, or
            //   (c) source-separating the mixed file post-hoc.
            //
            // None of these are localized changes. LLM attribution still
            // works correctly on Speaker N clusters from the mixed buffer; it
            // is just suboptimal on overlapping speech. Track in the v3.1
            // SPRINT_LOG.
            var speakerMap: [Int: String] = [:] // startTime (seconds, rounded) → "Speaker 1"
            do {
                let kit = try await SpeakerKit(PyannoteConfig())
                fileLog("Diarization: SpeakerKit models loaded")
                let diarResult = try await kit.diarize(audioArray: samples)
                fileLog("Diarization: \(diarResult.segments.count) speaker segments found")

                // Build a lookup: for each second, which speaker is active
                for seg in diarResult.segments {
                    let sid = seg.speaker.speakerId ?? 0
                    let label = "Speaker \(sid + 1)"
                    var t = Int(seg.startTime)
                    while t < Int(seg.endTime) + 1 {
                        speakerMap[t] = label
                        t += 1
                    }
                }

                let uniqueSpeakers = Set(diarResult.segments.compactMap { $0.speaker.speakerId })
                fileLog("Diarization: \(uniqueSpeakers.count) unique speaker(s)")

                // Capture speaker labels — written atomically with transcripts in the caller
                if uniqueSpeakers.count > 1 {
                    capturedSpeakerLabels = uniqueSpeakers.sorted().map { "Speaker \($0 + 1)" }.joined(separator: ", ")
                }
            } catch {
                fileLog("Diarization failed (continuing without speaker labels): \(error.localizedDescription)")
            }

            // Step 3: Filter hallucinations and save transcripts with speaker labels
            //
            // WhisperKit hallucinates on silent/noisy audio — common patterns:
            // - Single word repeated across many segments ("you", "the", "I", "thank you")
            // - Bracketed noise markers: [BLANK_AUDIO], [inaudible], (silence)
            // - Very short segments with low confidence
            // - Repetitive text within a single segment (same phrase 3+ times)

            // Known hallucination phrases WhisperKit produces on silence
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

                // Look up speaker for this segment's time
                let speaker = speakerMap[Int(seg.startTime)] ?? "Speaker"

                toSave.append(Transcript(
                    meetingId: meetingId,
                    speakerLabel: speaker,
                    text: text,
                    startTime: seg.startTime,
                    endTime: seg.endTime,
                    confidence: seg.confidence
                ))
            }
            fileLog("Batch transcribe: prepared \(toSave.count) segments, skipped \(skippedCount) hallucinations")
            Logger.transcription.info("Batch transcription ready: \(toSave.count) segments for meeting \(meetingId)")
            return (toSave, capturedSpeakerLabels)

        } catch {
            fileLog("Batch transcribe: ERROR — \(error.localizedDescription)")
            Logger.transcription.error("Batch transcription failed: \(error.localizedDescription)")
            return ([], capturedSpeakerLabels)
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
    private func applySpeakerAttribution(
        transcripts: [Transcript],
        meeting: Meeting
    ) async -> (transcripts: [Transcript], meeting: Meeting) {
        let participants = meeting.participantList
        guard !participants.isEmpty else { return (transcripts, meeting) }

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

        // Voice-profile pre-match — checks each Speaker N cluster against the
        // stored voice fingerprint DB before the LLM is invoked. A cosine
        // similarity ≥ 0.82 against a known person collapses the mapping to
        // that name with zero LLM cost. The matched names are passed to the
        // LLM as priorAliases (rather than written directly to the mapping)
        // so the LLM can still override if it disagrees, but in practice the
        // pre-match wins ~all of the time.
        var voiceMatches: [String: String] = [:]
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
                    voiceMatches = await VoiceProfileService.shared.matchProfiles(
                        audioURL: systemURL,
                        clusterRanges: clusterRanges,
                        stored: stored
                    )
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
            // Always allow the user — mic channel is ground truth.
            if let uf = userFirstLower, lower.contains(uf) { return false }
            // Keep when name fuzzy-matches any attendee.
            let isAttendee = attendeeNamesLower.contains { att in
                att.contains(lower) || lower.contains(att)
            }
            return !isAttendee
        }
        for (cluster, name) in droppedMatches {
            Logger.general.warning("[AttendanceGate] dropping voice match \(cluster, privacy: .public) → \(name, privacy: .public) — not in attendees \(participants.joined(separator: ", "), privacy: .public)")
            voiceMatches.removeValue(forKey: cluster)
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
        let vocativeMatches = VocativeMiningService.attribute(
            transcripts: transcripts,
            attendees: participants,
            userFirstName: userFirst,
            existingMapping: combinedPriorAliases
        )
        for (cluster, name) in vocativeMatches where combinedPriorAliases[cluster] == nil {
            Logger.general.info("[Vocative] mined \(cluster, privacy: .public) → \(name, privacy: .public)")
            combinedPriorAliases[cluster] = name
        }

        let outcome = await SpeakerAttributionService.shared.attribute(
            transcripts: transcripts,
            participantNames: participants,
            userFirstName: userFirst,
            priorAliases: combinedPriorAliases,
            ollama: ollamaService,
            claude: claudeForAttribution
        )

        // Voice-pre-matches are authoritative on their own. Even if the LLM
        // skipped a cluster, if the profile DB matched it, we still apply that.
        var mapping = outcome.mapping
        for (cluster, name) in voiceMatches where mapping[cluster] == nil {
            mapping[cluster] = name
        }

        // Auto-map the user's own mic cluster (if any). Mic-tagged turns are
        // labelled "mic" by the capture pipeline, never "Speaker N", so they
        // don't go through the LLM. Surface the user's name on those rows by
        // mapping "mic" -> their full name (or first name if that's all we have).
        if let userFirst = userFirst {
            let fullName = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
            let displayName = fullName.isEmpty ? userFirst : fullName
            mapping["mic"] = displayName
        }

        // 2-person meeting auto-assignment. If the calendar invite has the
        // user + exactly one other participant, AND the transcript has
        // exactly one un-mapped cluster (everything else is mic or already
        // resolved by voice/LLM), name that cluster the lone non-user
        // participant. Cheap, deterministic, and removes the most common
        // "click each fragment to label" friction for 1:1s.
        let allClusters = Set(transcripts.compactMap { $0.speakerLabel })
            .filter { $0 != "mic" && $0 != "system" && $0.hasPrefix("Speaker ") }
        let unmappedClusters = allClusters.filter { mapping[$0] == nil }

        if unmappedClusters.count == 1,
           let onlyCluster = unmappedClusters.first {
            // Calendar participants minus anyone matching the user's first name.
            let nonUserParticipants = participants.filter { name in
                guard let userFirst = userFirst else { return true }
                return !name.lowercased().contains(userFirst.lowercased())
            }
            if nonUserParticipants.count == 1 {
                let inferred = nonUserParticipants[0]
                mapping[onlyCluster] = inferred
                Logger.general.info("Auto-assigned 2-person meeting: \(onlyCluster, privacy: .public) → \(inferred, privacy: .public)")
            }
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
        Logger.general.info("Speaker attribution: mapped \(mapping.count) cluster(s) (outcome=\(String(describing: outcome.reason), privacy: .public)) for meeting \(meeting.id, privacy: .public)")
        return (relabelled, updated)
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
        // throws.
        let textGen = await makeTextGenerator()
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
            guard !raw.isEmpty else { continue }
            let lower = raw.lowercased()
            if lower.hasPrefix("speaker ") { continue }
            if lower == "system" || lower == "mic" || lower == "unknown" || lower == "other" || lower == "them" { continue }
            if !userFirst.isEmpty, lower.contains(userFirst) { continue }
            // Treat the speaker name as the canonical key.
            rangesByName[raw, default: []].append((Float(t.startTime), Float(t.endTime)))
        }
        guard !rangesByName.isEmpty else { return }

        let voiceService = VoiceProfileService.shared
        let repo = VoiceProfileRepository(database: database)
        let personRepo = PersonRepository(database: database)
        let sampleRepo = VoiceSampleRepository(database: database)
        for (name, ranges) in rangesByName {
            guard let embedding = await voiceService.extractEmbedding(audioURL: systemURL, timeRanges: ranges) else { continue }
            let person = try? await personRepo.findOrCreate(for: name)
            try? await repo.merge(personName: name, newEmbedding: embedding, personRepo: personRepo)
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
                    source: "voice_match",
                    createdAt: Date()
                )
                sample.embedding = embedding
                try? await sampleRepo.save(sample)
            }
            Logger.general.info("Voice profile learned: \(name, privacy: .public) (\(ranges.count) range(s)) for meeting \(meetingId, privacy: .public)")
        }
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
    private func runDiarization(meetingId: String, systemAudioURL: URL?) async {
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
        let participantCount: Int? = {
            guard let m = meeting else { return nil }
            let count = m.participantList.count
            return count > 0 ? count : nil
        }()

        do {
            let result = try await service.diarize(
                systemAudioURL: audioURL,
                participantCount: participantCount
            )
            guard result.speakerCount > 0 else {
                fileLog("Diarization: 0 speakers detected for \(meetingId)")
                return
            }

            let resultBox = DiarizationResultBox(result)
            let profileRepo = VoiceProfileRepository(database: database)
            let voiceService = VoiceProfileService.shared

            // Phase 3 — match stored voice profiles before LLM attribution.
            // Clusters that match a known voice are pre-assigned, skipping the LLM entirely.
            // Use allProfilesResolved so each profile's personName reflects the
            // Person's current canonical name (Phase 2: personId-keyed matching).
            let personRepo2 = PersonRepository(database: database)
            let storedProfiles = (try? await profileRepo.allProfilesResolved(personRepo: personRepo2)) ?? []
            let clusterLabels = Set(result.segments.compactMap { $0.speaker.speakerId }.map { "Speaker \($0)" })
            let voiceMatches = await voiceService.matchProfiles(
                clusters: Array(clusterLabels),
                audioURL: audioURL,
                diarizationResult: resultBox,
                stored: storedProfiles
            )
            if !voiceMatches.isEmpty {
                fileLog("Diarization: voice profiles pre-matched \(voiceMatches.count) cluster(s) for \(meetingId)")
            }

            // Fetch all system-audio transcript rows for alignment.
            let transcripts = try await transcriptRepo.transcriptsForMeeting(meetingId, limit: Int.max)
            let systemTranscripts = transcripts.filter {
                ($0.speakerLabel ?? "").lowercased() == "system"
            }
            guard !systemTranscripts.isEmpty else {
                fileLog("Diarization: no system-audio transcript rows for \(meetingId)")
                return
            }

            // Align diarization segments → transcript rows → "Speaker N" labels.
            var labelMapping = service.alignToTranscripts(systemTranscripts, result: result)
            guard !labelMapping.isEmpty else {
                fileLog("Diarization: alignment produced no matches for \(meetingId)")
                return
            }

            // Apply voice-profile pre-assignments: replace "Speaker N" with real name
            // where we have a confident match, so the LLM doesn't need to guess.
            if !voiceMatches.isEmpty {
                labelMapping = labelMapping.mapValues { label in
                    voiceMatches[label] ?? label
                }
            }

            try await transcriptRepo.updateSpeakerLabels(labelMapping)
            fileLog("Diarization: labelled \(labelMapping.count) transcript rows for \(meetingId) (\(result.speakerCount) speakers)")

            // Now run LLM attribution for any remaining "Speaker N" clusters.
            if let m = meeting {
                let relabelled = try await transcriptRepo.transcriptsForMeeting(meetingId, limit: Int.max)
                let (_, attributed) = await applySpeakerAttribution(
                    transcripts: relabelled,
                    meeting: m
                )
                try? await database.writer.write { db in
                    var updated = attributed
                    try updated.update(db)
                }

                // Phase 3 — save voice embeddings for newly-identified speakers
                // so future meetings can match them without the LLM.
                let finalSpeakerMap = attributed.speakerMapDictionary
                let personRepo = PersonRepository(database: database)
                for (clusterLabel, personName) in finalSpeakerMap {
                    guard !personName.isEmpty else { continue }
                    if let embedding = await voiceService.extractEmbedding(
                        forSpeaker: clusterLabel,
                        from: audioURL,
                        diarizationResult: resultBox
                    ) {
                        try? await profileRepo.merge(personName: personName, newEmbedding: embedding, personRepo: personRepo)
                        fileLog("Diarization: updated voice profile for \(personName)")
                    }
                }
            }

            loadMeetings()
        } catch {
            fileLog("Diarization: failed for \(meetingId): \(error.localizedDescription)")
            Logger.general.error("Diarization failed for \(meetingId): \(error.localizedDescription)")
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
                    modelProgressCancellable = nil
                    modelDownloadProgress = 1.0

                    Logger.transcription.info("WhisperKit model loaded — transcription is ready")
                    fileLog("Model: LOADED successfully — ready for transcription")

                    // Notify user if this was a real download (not a cache load)
                    let loadDuration = Date().timeIntervalSince(loadStart)
                    if loadDuration > 30 {
                        sendModelReadyNotification()
                    }

                    // Process any pending transcription jobs
                    await processPendingTranscriptions()

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

        for (meetingId, path) in pending {
            let audioURL = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else {
                fileLog("Pending transcription: audio file missing for \(meetingId), removing from queue")
                continue
            }
            // Use same atomic-write pattern as transcriptionHandler
            let (rawTranscripts, speakerLabels) = await batchTranscribe(meetingId: meetingId, audioURL: audioURL)
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

        // Clear the queue
        UserDefaults.standard.removeObject(forKey: Self.pendingTranscriptionKey)
        fileLog("Pending transcription queue cleared")
    }

    // MARK: - Auto-title (P1-T06)

    /// If the meeting still has the default/empty title and is not tied to a
    /// calendar event, ask Ollama for a 5-7 word title from the transcript.
    /// Falls through silently when Ollama is unavailable — the meeting just
    /// keeps its default title until the user (or summary) renames it.
    private func autoTitleIfNeeded(meeting: Meeting, transcripts: [Transcript]) async {
        // Calendar meetings already have a meaningful title from the event.
        guard meeting.calendarEventId == nil else { return }

        let defaultTitles: Set<String> = ["New Meeting", "Untitled Meeting", ""]
        let trimmedTitle = meeting.title.trimmingCharacters(in: .whitespaces)
        guard defaultTitles.contains(meeting.title) || trimmedTitle.isEmpty else { return }

        let transcriptText = transcripts.map { $0.text }.joined(separator: " ")
        guard !transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let resolvedTitle: String?
        if let generated = await TitleGenerationService.shared.generate(
            fromTranscript: transcriptText,
            using: ollamaService
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
    private func handleCallDetected(appName: String) {
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
                    // Look for a scheduled meeting within ±5 minutes
                    let nearbyMeetings = try await self.meetingRepository.meetingsNearDate(Date(), windowMinutes: 5)
                    let scheduledMatch = nearbyMeetings.first(where: { $0.status == .scheduled || $0.status == .notified })

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

                    self.activeMeeting = self.stateMachine.currentMeeting
                    self.isRecording = self.stateMachine.isRecording
                    self.selectedMeetingId = meeting.id
                    self.detectedCallApp = nil
                    self.recordingStartedByDetector = self.isRecording
                    if self.isRecording { self.startAudioLevelPolling() }
                    self.loadMeetings()
                    self.fileLog("handleCallDetected: recording started for \(meeting.id) ('\(meeting.title)')")

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

    /// Trim leading and trailing silence from audio samples.
    /// Uses 1-second windows and checks if the RMS energy exceeds the threshold.
    private func trimSilence(_ samples: [Float], threshold: Float, windowSize: Int) -> [Float] {
        guard samples.count > windowSize else { return samples }

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

        guard firstNonSilent < lastNonSilent else { return samples }
        return Array(samples[firstNonSilent..<lastNonSilent])
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

        // Hourly safety net — tighter than once-a-day so a missed sync hook
        // doesn't leave the user without a brief for their afternoon meeting.
        prepContextTimerCancellable = Timer.publish(every: 3600, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.preComputePrepContext()
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

    @MainActor
    private func preComputePrepContext() {
        Task { [weak self] in
            guard let self else { return }
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
            } catch {
                fileLog("Prep: context pre-computation failed: \(error.localizedDescription)")
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

        for meeting in upcomingMeetings {
            guard let startDate = meeting.scheduledStartDate else { continue }
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
            // lead-time notification setting. Window is 90s to guarantee the
            // 30s poll catches it even if the timer drifts slightly.
            // Accepts .notified status too — a call app launch can advance the meeting
            // to .notified well before the 90s window, which would silently skip it.
            if timeUntilStart > 0, timeUntilStart <= 90,
               meeting.status == .scheduled || meeting.status == .notified,
               hudShownMeetingIds.insert(meeting.id).inserted {
                NotificationCenter.default.post(
                    name: .meetingHUDShow,
                    object: nil,
                    userInfo: ["meetingId": meeting.id]
                )
                Logger.general.debug("HUD: showing pre-meeting card for '\(meeting.title)'")
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
                      timeUntilStart > 0 && timeUntilStart <= 75,
                      (meeting.status == .scheduled || meeting.status == .notified),
                      !autoJoinedMeetingIds.contains(meeting.id) {
                // autoRecord on, in window, but not joined — diagnose why.
                let reason: String
                if meeting.meetLink?.isEmpty != false {
                    reason = "no meetLink on meeting"
                } else if isRecording {
                    reason = "already recording"
                } else if isStartingMeeting {
                    reason = "another start in progress"
                } else {
                    reason = "unknown"
                }
                Logger.notifications.debug("[autoJoin] skipped '\(meeting.title, privacy: .public)' timeUntilStart=\(Int(timeUntilStart))s reason=\(reason, privacy: .public)")
            }

            // Auto-start: if meeting should have started (within 0-5 min past start) and we're not recording.
            // The 5-minute window accommodates meetings that start slightly late.
            // Accepts .notified too — call-app-launch can advance status before the start window.
            // Skip if we already auto-joined at lead time.
            if timeUntilStart >= -300 && timeUntilStart <= 0
                && (meeting.status == .scheduled || meeting.status == .notified)
                && !isRecording && !isStartingMeeting
                && !autoJoinedMeetingIds.contains(meeting.id) {
                Logger.general.debug("Auto-starting recording for meeting: \(meeting.title)")
                startRecording(for: meeting)
            }
        }
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
                Task { @MainActor in
                    self.handleCallDetected(appName: appName)
                }
            }
            .store(in: &cancellables)

        // Call app closed — auto-stop recording only if it was detector-started.
        // Manually-started recordings must never be stopped by the browser detector
        // losing signal (e.g., when MicUsage is suppressed because we're recording).
        NotificationCenter.default.publisher(for: .callAppTerminated)
            .sink { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    self.detectedCallApp = nil
                    if self.isRecording && self.recordingStartedByDetector {
                        Logger.general.info("Call ended — auto-stopping detector-started recording")
                        self.stopRecording()
                    } else if self.isRecording {
                        Logger.general.info("Call ended signal received — keeping recording alive (manually started)")
                    }
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
    func makeTextGenerator() async -> ((String, String) async throws -> String)? {
        let hasClaudeKey = ((try? KeychainHelper.loadString(forKey: KeychainHelper.Key.claudeAPIKey)) ?? "")?.isEmpty == false
        await ollamaService.refreshStatus()
        let ollamaReachable = ollamaService.isReachable
        let useOllama = settings.useLocalLLM || (!hasClaudeKey && ollamaReachable)

        if useOllama {
            let service = ollamaService
            let ollamaModel = settings.ollamaModel
            return { sys, usr in try await service.generate(systemPrompt: sys, userPrompt: usr, model: ollamaModel) }
        } else if hasClaudeKey {
            let claude = ClaudeService()
            let claudeModel = settings.claudeModel
            return { sys, usr in try await claude.sendMessage(systemPrompt: sys, userPrompt: usr, model: claudeModel) }
        }
        return nil
    }

    /// Groups all meetings (past + upcoming) into recurring-series "folders" by normalised base title.
    /// Result is cached and invalidated whenever `upcomingMeetings` or `pastMeetings` change.
    /// A folder is only created if 2+ meetings share the same base title.
    func meetingFolders() -> [MeetingFolder] {
        if let cached = _cachedFolders { return cached }
        var map: [String: [Meeting]] = [:]
        let allMeetings = (upcomingMeetings + pastMeetings).filter { $0.status != .archived }
        for meeting in allMeetings {
            let key = MeetingFolder.normaliseTitle(meeting.title)
            map[key, default: []].append(meeting)
        }
        let result = map
            .filter { $0.value.count >= 2 }
            .map { key, meetings in
                MeetingFolder(
                    key: key,
                    displayName: meetings.first.map { MeetingFolder.displayName(for: $0.title) } ?? key,
                    meetings: meetings.sorted { ($0.effectiveDate) > ($1.effectiveDate) }
                )
            }
            .sorted { $0.meetings.first?.effectiveDate ?? .distantPast > $1.meetings.first?.effectiveDate ?? .distantPast }
        _cachedFolders = result
        return result
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
    case tasks
    case search
    case meetings
    case analytics
    case folder(String)  // folder key = normalised base title
}

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

    /// When set, SettingsView will switch to this tab index and clear the value.
    /// Tab indices: 0 General, 1 Audio, 2 Transcription, 3 Calendar, 4 AI(Claude), 5 AI(Local).
    var pendingSettingsTab: Int?

    /// The user's persisted settings. Changes are automatically written to the database.
    var settings: AppSettings = .default {
        didSet {
            guard settings != oldValue else { return }
            persistSettings()
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
                    self.pastMeetings = past
                    self.meetings = upcoming + past
                }
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
            let (transcripts, speakerLabels) = await self.batchTranscribe(meetingId: meetingId, audioURL: audioURL)

            // Atomically commit transcripts + meeting-status update + speaker labels in one write.
            // Previously three separate writer.write calls; now a single transaction so a crash
            // between steps cannot leave transcripts saved but meeting still in .transcribing.
            if var meeting = try? await self.meetingRepository.find(id: meetingId) {
                if let labels = speakerLabels {
                    let existing = meeting.participants ?? ""
                    meeting.participants = existing.isEmpty ? labels : "\(existing) (\(labels))"
                }
                let wasTranscribing = meeting.status == .transcribing
                if wasTranscribing { meeting.status = .complete }

                try? await self.database.writer.write { db in
                    for var t in transcripts { try t.save(db) }
                    try meeting.save(db)
                }

                if wasTranscribing {
                    NotificationCenter.default.post(
                        name: .meetingStateChanged,
                        object: self.stateMachine,
                        userInfo: ["meetingId": meeting.id, "status": meeting.status.rawValue]
                    )
                }
                Logger.transcription.info("Transcription committed: \(transcripts.count) segments for \(meetingId)")

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

        taskQueueManager.enrichmentHandler = { [weak self] meetingId in
            guard let self else { return }
            self.fileLog("TaskQueue: enrichment placeholder for \(meetingId)")
        }

        taskQueueManager.contextEnrichmentHandler = { [weak self] meetingId in
            guard let self else { return }
            self.fileLog("TaskQueue: finding related meetings for \(meetingId)")
            let service = RelevantMeetingService(database: AppDatabase.shared)
            try await service.enrichContext(meetingId: meetingId)
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

                // Skip very low confidence segments (< 0.4)
                if seg.confidence < 0.4 {
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
            let (transcripts, speakerLabels) = await batchTranscribe(meetingId: meetingId, audioURL: audioURL)
            if var meeting = try? await meetingRepository.find(id: meetingId) {
                if let labels = speakerLabels {
                    let existing = meeting.participants ?? ""
                    meeting.participants = existing.isEmpty ? labels : "\(existing) (\(labels))"
                }
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

    /// Proactively enriches context for meetings starting in the next 30 minutes.
    /// Runs every 5 minutes so prep cards load instantly when Jordan opens HomeView.
    private func startPrepContextTimer() {
        preComputePrepContext() // Run immediately on startup
        prepContextTimerCancellable = Timer.publish(every: 300, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.preComputePrepContext()
            }
    }

    @MainActor
    private func preComputePrepContext() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let soonMeetings = try await self.meetingRepository.meetingsStartingWithin(minutes: 30)
                let service = RelevantMeetingService(database: self.database)
                for meeting in soonMeetings {
                    if meeting.contextJSON == nil || meeting.contextJSON?.isEmpty == true {
                        try await service.enrichContext(meetingId: meeting.id)
                    }
                }
                if !soonMeetings.isEmpty {
                    fileLog("Prep: enriched context for \(soonMeetings.count) upcoming meeting(s)")
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

        for meeting in upcomingMeetings {
            guard let startDate = meeting.scheduledStartDate else { continue }
            let timeUntilStart = startDate.timeIntervalSince(now)

            // Meeting starting within the notification window — post only once per meeting
            if timeUntilStart > 0, timeUntilStart <= warningWindow,
               meeting.status == .scheduled,
               notifiedMeetingIds.insert(meeting.id).inserted {
                NotificationCenter.default.post(
                    name: .meetingStartingSoon,
                    object: nil,
                    userInfo: ["meetingId": meeting.id, "minutesUntilStart": Int(timeUntilStart / 60)]
                )
                Logger.general.debug("Meeting '\(meeting.title)' starting in \(Int(timeUntilStart / 60)) minutes")
            }

            // Auto-start: if meeting should have started (within 0-5 min past start) and we're not recording.
            // The 5-minute window accommodates meetings that start slightly late.
            if timeUntilStart >= -300 && timeUntilStart <= 0 && meeting.status == .scheduled && !isRecording && !isStartingMeeting {
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

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
    static var shared: AppState!

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

    /// Timestamp of the last call detection event, used to deduplicate rapid-fire
    /// notifications from CallDetectionService and BrowserCallDetector firing for
    /// the same meeting (e.g., Zoom native app + Zoom in browser tab).
    private var lastCallDetectionTime: Date?
    var meetings: [Meeting] = []
    var upcomingMeetings: [Meeting] = [] { didSet { _cachedFolders = nil } }
    var pastMeetings: [Meeting] = []    { didSet { _cachedFolders = nil } }

    /// Cached folder groupings — invalidated whenever meetings change.
    private var _cachedFolders: [MeetingFolder]?
    var navigationPath = NavigationPath()

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
                if var loaded = loaded {
                    // Always enforce large-v3 — no other models are supported.
                    if loaded.whisperModel != WhisperModel.largev3.rawValue {
                        loaded.whisperModel = WhisperModel.largev3.rawValue
                    }
                    await MainActor.run { self.settings = loaded }
                }
            } catch {
                print("Failed to load settings: \(error)")
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
                print("Failed to persist settings: \(error)")
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
                    print("Failed to load meetings: \(error)")
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
            await self.batchTranscribe(meetingId: meetingId, audioURL: audioURL)

            // Mark meeting complete after transcription
            if var meeting = try? await self.meetingRepository.find(id: meetingId),
               meeting.status == .transcribing {
                try? await self.stateMachine.complete(meeting: meeting)
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

        let systemPrompt = rawTemplate
            .replacingOccurrences(of: "{{meetingTitle}}", with: meeting.title)
            .replacingOccurrences(of: "{{date}}", with: meeting.startDate?.formatted() ?? "Unknown")
            .replacingOccurrences(of: "{{duration}}", with: meeting.formattedDuration)
            .replacingOccurrences(of: "{{transcript}}", with: "")
            .replacingOccurrences(of: "{{notes}}", with: "")

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
                userPrompt: transcript,
                model: settings.ollamaModel
            )
        } else if hasClaudeKey {
            let claude = ClaudeService()
            summaryText = try await claude.sendMessage(
                systemPrompt: systemPrompt,
                userPrompt: transcript,
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

                loadMeetings()
                fileLog("Recording started for meeting \(self.stateMachine.currentMeeting?.id ?? "?")")
            } catch {
                Logger.general.error("Failed to start recording: \(error.localizedDescription)")
                self.lastUserError = error.localizedDescription
            }
        }
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

    /// Schedule automatic summary generation 10 minutes after transcription completes.
    private func scheduleAutoSummary(meetingId: String) {
        fileLog("Auto-summary: scheduled for meeting \(meetingId) in 10 minutes")
        Logger.ai.info("Auto-summary scheduled for \(meetingId) — will fire in 10 minutes")

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(600)) // 10 minutes

            // Verify the meeting still exists and doesn't already have a summary
            guard let meeting = try? await meetingRepository.find(id: meetingId) else {
                fileLog("Auto-summary: meeting \(meetingId) no longer exists — skipping")
                return
            }

            if let existing = try? await summaryRepository.latestSummary(meetingId: meetingId), !existing.summaryText.isEmpty {
                fileLog("Auto-summary: meeting \(meetingId) already has a summary — skipping")
                return
            }

            fileLog("Auto-summary: generating for meeting \(meetingId)...")

            // Determine AI backend (same routing as SummaryView)
            let baseTextGenerator: (String, String) async throws -> String
            let modelUsed: String

            let hasClaudeKey = ((try? KeychainHelper.loadString(forKey: KeychainHelper.Key.claudeAPIKey)) ?? "")?.isEmpty == false
            await ollamaService.refreshStatus()
            let ollamaReachable = ollamaService.isReachable

            let useOllama = settings.useLocalLLM || (!hasClaudeKey && ollamaReachable)

            if useOllama {
                let service = ollamaService
                let ollamaModel = settings.ollamaModel  // "auto" or explicit
                baseTextGenerator = { sys, usr in
                    try await service.generate(systemPrompt: sys, userPrompt: usr, model: ollamaModel)
                }
                modelUsed = "ollama/\(ollamaModel)"
            } else if hasClaudeKey {
                let claude = ClaudeService()
                let claudeModel = settings.claudeModel
                baseTextGenerator = { sys, usr in
                    try await claude.sendMessage(systemPrompt: sys, userPrompt: usr, model: claudeModel)
                }
                modelUsed = claudeModel
            } else {
                fileLog("Auto-summary: no AI configured — skipping")
                return
            }

            // If a default recipe is set, use its prompt template
            let textGenerator: (String, String) async throws -> String
            if let recipeId = settings.defaultRecipeId {
                let repo = RecipeRepository(database: database)
                if let recipe = try? await repo.find(id: recipeId) {
                    textGenerator = { _, usr in try await baseTextGenerator(recipe.promptTemplate, usr) }
                } else {
                    textGenerator = baseTextGenerator
                }
            } else {
                textGenerator = baseTextGenerator
            }

            do {
                let generator = SummaryGenerator()
                let summary = try await generator.generateSummary(
                    for: meeting,
                    transcriptRepo: transcriptRepository,
                    noteRepo: noteRepository,
                    summaryRepo: summaryRepository,
                    textGenerator: textGenerator,
                    modelUsed: modelUsed,
                    settings: settings
                )
                fileLog("Auto-summary: completed for meeting \(meetingId) (\(summary.summaryText.count) chars)")
                Logger.ai.info("Auto-summary generated for \(meetingId)")
            } catch {
                fileLog("Auto-summary: FAILED for meeting \(meetingId) — \(error.localizedDescription)")
                Logger.ai.error("Auto-summary failed: \(error.localizedDescription)")
            }
        }
    }

    /// Batch-transcribe a complete WAV file using WhisperKit's sequential long-form algorithm.
    /// This gives dramatically better accuracy than streaming 30-second chunks because
    /// Whisper carries context between windows and the full audio is available.
    private func batchTranscribe(meetingId: String, audioURL: URL?) async {
        guard let audioURL else {
            fileLog("Batch transcribe: no audio file URL")
            return
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
            return
        }

        fileLog("Batch transcribe: processing \(audioURL.lastPathComponent)...")

        do {
            // Read the WAV file into Float32 samples
            let audioFile = try AVAudioFile(forReading: audioURL)
            let fileFormat = audioFile.processingFormat
            let frameCount = AVAudioFrameCount(audioFile.length)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: frameCount) else {
                fileLog("Batch transcribe: failed to create buffer")
                return
            }
            try audioFile.read(into: buffer)

            guard let channelData = buffer.floatChannelData else {
                fileLog("Batch transcribe: no channel data")
                return
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
                let config = PyannoteConfig()
                let modelManager = SpeakerKitModelManager(config: config)
                try await modelManager.loadModels()
                fileLog("Diarization: SpeakerKit models loaded")

                guard let models = modelManager.models as? PyannoteModels else {
                    fileLog("Diarization: failed to cast models")
                    throw SpeakerKitError.invalidConfiguration("Model cast failed")
                }

                let kit = try SpeakerKit(models: models)
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

                // Update meeting participants
                if uniqueSpeakers.count > 1 {
                    let speakerLabels = uniqueSpeakers.sorted().map { "Speaker \($0 + 1)" }.joined(separator: ", ")
                    if var meeting = try? await meetingRepository.find(id: meetingId) {
                        let existing = meeting.participants ?? ""
                        meeting.participants = existing.isEmpty ? speakerLabels : "\(existing) (\(speakerLabels))"
                        try? await meetingRepository.save(&meeting)
                    }
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
            try await transcriptRepository.saveBatch(toSave)
            let savedCount = toSave.count

            fileLog("Batch transcribe: saved \(savedCount) segments, skipped \(skippedCount) hallucinations")
            Logger.transcription.info("Batch transcription complete: \(savedCount) segments for meeting \(meetingId)")

        } catch {
            fileLog("Batch transcribe: ERROR — \(error.localizedDescription)")
            Logger.transcription.error("Batch transcription failed: \(error.localizedDescription)")
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

            // Always use large-v3 — it's the only supported model.
            let model = WhisperModel.largev3
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
            await batchTranscribe(meetingId: meetingId, audioURL: audioURL)
        }

        // Clear the queue
        UserDefaults.standard.removeObject(forKey: Self.pendingTranscriptionKey)
        fileLog("Pending transcription queue cleared")
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

    // MARK: - File Logging (for debugging with user)

    /// Append a line to a shared log file that both the app and Claude can read.
    /// Log rotation: when the file exceeds `maxLogFileSize`, the current log is
    /// renamed to `app.log.1` (overwriting any previous backup) and a fresh file
    /// is started.  This prevents unbounded disk growth.
    static let logFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/MeetingManager/app.log")

    /// Maximum log file size before rotation (5 MB).
    private static let maxLogFileSize: UInt64 = 5 * 1024 * 1024

    func fileLog(_ message: String) {
        let timestamp = DateFormatting.iso8601Formatter.string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        let fm = FileManager.default
        if fm.fileExists(atPath: Self.logFile.path) {
            // Rotate if the file is too large
            if let attrs = try? fm.attributesOfItem(atPath: Self.logFile.path),
               let size = attrs[.size] as? UInt64,
               size > Self.maxLogFileSize {
                let backupURL = Self.logFile.deletingPathExtension()
                    .appendingPathExtension("log.1")
                try? fm.removeItem(at: backupURL)
                try? fm.moveItem(at: Self.logFile, to: backupURL)
                // Start fresh
                try? data.write(to: Self.logFile)
                return
            }

            if let handle = try? FileHandle(forWritingTo: Self.logFile) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        } else {
            // Ensure directory exists
            let dir = Self.logFile.deletingLastPathComponent()
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try? data.write(to: Self.logFile)
        }
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
                Logger.general.info("Meeting '\(meeting.title)' starting in \(Int(timeUntilStart / 60)) minutes")
            }

            // Auto-start: if meeting should have started (within 0-5 min past start) and we're not recording.
            // The 5-minute window accommodates meetings that start slightly late.
            if timeUntilStart >= -300 && timeUntilStart <= 0 && meeting.status == .scheduled && !isRecording && !isStartingMeeting {
                Logger.general.info("Auto-starting recording for meeting: \(meeting.title)")
                startRecording(for: meeting)
            }
        }
    }

    // MARK: - Notification Observers

    private func observeNotifications() {
        // Create ad-hoc meeting via state machine (manual "New Meeting" button).
        // If a scheduled meeting starts within 5 minutes, start that instead.
        NotificationCenter.default.publisher(for: .createNewMeeting)
            .sink { [weak self] _ in
                guard let self else { return }
                guard !self.isRecording else {
                    self.fileLog("createNewMeeting: skipped — already recording")
                    return
                }
                guard !self.isStartingMeeting else {
                    self.fileLog("createNewMeeting: skipped — another start in progress (debounce)")
                    return
                }
                self.isStartingMeeting = true
                self.fileLog("createNewMeeting notification received")
                Task { @MainActor in
                    defer { self.isStartingMeeting = false }
                    do {
                        // Check for a nearby scheduled meeting first
                        let nearby = try await self.meetingRepository.meetingsNearDate(Date(), windowMinutes: 5)
                        let scheduledMatch = nearby.first(where: { $0.status == .scheduled || $0.status == .notified })

                        let meeting: Meeting
                        if let scheduled = scheduledMatch {
                            self.fileLog("New Meeting: matched scheduled '\(scheduled.title)' — starting it")
                            try await self.stateMachine.startRecording(meeting: scheduled)
                            meeting = self.stateMachine.currentMeeting ?? scheduled
                        } else {
                            meeting = try await self.stateMachine.createAndStartMeeting(title: "New Meeting")
                        }

                        self.activeMeeting = self.stateMachine.currentMeeting
                        self.isRecording = self.stateMachine.isRecording
                        self.selectedMeetingId = meeting.id
                        if self.isRecording { self.startAudioLevelPolling() }
                        self.fileLog("Meeting started: \(meeting.id) ('\(meeting.title)')")
                        self.loadMeetings()
                    } catch {
                        Logger.general.error("Failed to start meeting: \(error.localizedDescription)")
                        self.lastUserError = error.localizedDescription
                    }
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
    }

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
    case chat
    case people
    case tasks
    case search
    case meetings
    case folder(String)  // folder key = normalised base title
}

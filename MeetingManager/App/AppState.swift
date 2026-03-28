import SwiftUI
import Combine
import os

@Observable
@MainActor
final class AppState {
    var selectedMeetingId: String?
    var isRecording = false
    var activeMeeting: Meeting?
    var meetings: [Meeting] = []
    var upcomingMeetings: [Meeting] = []
    var pastMeetings: [Meeting] = []
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
    let meetingRepository: MeetingRepository
    let transcriptRepository: TranscriptRepository
    let noteRepository: NoteRepository
    let summaryRepository: SummaryRepository
    let audioCaptureService: AudioCaptureService
    let transcriptionService: TranscriptionService
    let streamingTranscriber: StreamingTranscriber

    // State machine — single source of truth for meeting lifecycle
    private(set) var stateMachine: MeetingStateMachine

    /// True while the WhisperKit model is downloading/loading.
    private(set) var isLoadingModel = false

    /// User-visible error from the most recent operation (shown via alert).
    var lastUserError: String?

    private var cancellables = Set<AnyCancellable>()
    private var proximityTimer: Timer?

    init() {
        self.database = AppDatabase.shared
        self.meetingRepository = MeetingRepository(database: database)
        self.transcriptRepository = TranscriptRepository(database: database)
        self.noteRepository = NoteRepository(database: database)
        self.summaryRepository = SummaryRepository(database: database)
        self.audioCaptureService = AudioCaptureService()

        let txService = TranscriptionService()
        self.transcriptionService = txService
        self.streamingTranscriber = StreamingTranscriber(transcriptionService: txService)

        self.stateMachine = MeetingStateMachine(
            meetingRepository: meetingRepository,
            audioCaptureService: audioCaptureService
        )

        loadMeetings()
        loadSettings()
        observeNotifications()
        startProximityCheck()
        autoLoadTranscriptionModel()
    }

    // MARK: - Settings

    func loadSettings() {
        Task {
            do {
                let loaded = try await database.writer.read { db in
                    try AppSettings.fetchOne(db)
                }
                if let loaded {
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
        Task {
            do {
                let upcoming = try await meetingRepository.upcomingMeetings()
                let past = try await meetingRepository.pastMeetings(limit: 50)
                await MainActor.run {
                    self.upcomingMeetings = upcoming
                    self.pastMeetings = past
                    self.meetings = upcoming + past
                }
            } catch {
                print("Failed to load meetings: \(error)")
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

    /// Start recording — delegates to the state machine, then starts live transcription.
    func startRecording(for meeting: Meeting) {
        Task {
            do {
                try await stateMachine.startRecording(meeting: meeting)
                self.activeMeeting = self.stateMachine.currentMeeting
                self.isRecording = self.stateMachine.isRecording
                self.selectedMeetingId = self.stateMachine.currentMeeting?.id
                loadMeetings()

                // Start live transcription if model is loaded
                if let meetingId = self.stateMachine.currentMeeting?.id {
                    startTranscription(meetingId: meetingId)
                }
            } catch {
                Logger.general.error("Failed to start recording: \(error.localizedDescription)")
                self.lastUserError = error.localizedDescription
            }
        }
    }

    /// Stop recording — stops transcription, delegates to the state machine, and marks complete.
    func stopRecording() {
        Task {
            // Stop the streaming transcriber first
            await streamingTranscriber.stop()

            do {
                // Save the meeting reference before stopRecording clears it
                let stoppedMeeting = stateMachine.currentMeeting

                try await stateMachine.stopRecording()
                self.activeMeeting = self.stateMachine.currentMeeting
                self.isRecording = self.stateMachine.isRecording

                // Transition directly to complete (skip summarizing — user can trigger AI later)
                if let stopped = stoppedMeeting {
                    if let refreshed = try? await meetingRepository.find(id: stopped.id),
                       refreshed.status == .transcribing {
                        try await stateMachine.complete(meeting: refreshed)
                    }
                }

                loadMeetings()
            } catch {
                Logger.general.error("Failed to stop recording: \(error.localizedDescription)")
                self.lastUserError = error.localizedDescription
            }
        }
    }

    // MARK: - Transcription Lifecycle

    /// Automatically load the default WhisperKit model at app startup.
    private func autoLoadTranscriptionModel() {
        Task {
            guard !transcriptionService.isModelLoaded else { return }

            // Map the stored settings string to a WhisperModel enum.
            // AppSettings stores short names like "tiny-en"; WhisperModel uses full HuggingFace names.
            let model: WhisperModel
            switch settings.whisperModel {
            case "tiny-en", WhisperModel.tinyEn.rawValue: model = .tinyEn
            case "base-en", WhisperModel.baseEn.rawValue: model = .baseEn
            case "small-en", WhisperModel.smallEn.rawValue: model = .smallEn
            default: model = .tinyEn  // Safe default
            }

            Logger.transcription.info("Auto-loading WhisperKit model: \(model.rawValue)")
            isLoadingModel = true
            do {
                try await transcriptionService.loadModel(model)
                Logger.transcription.info("WhisperKit model loaded — transcription is ready")
            } catch {
                Logger.transcription.error("Failed to auto-load WhisperKit model: \(error.localizedDescription)")
                // Non-fatal — recording works without transcription, user can retry from settings
            }
            isLoadingModel = false
        }
    }

    /// Start the streaming transcription loop for the given meeting.
    private func startTranscription(meetingId: String) {
        guard transcriptionService.isModelLoaded else {
            Logger.transcription.warning("Cannot start transcription: WhisperKit model not loaded. Recording will continue without live transcript.")
            lastUserError = "Transcription model is not loaded. Recording audio only. Go to Settings → Transcription to download a model."
            return
        }

        streamingTranscriber.start(
            meetingId: meetingId,
            bufferManager: audioCaptureService.transcriptionBuffer,
            repository: transcriptRepository
        )
        Logger.transcription.info("StreamingTranscriber started for meeting \(meetingId)")
    }

    // MARK: - Meeting Proximity Detection

    func startProximityCheck() {
        proximityTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkUpcomingMeetings()
            }
        }
        proximityTimer?.fire() // Run immediately
    }

    func stopProximityCheck() {
        proximityTimer?.invalidate()
        proximityTimer = nil
    }

    @MainActor
    private func checkUpcomingMeetings() {
        let now = Date()
        let warningWindow: TimeInterval = Double(settings.notificationLeadTimeMinutes * 60)

        for meeting in upcomingMeetings {
            guard let startDate = meeting.scheduledStartDate else { continue }
            let timeUntilStart = startDate.timeIntervalSince(now)

            // Meeting starting within the notification window and not yet notified
            if timeUntilStart > 0 && timeUntilStart <= warningWindow && meeting.status == .scheduled {
                NotificationCenter.default.post(
                    name: .meetingStartingSoon,
                    object: nil,
                    userInfo: ["meetingId": meeting.id, "minutesUntilStart": Int(timeUntilStart / 60)]
                )
                Logger.general.info("Meeting '\(meeting.title)' starting in \(Int(timeUntilStart / 60)) minutes")
            }

            // Auto-start: if meeting should have started (within 0-2 min past start) and we're not recording
            if timeUntilStart >= -120 && timeUntilStart <= 0 && meeting.status == .scheduled && !isRecording {
                Logger.general.info("Auto-starting recording for meeting: \(meeting.title)")
                startRecording(for: meeting)
            }
        }
    }

    // MARK: - Notification Observers

    private func observeNotifications() {
        // Create ad-hoc meeting via state machine
        NotificationCenter.default.publisher(for: .createNewMeeting)
            .sink { [weak self] _ in
                guard let self else { return }
                Task {
                    do {
                        let meeting = try await self.stateMachine.createAndStartMeeting(title: "New Meeting")
                        await MainActor.run {
                            self.activeMeeting = self.stateMachine.currentMeeting
                            self.isRecording = self.stateMachine.isRecording
                            self.selectedMeetingId = meeting.id
                        }
                        self.loadMeetings()

                        // Start live transcription
                        await MainActor.run {
                            self.startTranscription(meetingId: meeting.id)
                        }
                    } catch {
                        Logger.general.error("Failed to create ad-hoc meeting: \(error.localizedDescription)")
                        await MainActor.run {
                            self.lastUserError = error.localizedDescription
                        }
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

                    // If recording just started (e.g., via auto-detect), start transcription
                    if !wasRecording && self.isRecording,
                       let meetingId = self.stateMachine.currentMeeting?.id {
                        self.startTranscription(meetingId: meetingId)
                    }
                }
            }
            .store(in: &cancellables)
    }
}

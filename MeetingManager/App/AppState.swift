import AVFoundation
import SwiftUI
import Combine
import Speech
import UserNotifications
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
    let appleSpeechTranscriber: AppleSpeechTranscriber

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
        self.appleSpeechTranscriber = AppleSpeechTranscriber()

        self.stateMachine = MeetingStateMachine(
            meetingRepository: meetingRepository,
            audioCaptureService: audioCaptureService
        )

        loadMeetings()
        loadSettings()
        observeNotifications()
        startProximityCheck()
        autoLoadTranscriptionModel()

        fileLog("AppState initialized — starting model download")
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

    /// Start recording — delegates to the state machine. No live transcription needed —
    /// we transcribe the complete recording after the meeting ends for much better accuracy.
    func startRecording(for meeting: Meeting) {
        Task {
            do {
                try await stateMachine.startRecording(meeting: meeting)
                self.activeMeeting = self.stateMachine.currentMeeting
                self.isRecording = self.stateMachine.isRecording
                self.selectedMeetingId = self.stateMachine.currentMeeting?.id
                loadMeetings()
                fileLog("Recording started for meeting \(self.stateMachine.currentMeeting?.id ?? "?")")
            } catch {
                Logger.general.error("Failed to start recording: \(error.localizedDescription)")
                self.lastUserError = error.localizedDescription
            }
        }
    }

    /// Stop recording — then run batch transcription on the complete audio file.
    /// Batch transcription is dramatically more accurate than live streaming because
    /// Whisper can use the full audio context and sequential decoding.
    func stopRecording() {
        Task {
            do {
                // Save references before stopRecording clears them
                let stoppedMeeting = stateMachine.currentMeeting
                let audioURL = audioCaptureService.currentAudioFileURL

                try await stateMachine.stopRecording()
                self.activeMeeting = self.stateMachine.currentMeeting
                self.isRecording = self.stateMachine.isRecording

                // Mark meeting as transcribing → then run batch transcription
                if let stopped = stoppedMeeting {
                    if let refreshed = try? await meetingRepository.find(id: stopped.id),
                       refreshed.status == .transcribing {
                        // Run batch transcription on the complete audio file
                        fileLog("Meeting stopped. Starting batch transcription for \(stopped.id)...")
                        await batchTranscribe(meetingId: stopped.id, audioURL: audioURL)

                        // Mark complete after transcription finishes
                        if let final_ = try? await meetingRepository.find(id: stopped.id),
                           final_.status == .transcribing {
                            try await stateMachine.complete(meeting: final_)
                        }
                    }
                }

                // Notify the menu bar that recording has stopped
                NotificationCenter.default.post(name: .stopRecording, object: nil)

                loadMeetings()
            } catch {
                Logger.general.error("Failed to stop recording: \(error.localizedDescription)")
                self.lastUserError = error.localizedDescription
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
            fileLog("Batch transcribe: model not loaded, waiting...")
            for _ in 0..<60 {
                try? await Task.sleep(for: .seconds(1))
                if transcriptionService.isModelLoaded { break }
            }
        }
        guard transcriptionService.isModelLoaded else {
            fileLog("Batch transcribe: model not loaded after 60s — skipping")
            return
        }

        fileLog("Batch transcribe: processing \(audioURL.lastPathComponent)...")

        do {
            // Read the WAV file into Float32 samples
            let audioFile = try AVAudioFile(forReading: audioURL)
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

            // If the file isn't 16kHz, we need to read in the file's format
            let fileFormat = audioFile.processingFormat
            let frameCount = AVAudioFrameCount(audioFile.length)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: frameCount) else {
                fileLog("Batch transcribe: failed to create buffer")
                return
            }
            try audioFile.read(into: buffer)

            // Convert to [Float] array for WhisperKit
            guard let channelData = buffer.floatChannelData else {
                fileLog("Batch transcribe: no channel data")
                return
            }
            let samples = Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))

            let duration = Double(samples.count) / 16000.0
            fileLog("Batch transcribe: \(samples.count) samples (\(String(format: "%.0f", duration))s)")

            // Transcribe the complete file
            let segments = try await transcriptionService.transcribe(samples: samples)

            fileLog("Batch transcribe: WhisperKit returned \(segments.count) segments")

            // Filter and save to database
            var savedCount = 0
            for seg in segments {
                let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)

                // Skip noise/hallucination
                if text.isEmpty || text.count <= 1 { continue }
                if text.hasPrefix("[") && text.hasSuffix("]") { continue }
                if text.hasPrefix("(") && text.hasSuffix(")") { continue }

                // Skip repetitive hallucinations
                if text.count > 50 {
                    let words = text.components(separatedBy: .whitespaces)
                    if words.count > 10 {
                        let uniqueWords = Set(words)
                        if Double(uniqueWords.count) / Double(words.count) < 0.2 { continue }
                    }
                }

                let transcript = Transcript(
                    meetingId: meetingId,
                    speakerLabel: "mic",
                    text: text,
                    startTime: seg.startTime,
                    endTime: seg.endTime,
                    confidence: seg.confidence
                )
                try await transcriptRepository.saveBatch([transcript])
                savedCount += 1
            }

            fileLog("Batch transcribe: saved \(savedCount) transcript segments to DB")
            Logger.transcription.info("Batch transcription complete: \(savedCount) segments for meeting \(meetingId)")

        } catch {
            fileLog("Batch transcribe: ERROR — \(error.localizedDescription)")
            Logger.transcription.error("Batch transcription failed: \(error.localizedDescription)")
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
            default: model = .baseEn  // base-en is 2x more accurate than tiny-en
            }

            Logger.transcription.info("Auto-loading WhisperKit model: \(model.rawValue)")
            fileLog("Model: loading \(model.rawValue)...")
            isLoadingModel = true
            do {
                try await transcriptionService.loadModel(model)
                Logger.transcription.info("WhisperKit model loaded — transcription is ready")
                fileLog("Model: LOADED successfully — ready for transcription")
            } catch {
                Logger.transcription.error("Failed to auto-load WhisperKit model: \(error.localizedDescription)")
                fileLog("Model: FAILED to load — \(error.localizedDescription)")
            }
            isLoadingModel = false
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

        if settings.autoRecord {
            // Auto-record: immediately create meeting and start recording
            fileLog("handleCallDetected: autoRecord=true, creating meeting for \(appName)")
            Task { @MainActor in
                do {
                    let title = "\(appName) Meeting"
                    let meeting = try await self.stateMachine.createAndStartMeeting(title: title)
                    self.activeMeeting = self.stateMachine.currentMeeting
                    self.isRecording = self.stateMachine.isRecording
                    self.selectedMeetingId = meeting.id
                    self.loadMeetings()
                    self.fileLog("handleCallDetected: meeting created \(meeting.id) — transcription runs after meeting ends")
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

    // Live transcription removed — batch transcription after meeting ends is dramatically more accurate.
    // See batchTranscribe() which runs WhisperKit's sequential long-form algorithm on the complete WAV.

    // MARK: - File Logging (for debugging with user)

    /// Append a line to a shared log file that both the app and Claude can read.
    static let logFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/MeetingManager/app.log")

    func fileLog(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: Self.logFile.path) {
                if let handle = try? FileHandle(forWritingTo: Self.logFile) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: Self.logFile)
            }
        }
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
        // Create ad-hoc meeting via state machine (manual "New Meeting" button)
        NotificationCenter.default.publisher(for: .createNewMeeting)
            .sink { [weak self] _ in
                guard let self else { return }
                self.fileLog("createNewMeeting notification received")
                Task {
                    do {
                        let meeting = try await self.stateMachine.createAndStartMeeting(title: "New Meeting")
                        await MainActor.run {
                            self.activeMeeting = self.stateMachine.currentMeeting
                            self.isRecording = self.stateMachine.isRecording
                            self.selectedMeetingId = meeting.id
                            self.fileLog("Meeting created: \(meeting.id) — transcription runs after meeting ends")
                        }
                        self.loadMeetings()
                    } catch {
                        Logger.general.error("Failed to create ad-hoc meeting: \(error.localizedDescription)")
                        await MainActor.run { self.lastUserError = error.localizedDescription }
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

        // Call app closed — auto-stop recording if active
        NotificationCenter.default.publisher(for: .callAppTerminated)
            .sink { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    if self.isRecording {
                        Logger.general.info("Call ended — auto-stopping recording")
                        self.stopRecording()
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
}

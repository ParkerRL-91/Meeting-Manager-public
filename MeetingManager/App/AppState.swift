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

    // State machine — single source of truth for meeting lifecycle
    private(set) var stateMachine: MeetingStateMachine

    private var cancellables = Set<AnyCancellable>()
    private var proximityTimer: Timer?

    init() {
        self.database = AppDatabase.shared
        self.meetingRepository = MeetingRepository(database: database)
        self.transcriptRepository = TranscriptRepository(database: database)
        self.noteRepository = NoteRepository(database: database)
        self.summaryRepository = SummaryRepository(database: database)
        self.audioCaptureService = AudioCaptureService()
        self.stateMachine = MeetingStateMachine(
            meetingRepository: meetingRepository,
            audioCaptureService: audioCaptureService
        )

        loadMeetings()
        loadSettings()
        observeNotifications()
        startProximityCheck()
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

    /// Start recording — delegates to the state machine.
    func startRecording(for meeting: Meeting) {
        Task {
            do {
                try await stateMachine.startRecording(meeting: meeting)
                self.activeMeeting = self.stateMachine.currentMeeting
                self.isRecording = self.stateMachine.isRecording
                self.selectedMeetingId = self.stateMachine.currentMeeting?.id
                loadMeetings()
            } catch {
                print("Failed to start recording: \(error)")
            }
        }
    }

    /// Stop recording — delegates to the state machine.
    func stopRecording() {
        Task {
            do {
                try await stateMachine.stopRecording()
                self.activeMeeting = self.stateMachine.currentMeeting
                self.isRecording = self.stateMachine.isRecording
                loadMeetings()
            } catch {
                print("Failed to stop recording: \(error)")
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
                    } catch {
                        print("Failed to create ad-hoc meeting: \(error)")
                    }
                }
            }
            .store(in: &cancellables)

        // Sync local state when the state machine posts a change
        NotificationCenter.default.publisher(for: .meetingStateChanged)
            .sink { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    self.activeMeeting = self.stateMachine.currentMeeting
                    self.isRecording = self.stateMachine.isRecording
                    self.loadMeetings()
                }
            }
            .store(in: &cancellables)
    }
}

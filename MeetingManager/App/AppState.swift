import SwiftUI
import Combine

@Observable
final class AppState {
    var selectedMeetingId: String?
    var isRecording = false
    var activeMeeting: Meeting?
    var meetings: [Meeting] = []
    var upcomingMeetings: [Meeting] = []
    var pastMeetings: [Meeting] = []
    var navigationPath = NavigationPath()

    // Services
    let database: AppDatabase
    let meetingRepository: MeetingRepository
    let transcriptRepository: TranscriptRepository
    let noteRepository: NoteRepository
    let summaryRepository: SummaryRepository

    private var cancellables = Set<AnyCancellable>()
    private(set) var stateMachine: MeetingStateMachine?

    init() {
        self.database = AppDatabase.shared
        self.meetingRepository = MeetingRepository(database: database)
        self.transcriptRepository = TranscriptRepository(database: database)
        self.noteRepository = NoteRepository(database: database)
        self.summaryRepository = SummaryRepository(database: database)

        loadMeetings()
        observeNotifications()
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

    func startRecording(for meeting: Meeting) {
        var updated = meeting
        updated.status = .recording
        updated.startDate = Date()

        Task {
            try? await meetingRepository.save(&updated)
            await MainActor.run {
                self.activeMeeting = updated
                self.isRecording = true
                self.selectedMeetingId = updated.id
            }
            loadMeetings()
        }
    }

    func stopRecording() {
        guard var meeting = activeMeeting else { return }
        meeting.status = .transcribing
        meeting.endDate = Date()

        Task {
            try? await meetingRepository.save(&meeting)
            await MainActor.run {
                self.activeMeeting = nil
                self.isRecording = false
            }
            loadMeetings()
        }
    }

    // MARK: - Notification Observers

    private func observeNotifications() {
        NotificationCenter.default.publisher(for: .createNewMeeting)
            .sink { [weak self] _ in
                Task {
                    let meeting = try? await self?.createMeeting(title: "New Meeting")
                    if let meeting {
                        await MainActor.run {
                            self?.startRecording(for: meeting)
                        }
                    }
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .callAppTerminated)
            .sink { [weak self] _ in
                if self?.isRecording == true {
                    self?.stopRecording()
                }
            }
            .store(in: &cancellables)
    }
}

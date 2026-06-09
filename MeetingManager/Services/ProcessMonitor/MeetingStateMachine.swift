import Foundation
import Combine
import os

// MARK: - State Transition Errors

enum MeetingStateMachineError: LocalizedError {
    case invalidTransition(from: MeetingStatus, to: MeetingStatus)
    case noActiveMeeting
    case meetingNotFound(String)
    case alreadyRecording

    var errorDescription: String? {
        switch self {
        case .invalidTransition(let from, let to):
            return "Invalid state transition from \(from.displayName) to \(to.displayName)."
        case .noActiveMeeting:
            return "No active meeting to perform this action on."
        case .meetingNotFound(let id):
            return "Meeting with id \(id) not found."
        case .alreadyRecording:
            return "Another meeting is already being recorded."
        }
    }
}

// MARK: - MeetingStateMachine

@Observable
@MainActor
final class MeetingStateMachine {

    // MARK: - Observable State

    private(set) var currentMeeting: Meeting?
    private(set) var currentState: MeetingStatus = .scheduled
    private(set) var isRecording: Bool = false

    /// Set synchronously before the first await in startRecording/reopenRecording.
    /// `currentMeeting == nil` alone is a TOCTOU hazard: it's only assigned after
    /// persist + capture start (seconds of awaits), so two interleaved starts both
    /// pass the nil check and the loser's audio lands on the winner's meeting.
    private var isStarting = false

    // MARK: - Dependencies

    private let meetingRepository: MeetingRepository
    private let audioCaptureService: any AudioCapturing

    // MARK: - Notification Observers

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Valid Transitions

    /// Map of source states to allowed destination states.
    private static let allowedTransitions: [MeetingStatus: Set<MeetingStatus>] = [
        .scheduled:    [.notified, .recording, .cancelled],
        .notified:     [.recording, .cancelled],
        .recording:    [.transcribing, .cancelled],
        .transcribing: [.summarizing, .complete, .cancelled],
        .summarizing:  [.complete, .cancelled],
        .complete:     [.recording],   // allows reopen to append audio
        .cancelled:    [.scheduled, .recording],  // allow recovery from crash/cancel
    ]

    // MARK: - Init

    init(meetingRepository: MeetingRepository, audioCaptureService: any AudioCapturing) {
        self.meetingRepository = meetingRepository
        self.audioCaptureService = audioCaptureService
        observeNotifications()
    }

    // MARK: - State Transitions

    /// Transition a scheduled meeting to notified (upcoming).
    func notifyUpcoming(meeting: Meeting) async throws {
        try validateTransition(from: meeting.status, to: .notified)
        var updated = meeting
        updated.status = .notified
        try await persist(&updated)
        postStateChanged(meeting: updated)
    }

    /// Start recording for a meeting. Accepts scheduled or notified meetings.
    func startRecording(meeting: Meeting) async throws {
        guard currentMeeting == nil, !isStarting else {
            throw MeetingStateMachineError.alreadyRecording
        }
        isStarting = true
        defer { isStarting = false }
        try validateTransition(from: meeting.status, to: .recording)

        var updated = meeting
        updated.status = .recording
        updated.startDate = Date()
        Logger.general.info("startRecording: setting startDate=\(updated.startDate!) for meeting \(updated.id)")
        try await persist(&updated)

        // Verify the persist actually wrote the correct startDate
        if let verified = try? await meetingRepository.find(id: updated.id) {
            if verified.startDate != updated.startDate {
                Logger.general.error("startRecording: startDate MISMATCH after persist! expected=\(updated.startDate!), got=\(String(describing: verified.startDate))")
            }
        }

        // Start audio capture — rollback if it fails
        do {
            try await audioCaptureService.startCapture(meetingId: updated.id)
        } catch {
            updated.status = meeting.status
            updated.startDate = meeting.startDate
            try? await persist(&updated)
            throw error
        }

        await persistAudioPathAtStart(&updated)

        currentMeeting = updated
        currentState = .recording
        isRecording = true

        postStateChanged(meeting: updated)
    }

    /// Persist the capture file path the moment recording starts, not only at
    /// stop. If the app crashes mid-recording, the startup cleanup pass needs
    /// the path on the meeting row to route the WAV into transcription instead
    /// of resetting the meeting to `.scheduled` and orphaning the file.
    private func persistAudioPathAtStart(_ meeting: inout Meeting) async {
        guard let path = audioCaptureService.currentAudioFileURL?.path,
              !meeting.audioFilePaths.contains(path) else { return }
        meeting.audioFilePaths.append(path)
        do {
            try await persist(&meeting)
        } catch {
            // Recording is already running — don't fail the start over
            // bookkeeping. stopRecording() appends the path again as backstop.
            Logger.general.error("startRecording: failed to persist audio path at start: \(error.localizedDescription)")
        }
    }

    /// Stop recording the current meeting and transition to transcribing.
    func stopRecording() async throws {
        guard var meeting = currentMeeting else {
            throw MeetingStateMachineError.noActiveMeeting
        }
        try validateTransition(from: meeting.status, to: .transcribing)

        // Stop audio capture and append the new file path to the array.
        let audioURL = audioCaptureService.stopCapture()
        if let path = audioURL?.path, !meeting.audioFilePaths.contains(path) {
            meeting.audioFilePaths.append(path)
        }
        meeting.status = .transcribing
        meeting.endDate = Date()
        try await persist(&meeting)

        currentMeeting = nil
        currentState = .scheduled
        isRecording = false

        postStateChanged(meeting: meeting)
    }

    /// Re-open a completed meeting to append more audio to the same transcript.
    ///
    /// Transitions: complete → recording. The new audio file is appended to
    /// `audioFilePaths` when `stopRecording()` is called.
    func reopenRecording(meeting: Meeting) async throws {
        guard currentMeeting == nil, !isStarting else {
            throw MeetingStateMachineError.alreadyRecording
        }
        isStarting = true
        defer { isStarting = false }
        try validateTransition(from: meeting.status, to: .recording)

        var updated = meeting
        updated.status = .recording
        // Don't overwrite startDate — keep the original recording start time.
        // endDate will be updated when this session stops.
        try await persist(&updated)

        do {
            try await audioCaptureService.startCapture(meetingId: updated.id)
        } catch {
            updated.status = .complete
            try? await persist(&updated)
            throw error
        }

        await persistAudioPathAtStart(&updated)

        currentMeeting = updated
        currentState = .recording
        isRecording = true

        postStateChanged(meeting: updated)
    }

    /// Transition a meeting from transcribing to summarizing.
    func beginSummarization(meeting: Meeting) async throws {
        try validateTransition(from: meeting.status, to: .summarizing)
        var updated = meeting
        updated.status = .summarizing
        try await persist(&updated)
        postStateChanged(meeting: updated)
    }

    /// Mark a meeting as complete.
    func complete(meeting: Meeting) async throws {
        try validateTransition(from: meeting.status, to: .complete)
        var updated = meeting
        updated.status = .complete
        try await persist(&updated)
        postStateChanged(meeting: updated)
    }

    /// Cancel a meeting from any non-terminal state.
    func cancel(meeting: Meeting) async throws {
        try validateTransition(from: meeting.status, to: .cancelled)

        var updated = meeting
        updated.status = .cancelled

        // If this is the active recording, stop capture
        if currentMeeting?.id == meeting.id {
            _ = audioCaptureService.stopCapture()
            updated.endDate = Date()
            currentMeeting = nil
            currentState = .cancelled
            isRecording = false
        }

        try await persist(&updated)
        postStateChanged(meeting: updated)
    }

    // MARK: - Convenience

    /// Create an ad-hoc meeting and immediately start recording.
    func createAndStartMeeting(title: String) async throws -> Meeting {
        var meeting = Meeting(
            title: title,
            startDate: Date(),
            status: .scheduled
        )
        try await meetingRepository.save(&meeting)

        // Now transition to recording through the normal path
        try await startRecording(meeting: meeting)

        // Return the latest version (with recording status)
        return currentMeeting ?? meeting
    }

    /// Start a scheduled meeting early, skipping the notified state.
    func startEarly(meeting: Meeting) async throws {
        guard meeting.status == .scheduled || meeting.status == .notified else {
            throw MeetingStateMachineError.invalidTransition(from: meeting.status, to: .recording)
        }
        try await startRecording(meeting: meeting)
    }

    // MARK: - Notification Observers

    private func observeNotifications() {
        // When a call app launches, auto-start recording
        NotificationCenter.default.publisher(for: .callAppLaunched)
            .sink { [weak self] notification in
                let appName = notification.userInfo?["appName"] as? String
                Task { [weak self] in
                    await self?.handleCallAppLaunched(appName: appName)
                }
            }
            .store(in: &cancellables)

        // NOTE: .callAppTerminated is handled by AppState, which checks
        // recordingStartedByDetector before stopping. The state machine must
        // NOT auto-stop here — doing so kills manually-started recordings
        // when the BrowserCallDetector's mic-usage heuristic loses signal.

        // NOTE: .startRecording / .stopRecording are observed by AppState, NOT
        // here. Stopping via the state machine directly would skip everything
        // that lives only in AppState.stopRecording — transcription enqueue,
        // level-polling teardown, participant-detection stop — leaving the
        // meeting stuck in `.transcribing` with no queued work.
    }

    private func handleCallAppLaunched(appName: String?) async {
        // Don't interrupt an already-running recording.
        guard !isRecording else {
            Logger.general.info("Call app launched but recording already in progress — skipping")
            return
        }

        // The state machine no longer auto-starts. It forwards the event to AppState
        // (via .callAppLaunched notification, which AppState already observes) and lets
        // AppState decide whether to auto-record or just show a notification, based on
        // user settings. This method now only handles linking to nearby scheduled meetings.
        do {
            let nearbyMeetings = try await meetingRepository.meetingsNearDate(Date(), windowMinutes: 15)
            if let scheduledMeeting = nearbyMeetings.first(where: { $0.status == .scheduled || $0.status == .notified }) {
                Logger.general.info("Call app launched — notifying for scheduled meeting: \(scheduledMeeting.title)")
                try await notifyUpcoming(meeting: scheduledMeeting)
            }
            // Ad-hoc meeting creation is now handled by AppState based on autoRecord/autoInvite settings
        } catch {
            Logger.general.error("Failed to handle call app launch: \(error.localizedDescription)")
        }
    }


    // MARK: - Private Helpers

    private func validateTransition(from: MeetingStatus, to: MeetingStatus) throws {
        guard let allowed = Self.allowedTransitions[from], allowed.contains(to) else {
            throw MeetingStateMachineError.invalidTransition(from: from, to: to)
        }
    }

    private func persist(_ meeting: inout Meeting) async throws {
        try await meetingRepository.save(&meeting)
    }

    private func postStateChanged(meeting: Meeting) {
        NotificationCenter.default.post(
            name: .meetingStateChanged,
            object: self,
            userInfo: [
                "meetingId": meeting.id,
                "status": meeting.status.rawValue,
            ]
        )
    }
}

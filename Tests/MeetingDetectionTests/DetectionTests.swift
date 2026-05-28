import XCTest
import Foundation
@testable import MeetingManager

// MARK: - Mock Audio Capture

/// No-op audio capture for tests — lets MeetingStateMachine run without real hardware.
@MainActor
final class MockAudioCapture: AudioCapturing {
    var micLevel: Float = 0
    var systemLevel: Float = 0
    var currentAudioFileURL: URL? = nil
    var onSilenceDetected: (() -> Void)? = nil

    var startCalled = false
    var stopCalled = false

    func startCapture(meetingId: String) async throws {
        startCalled = true
    }

    func stopCapture() -> URL? {
        stopCalled = true
        return nil
    }
}

// MARK: - DetectionTests

final class DetectionTests: XCTestCase {

    // MARK: - CallAppRegistry

    func testKnownCallAppsAreRecognized() {
        // Zoom, Teams, FaceTime, Webex should all be detected
        let knownBundleIDs = [
            "us.zoom.xos",
            "com.microsoft.teams",
            "com.apple.FaceTime",
            "com.cisco.webexmeetingsapp",
        ]
        for bundleID in knownBundleIDs {
            XCTAssertTrue(
                CallAppRegistry.isCallApp(bundleIdentifier: bundleID),
                "Expected \(bundleID) to be a known call app"
            )
        }
    }

    func testUnknownAppsAreNotRecognized() {
        let notCallApps = [
            "com.apple.Safari",
            "com.apple.finder",
            "com.jetbrains.intellij",
        ]
        for bundleID in notCallApps {
            XCTAssertFalse(
                CallAppRegistry.isCallApp(bundleIdentifier: bundleID),
                "Expected \(bundleID) NOT to be a call app"
            )
        }
    }

    func testDisplayNameForZoom() {
        let name = CallAppRegistry.displayName(for: "us.zoom.xos")
        XCTAssertNotNil(name)
        XCTAssertFalse(name!.isEmpty)
    }

    // MARK: - State Machine Notification Response

    /// Stopping an active recording transitions the meeting to `.transcribing`,
    /// clears the active state, and stops audio capture.
    ///
    /// NOTE: auto-stop on `.callAppTerminated` lives in AppState (which owns the
    /// notification observer and the "is this our call app?" check), NOT in
    /// MeetingStateMachine — see the comment in the machine's notification setup.
    /// So this test exercises the machine's real stop contract directly rather
    /// than via a notification the machine doesn't observe.
    @MainActor
    func testStopRecordingTransitionsToTranscribing() async throws {
        let db = try AppDatabase.empty()
        let repo = MeetingRepository(database: db)
        let audio = MockAudioCapture()
        let machine = MeetingStateMachine(
            meetingRepository: repo,
            audioCaptureService: audio
        )

        // Start a meeting (MockAudioCapture.startCapture is a no-op so this succeeds without hardware)
        let meeting = try await machine.createAndStartMeeting(title: "Test Meeting")
        XCTAssertTrue(machine.isRecording, "Should be recording after createAndStartMeeting")
        XCTAssertNotNil(machine.currentMeeting)

        try await machine.stopRecording()

        XCTAssertFalse(machine.isRecording, "Recording should be stopped")
        XCTAssertNil(machine.currentMeeting, "No active meeting after stop")
        XCTAssertTrue(audio.stopCalled, "AudioCapture.stopCapture should have been called")

        // Verify meeting was persisted with .transcribing status
        let persisted = try await repo.find(id: meeting.id)
        XCTAssertNotNil(persisted)
        XCTAssertEqual(persisted?.status, .transcribing, "Meeting should be in transcribing state after stop")
    }

    /// Posting .callAppLaunched when not recording should NOT auto-start recording
    /// (that's AppState's job based on user settings). The state machine should only
    /// link to a nearby scheduled meeting.
    @MainActor
    func testCallLaunchedDoesNotAutoStartWithoutMeeting() async throws {
        let db = try AppDatabase.empty()
        let repo = MeetingRepository(database: db)
        let audio = MockAudioCapture()
        let machine = MeetingStateMachine(
            meetingRepository: repo,
            audioCaptureService: audio
        )

        NotificationCenter.default.post(
            name: .callAppLaunched,
            object: nil,
            userInfo: ["appName": "Zoom", "bundleIdentifier": "us.zoom.xos"]
        )

        try await Task.sleep(for: .seconds(1))

        // No scheduled meetings in the DB — state machine should not auto-start
        XCTAssertFalse(machine.isRecording, "State machine should not auto-start when no scheduled meeting exists")
        XCTAssertFalse(audio.startCalled, "Audio capture should not start without a scheduled meeting")
    }

    /// .meetingStateChanged notification fires after stopRecording.
    @MainActor
    func testMeetingStateChangedFiresOnStop() async throws {
        let db = try AppDatabase.empty()
        let repo = MeetingRepository(database: db)
        let audio = MockAudioCapture()
        let machine = MeetingStateMachine(
            meetingRepository: repo,
            audioCaptureService: audio
        )

        _ = try await machine.createAndStartMeeting(title: "Test")

        var receivedNotification = false
        let observer = NotificationCenter.default.addObserver(
            forName: .meetingStateChanged,
            object: nil,
            queue: .main
        ) { _ in
            receivedNotification = true
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        try await machine.stopRecording()

        // Notification is posted synchronously at end of stopRecording
        XCTAssertTrue(receivedNotification, ".meetingStateChanged should fire when recording stops")
    }
}

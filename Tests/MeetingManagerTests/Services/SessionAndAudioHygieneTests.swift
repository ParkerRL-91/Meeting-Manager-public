import XCTest
@testable import MeetingManager

/// Pins the TASK-026 handler-level behaviors: append-session label
/// namespacing, crash-husk partitioning, and the anti-alias filter's
/// passband/stopband shape.
@MainActor
final class SessionAndAudioHygieneTests: XCTestCase {

    // MARK: - Append-session label namespacing

    private func row(_ label: String?, start: Double = 0) -> Transcript {
        SampleData.makeTranscript(
            meetingId: "m1", speakerLabel: label, text: "hello there friends",
            startTime: start, endTime: start + 4
        )
    }

    func testMaxSpeakerNumberIgnoresResolvedAndMicLabels() {
        XCTAssertEqual(
            AppState.maxSpeakerNumber(in: ["Speaker 2", "Speaker 11", "Alice Chen", "mic", "system"]),
            11
        )
        XCTAssertEqual(AppState.maxSpeakerNumber(in: ["Alice Chen", "mic"]), 0)
    }

    func testShiftMovesOnlyAnonymousSpeakerLabels() {
        let shifted = AppState.shiftSessionSpeakerLabels(
            [row("Speaker 1"), row("Speaker 2"), row("mic"), row("Alice Chen"), row(nil)],
            by: 11
        )
        XCTAssertEqual(shifted[0].speakerLabel, "Speaker 12")
        XCTAssertEqual(shifted[1].speakerLabel, "Speaker 13")
        XCTAssertEqual(shifted[2].speakerLabel, "mic")
        XCTAssertEqual(shifted[3].speakerLabel, "Alice Chen")
        XCTAssertNil(shifted[4].speakerLabel)
    }

    func testShiftZeroIsIdentity() {
        let rows = [row("Speaker 1")]
        XCTAssertEqual(
            AppState.shiftSessionSpeakerLabels(rows, by: 0).first?.speakerLabel,
            "Speaker 1"
        )
    }

    // MARK: - Crash-husk partitioning

    func testPartitionTreatsHeaderScaffoldingAsHusk() {
        // AVAudioFile's header occupies ~4 KB before the first sample — the
        // old `> 44` threshold classified a zero-sample husk as usable.
        let sizes = ["good.wav": 1_000_000, "husk.wav": 4_140]
        let (usable, husks) = AppState.partitionUsableAudioPaths(
            ["good.wav", "husk.wav", "missing.wav", ""],
            sizeOf: { sizes[$0] }
        )
        XCTAssertEqual(usable, ["good.wav"])
        XCTAssertEqual(Set(husks), Set(["husk.wav", "missing.wav"]),
                       "Missing files are husks; empty paths are dropped entirely")
    }

    func testPartitionKeepsAllGoodSessions() {
        let (usable, husks) = AppState.partitionUsableAudioPaths(
            ["a.wav", "b.wav"],
            sizeOf: { _ in 50_000 }
        )
        XCTAssertEqual(usable, ["a.wav", "b.wav"])
        XCTAssertTrue(husks.isEmpty)
    }

    // MARK: - Anti-alias filter shape

    private func rms(_ samples: [Float]) -> Float {
        sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
    }

    private func sine(_ hz: Double, rate: Double, seconds: Double) -> [Float] {
        let n = Int(rate * seconds)
        return (0..<n).map { Float(sin(2 * .pi * hz * Double($0) / rate)) }
    }

    func testBiquadPassesSpeechBandAndAttenuatesAliasingBand() {
        let rate = 48_000.0

        var passFilter = BiquadLowPass()
        passFilter.configure(sampleRate: rate)
        var speech = sine(1_000, rate: rate, seconds: 0.5)
        let speechInRMS = rms(speech)
        passFilter.process(&speech)
        XCTAssertGreaterThan(rms(speech), speechInRMS * 0.9,
                             "1 kHz (speech band) must pass nearly untouched")

        var stopFilter = BiquadLowPass()
        stopFilter.configure(sampleRate: rate)
        var hiss = sine(16_000, rate: rate, seconds: 0.5)
        let hissInRMS = rms(hiss)
        stopFilter.process(&hiss)
        XCTAssertLessThan(rms(hiss), hissInRMS * 0.25,
                          "16 kHz (would alias to 0 Hz after 16 kHz decimation) must be strongly attenuated")
    }

    func testBiquadReconfiguresOnRateChange() {
        var filter = BiquadLowPass()
        filter.configure(sampleRate: 48_000)
        XCTAssertEqual(filter.configuredRate, 48_000)
        filter.configure(sampleRate: 44_100)
        XCTAssertEqual(filter.configuredRate, 44_100)
    }
    // MARK: - Mic input format guard (TASK-029)

    func testUsableInputFormatRejectsMidTransitionFormats() {
        // A Bluetooth device mid A2DP→HFP switch reports 0 Hz / 0 channels;
        // tapping that raises an ObjC exception that no Swift catch sees.
        XCTAssertTrue(MicrophoneCapture.isUsableInputFormat(sampleRate: 44_100, channelCount: 1))
        XCTAssertTrue(MicrophoneCapture.isUsableInputFormat(sampleRate: 16_000, channelCount: 2))
        XCTAssertFalse(MicrophoneCapture.isUsableInputFormat(sampleRate: 0, channelCount: 1))
        XCTAssertFalse(MicrophoneCapture.isUsableInputFormat(sampleRate: 48_000, channelCount: 0))
        XCTAssertFalse(MicrophoneCapture.isUsableInputFormat(sampleRate: 0, channelCount: 0))
    }
    // MARK: - Failure honesty (TASK-031) + recordable-match filter (TASK-033)

    func testHumanizedTaskErrorTranslatesCoreAudioCodes() {
        let husk = NSError(domain: "com.apple.coreaudio.avfaudio", code: -50)
        XCTAssertTrue(TaskQueueManager.humanizedTaskError(husk).contains("couldn't be read"))
        XCTAssertTrue(TaskQueueManager.humanizedTaskError(husk).contains("-50"),
                      "Numeric code stays for support")
        let fmt = NSError(domain: NSOSStatusErrorDomain, code: -10868)
        XCTAssertTrue(TaskQueueManager.humanizedTaskError(fmt).contains("format"))
        let offline = URLError(.notConnectedToInternet)
        XCTAssertTrue(TaskQueueManager.humanizedTaskError(offline).contains("internet"))
    }

    func testEmptyResultErrorReadsHuman() {
        let err = AppState.TranscriptionEmptyResultError(rawSeconds: 420)
        XCTAssertTrue(err.localizedDescription.contains("7 minute"))
        XCTAssertTrue(err.localizedDescription.contains("Retry"))
    }

    func testRecordableMatchSkipsLocationBlocks() {
        var home = SampleData.makeMeeting(title: "Home")
        home.status = .scheduled
        home.isAllDay = true
        XCTAssertFalse(AppState.isRecordableCalendarMatch(home), "All-day blocks are never meetings")

        var focus = SampleData.makeMeeting(title: "Untitled Event")
        focus.status = .scheduled
        focus.isAllDay = false
        focus.participants = nil
        focus.meetLink = nil
        XCTAssertFalse(AppState.isRecordableCalendarMatch(focus), "No attendees + no link = not a meeting")

        var real = SampleData.makeMeeting(title: "Connor / Parker - 1:1")
        real.status = .notified
        real.isAllDay = false
        real.meetLink = "https://meet.google.com/abc-defg-hij"
        XCTAssertTrue(AppState.isRecordableCalendarMatch(real))
    }
}

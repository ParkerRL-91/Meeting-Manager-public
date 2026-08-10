import XCTest
@testable import MeetingManager

/// Scenario matrix for `MeetingSwitchDetectionService` (TASK-117).
///
/// Uses an injected clock + providers so no real time, DB, or process events
/// are needed. Emissions are captured via a `.meetingSwitchDetected` observer
/// (posted synchronously on the main thread; the emit `Task` is drained with
/// `pump()`).
@MainActor
final class MeetingSwitchDetectionServiceTests: XCTestCase {

    private var clock = Date(timeIntervalSince1970: 1_000_000)
    private var enabled = true
    private var memo = false
    private var nearby: [Meeting] = []
    private var emissions: [[String: String]] = []
    private var observer: NSObjectProtocol?
    private var service: MeetingSwitchDetectionService!

    /// Comfortably past the 90s arm delay.
    private var pastArmDelay: Date { clock.addingTimeInterval(200) }

    override func setUp() async throws {
        clock = Date(timeIntervalSince1970: 1_000_000)
        enabled = true
        memo = false
        nearby = []
        emissions = []
        service = MeetingSwitchDetectionService(
            now: { [weak self] in self?.clock ?? Date() },
            isEnabled: { [weak self] in self?.enabled ?? true },
            isMemo: { [weak self] in self?.memo ?? false },
            nearMeetings: { [weak self] _ in self?.nearby ?? [] }
        )
        observer = NotificationCenter.default.addObserver(
            forName: .meetingSwitchDetected, object: nil, queue: nil
        ) { [weak self] note in
            if let info = note.userInfo as? [String: String] { self?.emissions.append(info) }
        }
    }

    override func tearDown() async throws {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        service = nil
    }

    /// Drain the emit `Task` (async: it awaits `nearMeetings` then posts).
    private func pump() async {
        for _ in 0..<8 { await Task.yield() }
    }

    private func meet(_ name: String) -> String { "\(name) - Google Meet" }

    /// Arm and complete baseline adoption (union of the first
    /// `confirmPolls + 1` non-empty polls, plus the seed).
    private func armAndAdopt(seed: String? = nil, observing titles: [String]) {
        service.arm(detectorStartedTitle: seed, startedAt: clock)
        for _ in 0..<3 { service.noteBrowserTitles(titles) }
    }

    // 1. Baseline adoption never false-fires (calendar-titled recording, no seed).
    func testBaselineAdoptionNoFalseFire() async {
        service.arm(detectorStartedTitle: nil, startedAt: clock)
        // First stable 2-poll set becomes baseline.
        service.noteBrowserTitles([meet("Design Review")])
        service.noteBrowserTitles([meet("Design Review")])
        clock = pastArmDelay
        // Same title forever — never a switch.
        for _ in 0..<5 { service.noteBrowserTitles([meet("Design Review")]) }
        await pump()
        XCTAssertTrue(emissions.isEmpty)
    }

    // 2. Seeded baseline never false-fires.
    func testSeededBaselineNoFalseFire() async {
        service.arm(detectorStartedTitle: meet("Design Review"), startedAt: clock)
        clock = pastArmDelay
        for _ in 0..<5 { service.noteBrowserTitles([meet("Design Review")]) }
        await pump()
        XCTAssertTrue(emissions.isEmpty)
    }

    // 3. Two tabs open AFTER baseline: new title joins the set → emits, even
    //    though the old tab is still present (set-membership diff).
    func testTwoTabsOpenEmits() async {
        armAndAdopt(seed: meet("Weekly 1:1"), observing: [meet("Weekly 1:1")])
        clock = pastArmDelay
        service.noteBrowserTitles([meet("Weekly 1:1"), meet("Standup")])
        service.noteBrowserTitles([meet("Weekly 1:1"), meet("Standup")])
        await pump()
        XCTAssertEqual(emissions.count, 1)
        XCTAssertEqual(emissions.first?["normalizedTitle"], "standup")
        XCTAssertEqual(emissions.first?["sourceSignal"], "browserTitleChange")
    }

    // 3b. REGRESSION: a leftover tab from the PREVIOUS meeting, present from
    //     the first poll of a seeded (detector-started) recording, is part of
    //     the adopted baseline — never a backward "switch" suggestion. A
    //     genuinely new third title still emits.
    func testSeededLeftoverTabDoesNotFireBackwardSwitch() async {
        armAndAdopt(seed: meet("Standup"),
                    observing: [meet("Weekly 1:1"), meet("Standup")])
        clock = pastArmDelay
        for _ in 0..<5 { service.noteBrowserTitles([meet("Weekly 1:1"), meet("Standup")]) }
        await pump()
        XCTAssertTrue(emissions.isEmpty)
        service.noteBrowserTitles([meet("Standup"), meet("Retro")])
        service.noteBrowserTitles([meet("Standup"), meet("Retro")])
        await pump()
        XCTAssertEqual(emissions.count, 1)
        XCTAssertEqual(emissions.first?["normalizedTitle"], "retro")
    }

    // 4. A single poll of a new title does not emit; the second one does.
    func testRequiresTwoConfirmingPolls() async {
        armAndAdopt(seed: meet("Design Review"), observing: [meet("Design Review")])
        clock = pastArmDelay
        service.noteBrowserTitles([meet("Design Review"), meet("Retro")])
        await pump()
        XCTAssertTrue(emissions.isEmpty)
        service.noteBrowserTitles([meet("Design Review"), meet("Retro")])
        await pump()
        XCTAssertEqual(emissions.count, 1)
    }

    // 4b. One missed poll (throttled AppleScript: background-tab title absent
    //     from a CGWindowList-only poll) does NOT reset the confirm count; two
    //     consecutive misses do.
    func testConfirmWindowToleratesOneMiss() async {
        armAndAdopt(seed: meet("Design Review"), observing: [meet("Design Review")])
        clock = pastArmDelay
        service.noteBrowserTitles([meet("Design Review"), meet("Retro")])  // seen (1)
        service.noteBrowserTitles([meet("Design Review")])                 // miss (tolerated)
        service.noteBrowserTitles([meet("Design Review"), meet("Retro")])  // seen (2) → emit
        await pump()
        XCTAssertEqual(emissions.count, 1)
    }

    // 5. Arm delay suppresses emission; fires once elapsed.
    func testArmDelaySuppresses() async {
        armAndAdopt(seed: meet("Design Review"), observing: [meet("Design Review")])
        // Within 90s — no emit even after two new-title polls.
        service.noteBrowserTitles([meet("Design Review"), meet("Retro")])
        service.noteBrowserTitles([meet("Design Review"), meet("Retro")])
        await pump()
        XCTAssertTrue(emissions.isEmpty)
        // Past the delay, one more poll containing the candidate → emit.
        clock = pastArmDelay
        service.noteBrowserTitles([meet("Design Review"), meet("Retro")])
        await pump()
        XCTAssertEqual(emissions.count, 1)
    }

    // 6. Kill switch off → nothing fires.
    func testKillSwitchDisables() async {
        enabled = false
        service.arm(detectorStartedTitle: meet("Design Review"), startedAt: clock)
        clock = pastArmDelay
        service.noteBrowserTitles([meet("Design Review"), meet("Retro")])
        service.noteBrowserTitles([meet("Design Review"), meet("Retro")])
        await pump()
        XCTAssertTrue(emissions.isEmpty)
    }

    // 7. Memo recording → nothing fires.
    func testMemoExclusion() async {
        memo = true
        service.arm(detectorStartedTitle: meet("Design Review"), startedAt: clock)
        clock = pastArmDelay
        service.noteBrowserTitles([meet("Design Review"), meet("Retro")])
        service.noteBrowserTitles([meet("Design Review"), meet("Retro")])
        await pump()
        XCTAssertTrue(emissions.isEmpty)
    }

    // 8. A nil/empty poll neither triggers nor resets the confirm count.
    func testEmptyPollDoesNotReset() async {
        armAndAdopt(seed: meet("Design Review"), observing: [meet("Design Review")])
        clock = pastArmDelay
        service.noteBrowserTitles([meet("Design Review"), meet("Retro")])  // count 1
        service.noteBrowserTitles([])                                       // ignored
        service.noteBrowserTitles([meet("Design Review"), meet("Retro")])  // count 2 → emit
        await pump()
        XCTAssertEqual(emissions.count, 1)
    }

    // 9. A dismissed (suppressed) title never re-fires.
    func testSuppressedTitleCooldown() async {
        armAndAdopt(seed: meet("Design Review"), observing: [meet("Design Review")])
        clock = pastArmDelay
        service.suppressTitle("retro")
        service.noteBrowserTitles([meet("Design Review"), meet("Retro")])
        service.noteBrowserTitles([meet("Design Review"), meet("Retro")])
        await pump()
        XCTAssertTrue(emissions.isEmpty)
    }

    // 10. A time-based suppression window blocks, then releases.
    func testSuppressUntilWindow() async {
        armAndAdopt(seed: meet("Design Review"), observing: [meet("Design Review")])
        clock = pastArmDelay
        service.suppress(until: clock.addingTimeInterval(600))
        service.noteBrowserTitles([meet("Design Review"), meet("Retro")])
        service.noteBrowserTitles([meet("Design Review"), meet("Retro")])
        await pump()
        XCTAssertTrue(emissions.isEmpty)
        // Past the window → emits.
        clock = clock.addingTimeInterval(700)
        service.noteBrowserTitles([meet("Design Review"), meet("Retro")])
        service.noteBrowserTitles([meet("Design Review"), meet("Retro")])
        await pump()
        XCTAssertEqual(emissions.count, 1)
    }

    // 11. A second call-app surface emits a medium-confidence candidate.
    func testSecondCallAppMediumConfidence() async {
        service.arm(detectorStartedTitle: meet("Design Review"), startedAt: clock)
        clock = pastArmDelay
        service.noteCallAppEvent(bundleId: "us.zoom.xos", appName: "Zoom", isActivation: false)
        await pump()
        XCTAssertEqual(emissions.count, 1)
        XCTAssertEqual(emissions.first?["sourceSignal"], "secondCallApp")
        XCTAssertEqual(emissions.first?["confidence"], "medium")
        XCTAssertEqual(emissions.first?["bundleIdentifier"], "us.zoom.xos")
    }

    // 12. Calendar booster upgrades to high confidence and attaches a match.
    func testCalendarBoosterUpgradesToHigh() async {
        nearby = [Meeting(id: "m1", title: "Standup", status: .scheduled)]
        armAndAdopt(seed: meet("Design Review"), observing: [meet("Design Review")])
        clock = pastArmDelay
        service.noteBrowserTitles([meet("Design Review"), meet("Standup")])
        service.noteBrowserTitles([meet("Design Review"), meet("Standup")])
        await pump()
        XCTAssertEqual(emissions.count, 1)
        XCTAssertEqual(emissions.first?["confidence"], "high")
        XCTAssertEqual(emissions.first?["matchedMeetingId"], "m1")
    }

    // Disarm forgets state — a post-disarm poll cannot emit.
    func testDisarmStopsDetection() async {
        service.arm(detectorStartedTitle: meet("Design Review"), startedAt: clock)
        clock = pastArmDelay
        service.disarm()
        service.noteBrowserTitles([meet("Design Review"), meet("Retro")])
        service.noteBrowserTitles([meet("Design Review"), meet("Retro")])
        await pump()
        XCTAssertTrue(emissions.isEmpty)
    }
}

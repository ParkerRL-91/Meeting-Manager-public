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

    func testMicCycleBuiltInIsLastAndAlwaysReachable() {
        // 2026-06-15 incident: the Bluetooth IEM (121) was BOTH preferred
        // and system default. The built-in mic (81) must be in the cycle so
        // a dead default doesn't strand capture — but LAST, because in
        // clamshell the lid-closed built-in captures silence.
        let all: [AudioDeviceID] = [121, 81, 86]   // IEM, built-in, AnkerWork
        let order = MicrophoneCapture.orderedCandidates(
            inUseByOthers: [], preferred: 121, systemDefault: 121, builtIn: 81, all: all)
        XCTAssertEqual(order.first, 121, "honor the user's preferred device first")
        XCTAssertEqual(order.last, 81, "built-in is tried LAST (dead in clamshell)")
        XCTAssertEqual(Set(order), Set(all), "every input device is eventually tried")
        XCTAssertEqual(order.count, Set(order).count, "no device tried twice")
    }

    func testMicCyclePrioritizesTheMeetingsInUseMic() {
        // The user's real setup: lid closed, on an external mic the call
        // app is already using. That device must be tried FIRST, and the
        // dead built-in must not preempt it.
        let all: [AudioDeviceID] = [81, 86, 121]   // built-in, AnkerWork(in call), IEM(default)
        let order = MicrophoneCapture.orderedCandidates(
            inUseByOthers: [86],       // the call is on the AnkerWork
            preferred: 121,            // stale preferred = the IEM
            systemDefault: 121,
            builtIn: 81, all: all)
        XCTAssertEqual(order.first, 86, "the mic the meeting is using wins")
        XCTAssertEqual(order.last, 81, "built-in still last")
        XCTAssertEqual(Set(order), Set(all))
    }

    func testMicCycleSkipsUnknownAndOfflineDevices() {
        let all: [AudioDeviceID] = [81]   // only the built-in is actually present
        let order = MicrophoneCapture.orderedCandidates(
            inUseByOthers: [], preferred: 999,   // a saved-but-unplugged USB mic
            systemDefault: kAudioObjectUnknown, builtIn: 81, all: all)
        XCTAssertEqual(order, [81], "absent/unknown devices are dropped; built-in remains as the only option")
    }

    func testEngineFormatAgreementCatchesThePhantomDefault() {
        // The 2026-06-12 incident: engine reported its factory 44.1k/1ch
        // while the HAL said 48k — every start() died with -10868. This
        // rule is what now blocks the start until the views agree.
        XCTAssertFalse(MicrophoneCapture.engineFormatAgreesWithHAL(
            auRate: 44_100, auChannels: 1, halRate: 48_000, halChannels: 1))
        XCTAssertTrue(MicrophoneCapture.engineFormatAgreesWithHAL(
            auRate: 48_000, auChannels: 1, halRate: 48_000, halChannels: 2),
            "the AU presenting a mono view of a stereo device is normal")
        XCTAssertFalse(MicrophoneCapture.engineFormatAgreesWithHAL(
            auRate: 48_000, auChannels: 2, halRate: 48_000, halChannels: 1),
            "more AU channels than the device has is a stale binding")
        XCTAssertFalse(MicrophoneCapture.engineFormatAgreesWithHAL(
            auRate: 0, auChannels: 0, halRate: 48_000, halChannels: 1))
        XCTAssertFalse(MicrophoneCapture.engineFormatAgreesWithHAL(
            auRate: 48_000, auChannels: 1, halRate: 0, halChannels: 0),
            "an unreadable HAL is a failure, not a pass")
        XCTAssertTrue(MicrophoneCapture.engineFormatAgreesWithHAL(
            auRate: 44_100, auChannels: 1, halRate: 44_100.4, halChannels: 1),
            "sub-Hz clock drift tolerated")
    }

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
    // MARK: - Participant typeahead ranking (TASK-035)

    private func person(_ name: String, aliases: [String] = []) -> Person {
        Person.make(canonicalName: name, aliases: aliases)
    }

    func testSuggestionRankingPrefersNamePrefixThenWordThenAlias() {
        let people = [
            person("Joel Parker"),
            person("Parker Reid", aliases: ["parker@acme.com"]),
            person("Erica Smith", aliases: ["erica.parker@corp.com"]),
            person("Dave Brown"),
        ]
        let ranked = ParticipantBar.rankSuggestions(query: "par", people: people, excludedKeys: [])
        XCTAssertEqual(ranked.map(\.canonicalName),
                       ["Parker Reid", "Joel Parker", "Erica Smith"],
                       "Full-name prefix, then word prefix, then alias match — Dave excluded")
    }

    func testSuggestionsExcludeExistingParticipantsAndEmptyQuery() {
        let people = [person("Parker Reid")]
        let excluded: Set<String> = [VocativeMiningService.canonicalKey(for: "Parker Reid")]
        XCTAssertTrue(ParticipantBar.rankSuggestions(query: "par", people: people, excludedKeys: excluded).isEmpty)
        XCTAssertTrue(ParticipantBar.rankSuggestions(query: "  ", people: people, excludedKeys: []).isEmpty)
    }
    // MARK: - Folder grouping (TASK-036)

    func testFolderGroupingMergesDatedVariantsAndExcludesDebris() {
        let meetings = [
            SampleData.makeMeeting(id: "a", title: "Sprint Review 6/10", status: .complete),
            SampleData.makeMeeting(id: "b", title: "Sprint Review 6/17", status: .complete),
            SampleData.makeMeeting(id: "c", title: "Sprint Review 6/24", status: .archived),
            SampleData.makeMeeting(id: "d", title: "One-off chat", status: .complete),
        ]
        let folders = MeetingFolder.group(meetings)
        XCTAssertEqual(folders.count, 1, "Dated variants form one folder; singles and archived don't")
        XCTAssertEqual(folders.first?.meetings.count, 2, "Archived instance excluded")
        XCTAssertEqual(folders.first?.displayName, "Sprint Review")
    }

    func testFolderGroupingThresholdNeedsTwoLiveInstances() {
        let meetings = [
            SampleData.makeMeeting(id: "a", title: "Weekly 1:1", status: .complete),
            SampleData.makeMeeting(id: "b", title: "Weekly 1:1", status: .cancelled),
        ]
        XCTAssertTrue(MeetingFolder.group(meetings).isEmpty,
                      "Cancelled (crash) rows don't count toward the threshold")
    }
    // MARK: - Embedding helpers (TASK-045)

    func testVectorPackUnpackRoundTrip() {
        let v: [Float] = [0.25, -1.5, 3.14159, 0]
        XCTAssertEqual(EmbeddingService.unpack(EmbeddingService.pack(v)), v)
    }

    func testTranscriptChunkingPrefixesSpeakersAndOverlaps() {
        let rows = (0..<60).map { i in
            SampleData.makeTranscript(meetingId: "m1", speakerLabel: "Alice",
                                      text: String(repeating: "word ", count: 20) + "#\(i)",
                                      startTime: Double(i), endTime: Double(i) + 1)
        }
        let chunks = EmbeddingService.chunkTranscript(rows, maxChars: 800, overlap: 100)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks[0].hasPrefix("Alice: "))
        let tail = String(chunks[0].suffix(60))
        XCTAssertTrue(chunks[1].contains(String(tail.suffix(30))), "Overlap carries boundary context")
    }

    func testContentHashStable() {
        XCTAssertEqual(EmbeddingService.hash("hello"), EmbeddingService.hash("hello"))
        XCTAssertNotEqual(EmbeddingService.hash("hello"), EmbeddingService.hash("hello "))
    }
    // MARK: - PII redaction (TASK-054)

    func testRedactorRoundTripsNamesEmailsPhones() {
        let text = "Dave Smith (dave@acme.com, 555-867-5309) will call Erica."
        let r = PIIRedactor.build(knownNames: ["Dave Smith", "Erica"], texts: [text])
        let redacted = r.redact(text)
        XCTAssertFalse(redacted.contains("Dave Smith"))
        XCTAssertFalse(redacted.contains("dave@acme.com"))
        XCTAssertTrue(redacted.contains("Person A"))
        XCTAssertEqual(r.restore(redacted), text, "Round trip restores the original")
    }

    func testRedactorEmptyWhenNothingToRedact() {
        let r = PIIRedactor.build(knownNames: [], texts: ["the quarterly numbers look fine"])
        XCTAssertTrue(r.isEmpty)
    }
    // MARK: - Background work governor (TASK-055)

    private func inputs(recording: Bool = false, nextMeeting: Int? = nil,
                        thermal: ProcessInfo.ThermalState = .nominal,
                        battery: Bool = false, allowBattery: Bool = false,
                        interactive: Bool = false, hour: Int = 14,
                        deferredHours: Double = 0) -> BackgroundWorkPolicy.Inputs {
        .init(isRecording: recording, minutesToNextMeeting: nextMeeting,
              thermalState: thermal, onBattery: battery, allowOnBattery: allowBattery,
              interactivePending: interactive, localHour: hour,
              deferredSinceHours: deferredHours)
    }

    func testGovernorHardBlocks() {
        XCTAssertEqual(BackgroundWorkPolicy.decision(inputs(recording: true)), .deferFor(minutes: 15))
        XCTAssertEqual(BackgroundWorkPolicy.decision(inputs(battery: true)), .deferFor(minutes: 30))
        XCTAssertEqual(BackgroundWorkPolicy.decision(inputs(interactive: true)), .deferFor(minutes: 2))
        XCTAssertEqual(BackgroundWorkPolicy.decision(inputs(battery: true, allowBattery: true)), .run,
                       "Battery opt-in unblocks")
    }

    func testGovernorSoftPreferencesAndStarvationCap() {
        XCTAssertEqual(BackgroundWorkPolicy.decision(inputs(nextMeeting: 10)), .deferFor(minutes: 15))
        XCTAssertEqual(BackgroundWorkPolicy.decision(inputs(thermal: .serious)), .deferFor(minutes: 20))
        XCTAssertEqual(BackgroundWorkPolicy.decision(inputs()), .run)
        // Starved work overrides soft preferences but not an imminent meeting.
        XCTAssertEqual(BackgroundWorkPolicy.decision(inputs(nextMeeting: 10, deferredHours: 25)), .run)
        XCTAssertEqual(BackgroundWorkPolicy.decision(inputs(nextMeeting: 3, deferredHours: 25)), .deferFor(minutes: 10))
        // Hard blocks survive starvation.
        XCTAssertEqual(BackgroundWorkPolicy.decision(inputs(recording: true, deferredHours: 25)), .deferFor(minutes: 15))
    }

    func testBackgroundClassificationIsPerItem() {
        XCTAssertTrue(TaskQueueItem.isBackgroundItem(type: .embedIndex, meetingId: "__embed_backfill__"))
        XCTAssertFalse(TaskQueueItem.isBackgroundItem(type: .embedIndex, meetingId: "real-meeting-id"),
                       "A fresh meeting's embedding runs promptly (review M1)")
        XCTAssertTrue(TaskQueueItem.isBackgroundItem(type: .weeklyDigest, meetingId: "__weekly_digest__"))
        XCTAssertFalse(TaskQueueItem.isBackgroundItem(type: .summary, meetingId: "m"))
    }
    // MARK: - Think-block stripping (daily brief reasoning leak)

    func testStripThinkBlockHandlesClosedInlineAndTruncated() {
        // Closed inline block: keep only what follows the last </think>.
        XCTAssertEqual(
            OllamaService.stripThinkBlock("<think>let me reason about this</think>\n## Summary\nReal brief."),
            "## Summary\nReal brief.")
        // Multiple/nested closes: the LAST close wins.
        XCTAssertEqual(
            OllamaService.stripThinkBlock("<think>a</think>mid<think>b</think>answer"),
            "answer")
        // Truncated reasoning — opened <think>, never closed (ran out of
        // budget mid-thought). Must NOT leak the reasoning.
        XCTAssertEqual(
            OllamaService.stripThinkBlock("<think>the user wants a brief so I should list the meetings and"),
            "")
        // Truncated reasoning after a little real preamble: drop from <think>.
        XCTAssertEqual(
            OllamaService.stripThinkBlock("## Summary\n<think>now I will pad with reasoning that got cut"),
            "## Summary")
        // No think markers at all: returned unchanged.
        XCTAssertEqual(
            OllamaService.stripThinkBlock("## Summary\nPlain brief with no reasoning."),
            "## Summary\nPlain brief with no reasoning.")
    }

    // MARK: - Slide capture (TASK-069)

    func testSlideWindowPickFailsClosed() {
        func cand(_ i: Int, _ bundle: String, _ title: String, _ area: Double) -> SlideCapture.WindowCandidate {
            SlideCapture.WindowCandidate(index: i, bundleID: bundle, title: title, area: area)
        }
        let isCall: (String) -> Bool = { $0 == "us.zoom.xos" }
        let titleCall = SlideCapture.titleLooksLikeCall
        let isPWA = SlideCapture.isPWABundle

        // Tier 1: a native call-app window wins by area, beating a
        // call-titled browser tab.
        XCTAssertEqual(SlideCapture.pickWindow([
            cand(0, "us.zoom.xos", "Zoom Meeting", 800_000),
            cand(1, "us.zoom.xos", "Zoom toolbar", 50_000 * 41),  // bigger area wins
            cand(2, "com.google.Chrome", "Weekly Sync - Google Meet", 900_000),
        ], isCallApp: isCall, titleLooksLikeCall: titleCall, isPWA: isPWA), 1)

        // Tier 2: no native call app — ANY window whose title looks like a
        // call wins, regardless of bundle (browser tab here).
        XCTAssertEqual(SlideCapture.pickWindow([
            cand(0, "com.google.Chrome", "Hacker News", 900_000),
            cand(1, "com.google.Chrome", "Standup - Google Meet", 600_000),
        ], isCallApp: isCall, titleLooksLikeCall: titleCall, isPWA: isPWA), 1)

        // The reported bug: the Google Meet PWA (Chrome app bundle, NOT the
        // bare browser) with a "Meet" title must be found via the title tier.
        XCTAssertEqual(SlideCapture.pickWindow([
            cand(0, "com.apple.finder", "Desktop", 2_000_000),
            cand(1, "com.google.Chrome.app.kjgfgldnnfoeklkmfkjf", "Standup - Google Meet", 700_000),
        ], isCallApp: isCall, titleLooksLikeCall: titleCall, isPWA: isPWA), 1)

        // Tier 3: a Meet PWA whose title is just the meeting name (no "Meet")
        // is still found when it's the ONLY PWA window open.
        XCTAssertEqual(SlideCapture.pickWindow([
            cand(0, "com.apple.finder", "Desktop", 2_000_000),
            cand(1, "com.google.Chrome.app.kjgfgldnnfoeklkmfkjf", "Q3 Planning", 700_000),
        ], isCallApp: isCall, titleLooksLikeCall: titleCall, isPWA: isPWA), 1)

        // But two PWAs with no call title → refuse to guess (fail closed).
        XCTAssertNil(SlideCapture.pickWindow([
            cand(0, "com.google.Chrome.app.notionnotionnotion", "Roadmap", 900_000),
            cand(1, "com.google.Chrome.app.kjgfgldnnfoeklkmfkjf", "Q3 Planning", 700_000),
        ], isCallApp: isCall, titleLooksLikeCall: titleCall, isPWA: isPWA))

        // Nothing qualifies → nil, never a desktop fallback.
        XCTAssertNil(SlideCapture.pickWindow([
            cand(0, "com.apple.finder", "Desktop", 2_000_000),
            cand(1, "com.google.Chrome", "Hacker News", 900_000),
        ], isCallApp: isCall, titleLooksLikeCall: titleCall, isPWA: isPWA))
    }

    func testSlideTitleMatchingCoversMeetVariantsNotFalsePositives() {
        XCTAssertTrue(SlideCapture.titleLooksLikeCall("Standup - Google Meet"))
        XCTAssertTrue(SlideCapture.titleLooksLikeCall("Meet - abc-defg-hij"))
        XCTAssertTrue(SlideCapture.titleLooksLikeCall("meet.google.com/abc-defg"))
        XCTAssertTrue(SlideCapture.titleLooksLikeCall("Parker is presenting"))
        XCTAssertFalse(SlideCapture.titleLooksLikeCall("Q3 meeting notes.md"),
                       "the bare word 'meeting' must not match a document")
        XCTAssertTrue(SlideCapture.isPWABundle("com.google.Chrome.app.kjgfgldn"))
        XCTAssertFalse(SlideCapture.isPWABundle("com.google.Chrome"))
    }

    func testSlideDedupeNormalization() {
        XCTAssertEqual(SlideCapture.normalized("  Pricing\n  TIERS  2026 "),
                       SlideCapture.normalized("pricing tiers 2026"))
        XCTAssertNotEqual(SlideCapture.normalized("pricing tiers 2026"),
                          SlideCapture.normalized("pricing tiers 2027"))
    }

    // MARK: - Speaking stats (TASK-059)

    private func seg(_ label: String, _ start: Double, _ end: Double, _ text: String) -> Transcript {
        SampleData.makeTranscript(meetingId: "m1", speakerLabel: label, text: text,
                                  startTime: start, endTime: end)
    }

    func testSpeechStatsMeasureUserOnly() {
        let rows = [
            seg("mic", 0, 30, "So um I think we should ship Friday. What do you think?"),
            seg("Erica Smith", 30, 90, "I disagree because of the pricing."),
            seg("mic", 85, 100, "Right, you know, fair point."),    // starts inside Erica's turn
            seg("mic", 101, 130, "Let me walk through the plan."),  // 1s gap — same monologue run
        ]
        let stats = SpeechStatsBuilder.build(meetingId: "m1", transcripts: rows,
                                             selfName: "Parker Reid",
                                             now: Date(timeIntervalSince1970: 0))
        let s = try! XCTUnwrap(stats)
        XCTAssertEqual(s.talkShare, 74.0 / 134.0, accuracy: 0.001, "30+15+29 user / 134 total")
        XCTAssertEqual(s.interruptions, 1, "one user turn starts inside another speaker's segment")
        XCTAssertGreaterThan(s.fillerPer100, 0, "um + you know counted")
        XCTAssertGreaterThan(s.questionRate, 0)
        XCTAssertEqual(s.longestMonologueSec, 45, accuracy: 0.001, "85-130 merges across the 1s gap")
    }

    func testSpeechStatsNilWithoutBothSides() {
        let solo = [seg("mic", 0, 60, "Just me talking into a memo.")]
        XCTAssertNil(SpeechStatsBuilder.build(meetingId: "m1", transcripts: solo, selfName: "Parker Reid"),
                     "a memo has no conversation to measure")
        let absent = [seg("Erica Smith", 0, 60, "User never spoke.")]
        XCTAssertNil(SpeechStatsBuilder.build(meetingId: "m1", transcripts: absent, selfName: "Parker Reid"))
    }

    func testSpeechUserLabelMatchesMicAndAttributedName() {
        XCTAssertTrue(SpeechStatsBuilder.isUserLabel("mic", selfKey: VocativeMiningService.canonicalKey(for: "Parker Reid")))
        XCTAssertTrue(SpeechStatsBuilder.isUserLabel("Parker Reid", selfKey: VocativeMiningService.canonicalKey(for: "Parker Reid")))
        XCTAssertFalse(SpeechStatsBuilder.isUserLabel("Speaker 2", selfKey: VocativeMiningService.canonicalKey(for: "Parker Reid")))
        XCTAssertFalse(SpeechStatsBuilder.isUserLabel(nil, selfKey: "x"))
    }

    // MARK: - Video retention (TASK-080)

    func testVideoRetentionExpiry() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let entries: [(meetingId: String, createdAt: Date)] = [
            ("fresh", now.addingTimeInterval(-2 * 86_400)),    // 2 days
            ("old", now.addingTimeInterval(-20 * 86_400)),     // 20 days
            ("edge", now.addingTimeInterval(-14 * 86_400 - 1)),// just past 14d
        ]
        let expired = VideoRetention.expired(entries, retentionDays: 14, now: now)
        XCTAssertEqual(Set(expired), Set(["old", "edge"]))
        XCTAssertFalse(expired.contains("fresh"))
        // retentionDays 0 → never expire (disabled).
        XCTAssertTrue(VideoRetention.expired(entries, retentionDays: 0, now: now).isEmpty)
    }

    // MARK: - Topic trackers (TASK-081)

    func testTopicMatcherFirstMatchAndValidity() {
        let segs = [
            SampleData.makeTranscript(meetingId: "m", speakerLabel: "a", text: "Let's talk roadmap.", startTime: 5, endTime: 9),
            SampleData.makeTranscript(meetingId: "m", speakerLabel: "b", text: "The pricing is the blocker.", startTime: 20, endTime: 25),
            SampleData.makeTranscript(meetingId: "m", speakerLabel: "a", text: "Pricing again later.", startTime: 40, endTime: 44),
        ]
        let m = TopicMatcher.firstMatch(keywords: ["pricing", "discount"], in: segs)
        XCTAssertEqual(m?.atSeconds, 20, "first matching segment by time wins (one hit per meeting)")
        XCTAssertEqual(m?.snippet, "The pricing is the blocker.")
        XCTAssertNil(TopicMatcher.firstMatch(keywords: ["renewal"], in: segs), "no match → nil")
        XCTAssertNil(TopicMatcher.firstMatch(keywords: [], in: segs), "no keywords → nil")
        // Case-insensitive.
        XCTAssertNotNil(TopicMatcher.firstMatch(keywords: ["PRICING"], in: segs))

        XCTAssertTrue(TopicMatcher.isValid(keywords: ["x"], semanticSeed: nil))
        XCTAssertTrue(TopicMatcher.isValid(keywords: [], semanticSeed: "renewals"))
        XCTAssertFalse(TopicMatcher.isValid(keywords: ["  "], semanticSeed: nil))
        XCTAssertFalse(TopicMatcher.isValid(keywords: [], semanticSeed: nil))
    }

    func testTopicKeywordEncodingRoundTrip() {
        let encoded = TopicTracker.encode(keywords: ["price", "pricing", "discount"])
        let t = TopicTracker(id: 1, name: "Pricing", keywords: encoded, semanticSeed: nil, createdAt: Date(), hiddenAt: nil)
        XCTAssertEqual(t.keywordList, ["price", "pricing", "discount"])
    }

    // MARK: - Sentiment (TASK-079)

    func testSentimentLexiconPolarityNegationIntensifier() {
        XCTAssertEqual(SentimentLexicon.score("This is great, I love it.").label, "positive")
        XCTAssertEqual(SentimentLexicon.score("This is a terrible, broken mess.").label, "negative")
        // Negation flips: "not good" must not read positive.
        XCTAssertLessThan(SentimentLexicon.score("this is not good at all").polarity, 0)
        // Intensifier strengthens.
        XCTAssertGreaterThan(SentimentLexicon.score("very good").polarity,
                             SentimentLexicon.score("good").polarity - 0.0001)
        // No valence words → neutral, low magnitude.
        let plain = SentimentLexicon.score("the meeting is on tuesday at three")
        XCTAssertEqual(plain.label, "neutral")
        XCTAssertEqual(plain.magnitude, 0, accuracy: 0.0001)
        XCTAssertEqual(SentimentLexicon.score("").label, "neutral")
    }

    func testSentimentDeadZoneAndMixed() {
        // A faint score stays neutral (dead-zone) rather than flip-flopping.
        XCTAssertEqual(SentimentLexicon.meetingLabel(speakerPolarities: [0.05, -0.05], overall: "neutral"), "neutral")
        // Genuine divergence → mixed.
        XCTAssertEqual(SentimentLexicon.meetingLabel(speakerPolarities: [0.6, -0.6], overall: "positive"), "mixed")
        // One-sided → keep the overall.
        XCTAssertEqual(SentimentLexicon.meetingLabel(speakerPolarities: [0.6, 0.2], overall: "positive"), "positive")
    }

    // MARK: - Clips / key quotes (TASK-078)

    func testClipBuilderFromSegments() {
        let segs = [
            SampleData.makeTranscript(meetingId: "m1", speakerLabel: "Erica", text: "We should ship Friday.", startTime: 10, endTime: 14),
            SampleData.makeTranscript(meetingId: "m1", speakerLabel: "Parker", text: "Agreed.", startTime: 14, endTime: 16),
        ]
        let clip = ClipBuilder.fromSegments(segs, meetingId: "m1", now: Date(timeIntervalSince1970: 0))
        let c = try! XCTUnwrap(clip)
        XCTAssertEqual(c.startTime, 10)
        XCTAssertEqual(c.endTime, 16)
        XCTAssertEqual(c.quoteText, "We should ship Friday. Agreed.")
        XCTAssertEqual(c.speakerLabels, "Erica, Parker")
        XCTAssertEqual(c.timestampLabel, "0:10")
    }

    func testClipBuilderRejectsEmptyAndInverted() {
        XCTAssertNil(ClipBuilder.fromSegments([], meetingId: "m1"))
        let blank = [SampleData.makeTranscript(meetingId: "m1", speakerLabel: "x", text: "   ", startTime: 5, endTime: 8)]
        XCTAssertNil(ClipBuilder.fromSegments(blank, meetingId: "m1"),
                     "all-blank quote → no clip")
        // Single segment is fine (the common case from the context menu).
        let one = [SampleData.makeTranscript(meetingId: "m1", speakerLabel: "Dave", text: "Pricing is the blocker.", startTime: 90, endTime: 95)]
        let c = ClipBuilder.fromSegments(one, meetingId: "m1")
        XCTAssertEqual(c?.timestampLabel, "1:30")
        XCTAssertEqual(c?.quoteText, "Pricing is the blocker.")
    }

    func testClipQuoteLengthCapped() {
        let long = String(repeating: "word ", count: 2000)   // ~10k chars
        let seg = [SampleData.makeTranscript(meetingId: "m1", speakerLabel: "x", text: long, startTime: 0, endTime: 60)]
        let c = ClipBuilder.fromSegments(seg, meetingId: "m1")
        XCTAssertLessThanOrEqual(c?.quoteText.count ?? .max, ClipBuilder.maxQuoteChars + 1)
    }

    // MARK: - Audio playback sync (TASK-077)

    func testActiveSegmentBinarySearch() {
        let starts = [0.0, 5.0, 12.0, 30.0]
        XCTAssertNil(AudioPlaybackService.activeSegmentIndex(forTime: -1, sortedStarts: starts),
                     "before the first segment → none")
        XCTAssertEqual(AudioPlaybackService.activeSegmentIndex(forTime: 0, sortedStarts: starts), 0)
        XCTAssertEqual(AudioPlaybackService.activeSegmentIndex(forTime: 4.9, sortedStarts: starts), 0)
        XCTAssertEqual(AudioPlaybackService.activeSegmentIndex(forTime: 5, sortedStarts: starts), 1,
                       "exactly on a boundary belongs to that segment")
        XCTAssertEqual(AudioPlaybackService.activeSegmentIndex(forTime: 29.9, sortedStarts: starts), 2)
        XCTAssertEqual(AudioPlaybackService.activeSegmentIndex(forTime: 999, sortedStarts: starts), 3,
                       "past the last start → last segment")
        XCTAssertNil(AudioPlaybackService.activeSegmentIndex(forTime: 10, sortedStarts: []))
    }

    func testClampSeekBounds() {
        XCTAssertEqual(AudioPlaybackService.clampSeek(-5, duration: 100), 0)
        XCTAssertEqual(AudioPlaybackService.clampSeek(50, duration: 100), 50)
        XCTAssertEqual(AudioPlaybackService.clampSeek(150, duration: 100), 100)
        XCTAssertEqual(AudioPlaybackService.clampSeek(50, duration: 0), 50,
                       "unknown duration (0) doesn't clamp the upper bound")
    }

    func testCumulativeOffsetsForAppendedSessions() {
        // A meeting with three appended audio files: global time maps to the
        // right file via the cumulative offsets.
        XCTAssertEqual(AudioPlaybackService.cumulativeOffsets(durations: [10, 20, 5]), [0, 10, 30])
        XCTAssertEqual(AudioPlaybackService.cumulativeOffsets(durations: []), [])
        XCTAssertEqual(AudioPlaybackService.cumulativeOffsets(durations: [42]), [0])
    }

    // MARK: - In-app LLM runtime + model tags (TASK-082)

    func testSmallTierIsTheNonThinkingInstructTag() {
        // The pushed small/default model must be the NON-thinking instruct
        // build, never the bare/thinking qwen3:4b (ADR-007: 30 min–2 h
        // summaries). This guards the regression at its source.
        XCTAssertEqual(OllamaService.smallTier, "qwen3:4b-instruct")
        XCTAssertEqual(OllamaService.defaultModel, "qwen3:4b-instruct")
        XCTAssertFalse(OllamaService.isPushableDefault("qwen3:4b"),
                       "bare qwen3:4b is thinking-only — never a default")
        XCTAssertFalse(OllamaService.isPushableDefault("qwen3:4b-thinking"))
        XCTAssertTrue(OllamaService.isPushableDefault("qwen3:4b-instruct"))
        XCTAssertTrue(OllamaService.isPushableDefault("qwen3:8b"))
        // The default the app ships must itself be pushable.
        XCTAssertTrue(OllamaService.isPushableDefault(AppSettings.default.ollamaModel))
        XCTAssertTrue(OllamaService.isPushableDefault(OllamaService.smallTier))
        // Adaptive tiers must not contain the bare/thinking 4B either.
        XCTAssertFalse(OllamaService.modelTiers.contains { $0.name == "qwen3:4b" },
                       "adaptive selection must use the instruct 4B, not the thinking one")
    }

    func testPrivateRuntimePathsLiveUnderApplicationSupport() {
        // The managed runtime + models live in our private Application
        // Support dir, not ~/Applications or ~/.ollama (TASK-082 / ADR-016).
        XCTAssertTrue(OllamaInstaller.privateRuntimeDir.path.contains("Application Support/MeetingManager/runtime"))
        XCTAssertEqual(OllamaInstaller.privateRuntimeAppURL.lastPathComponent, "Ollama.app")
        XCTAssertEqual(OllamaInstaller.privateModelsDir.lastPathComponent, "models")
        XCTAssertFalse(OllamaInstaller.privateRuntimeDir.path.contains("/Applications/"),
                       "the runtime must NOT live in a user-facing Applications folder")
    }

    // MARK: - KB email ingestion (TASK-068)

    func testParseEMLKeepsHeadersBodyAndDropsAttachments() {
        let b64 = String(repeating: "JVBERi0xLjQKJcOkw7zDtsOfCjIgMCBvYmoKPDwvTGVuZ3RoIDMgMCBSL0ZpbHRlci9GbGF0ZURl\n", count: 4)
        let eml = """
        From: Erica Smith <erica@acme.com>
        To: parker@acme.com
        Subject: Pilot pricing
        Message-ID: <noise@acme.com>
        Date: Thu, 5 Jun 2026 09:00:00 -0500
        Content-Type: multipart/mixed; boundary="XYZ"

        --XYZ-boundary-line
        Content-Type: text/plain

        The pilot price needs sign-off by Friday.
        Second =
        line soft-wrapped.

        --XYZ-boundary-line
        Content-Type: application/pdf
        Content-Transfer-Encoding: base64

        """ + b64
        let parsed = KnowledgeBaseService.parseEML(eml)
        XCTAssertTrue(parsed.contains("Subject: Pilot pricing"))
        XCTAssertTrue(parsed.contains("From: Erica Smith"))
        XCTAssertFalse(parsed.contains("Message-ID"), "noise headers dropped")
        XCTAssertTrue(parsed.contains("sign-off by Friday"))
        XCTAssertTrue(parsed.contains("Second line soft-wrapped"), "quoted-printable soft break decoded")
        XCTAssertFalse(parsed.contains("JVBERi0x"), "base64 attachment runs dropped")
        XCTAssertFalse(parsed.contains("Content-Type"), "MIME noise dropped")
        XCTAssertEqual(KnowledgeBaseService.parseEML(""), "")
    }

    // MARK: - Practice mode (TASK-067)

    func testPracticeRecordPrioritizesObjectionsAndDedupes() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        func fact(_ kind: String, _ text: String, daysAgo: Double = 0) -> EntityFact {
            EntityFact(id: nil, entityType: "company", entityKey: "acme.com", meetingId: "m",
                       kind: kind, text: text, owner: nil, dueDate: nil,
                       extractedAt: now.addingTimeInterval(-daysAgo * 86_400))
        }
        let record = PracticeMode.numberedRecord(facts: [
            fact("decision", "Go with vendor B"),
            fact("objection", "Price too high", daysAgo: 5),
            fact("objection", "Price too high", daysAgo: 5),   // dupe
            fact("question", "Who owns rollout?"),
        ])
        XCTAssertEqual(record.map(\.fact.kind), ["objection", "question", "decision"],
                       "objections lead, dupes collapse")
        XCTAssertEqual(record.map(\.index), [1, 2, 3], "indexes are 1-based and contiguous")

        let prompt = PracticeMode.systemPrompt(personaName: "Acme", record: record)
        XCTAssertTrue(prompt.contains("[1]") && prompt.contains("Price too high"))
        XCTAssertTrue(prompt.contains("ONLY positions"), "grounding rule present")
    }

    func testPracticeConversationPromptCapsTurns() {
        let turns = (0..<20).map { (role: $0.isMultiple(of: 2) ? "user" : "persona", text: "turn \($0)") }
        let prompt = PracticeMode.conversationPrompt(turns: turns, personaName: "Acme", maxTurns: 4)
        XCTAssertFalse(prompt.contains("turn 15"), "old turns drop")
        XCTAssertTrue(prompt.contains("turn 19"))
        XCTAssertTrue(prompt.hasSuffix("Acme:"), "ends awaiting the persona's line")
    }

    // MARK: - Handover docs (TASK-062)

    func testHandoverPromptAssemblesOnlyProvidedRecord() {
        let prompt = HandoverDoc.userPrompt(
            folderName: "Acme Weekly",
            participants: ["Parker", "Erica"],
            threadContent: "Where things stand: pilot scoped.",
            facts: [
                EntityFact(id: 1, entityType: "series", entityKey: "acme weekly", meetingId: "m1",
                           kind: "decision", text: "Go with vendor B", owner: "Erica",
                           dueDate: nil, extractedAt: Date(timeIntervalSince1970: 1_700_000_000)),
            ],
            summaries: [("Acme Weekly", Date(timeIntervalSince1970: 1_700_000_000), "Summary text here")])
        XCTAssertTrue(prompt.contains("Series: Acme Weekly"))
        XCTAssertTrue(prompt.contains("Running thread:"))
        XCTAssertTrue(prompt.contains("[decision]") && prompt.contains("(Erica): Go with vendor B"))
        XCTAssertTrue(prompt.contains("Summary text here"))

        let empty = HandoverDoc.userPrompt(folderName: "X", participants: [],
                                           threadContent: nil, facts: [], summaries: [])
        XCTAssertEqual(empty, "Series: X", "absent record parts add no empty sections")
    }

    // MARK: - Meeting intent & ROI (TASK-065)

    func testIntentScoreParsingRejectsUnknownScores() {
        XCTAssertEqual(IntentScoring.parse(#"{"score":"met","note":"Pilot date agreed."}"#)?.score, "met")
        XCTAssertNil(IntentScoring.parse(#"{"score":"amazing","note":"x"}"#),
                     "scores outside the enum are rejected, not stored")
        XCTAssertNil(IntentScoring.parse("not json"))
    }

    func testFolderStatsDedupeFanOutAndGateThinData() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        func meeting(_ id: String, hours: Double) -> Meeting {
            var m = Meeting(title: id, startDate: now, endDate: now.addingTimeInterval(hours * 3600), status: .complete)
            m.id = id
            return m
        }
        let meetings = [meeting("m1", hours: 1.0), meeting("m2", hours: 1.0)]
        let facts = [
            receiptFact("decision", "Go with vendor B", type: "series"),
            receiptFact("decision", "Go with vendor B", type: "person"),   // fan-out dupe
            receiptFact("commitment", "Send deck"),                         // wrong kind
        ].map { f -> EntityFact in var c = f; c.meetingId = "m1"; return c }
        let intents = [
            MeetingIntent(meetingId: "m1", intent: "agree vendor", outcomeScore: "met",
                          outcomeNote: nil, createdAt: now, scoredAt: now),
            MeetingIntent(meetingId: "m2", intent: "budget", outcomeScore: nil,
                          outcomeNote: nil, createdAt: now, scoredAt: nil),  // unscored — excluded
        ]
        let stats = MeetingROI.folderStats(meetings: meetings, decisionFacts: facts, intents: intents)
        XCTAssertEqual(stats.decisionCount, 1, "fan-out rows are one decision")
        XCTAssertEqual(stats.decisionsPerHour, 0.5)
        XCTAssertEqual(stats.intentsSet, 1, "unscored intents don't count yet")
        XCTAssertEqual(stats.hitRate, 1.0)

        let thin = MeetingROI.folderStats(
            meetings: [meeting("m3", hours: 0.4)],
            decisionFacts: [], intents: [])
        XCTAssertNil(thin.decisionsPerHour, "under an hour of recorded time, the rate is noise")
        XCTAssertNil(thin.hitRate)
    }

    // MARK: - Glossary miner (TASK-064)

    func testJargonTokensMatchCapsAndCamelCase() {
        let tokens = GlossaryMiner.jargonTokens(in: "The MTB reviewed Acme output via taskQueue, which was okay.")
        XCTAssertTrue(tokens.contains("MTB"))
        XCTAssertTrue(tokens.contains("Acme"))
        XCTAssertTrue(tokens.contains("taskQueue"))
        XCTAssertFalse(tokens.contains("okay"), "plain lowercase words never match")
    }

    func testGlossaryCandidatesRespectFloorDictionaryAndTombstones() {
        let transcripts = [
            "m1": "MTB met today. The MTB agreed.\nAPIs are fine.",
            "m2": "MTB review went long.\nAPIs again.",
            "m3": "Another MTB session.\nCEO joined.",
        ]
        let dictionary: Set<String> = ["api", "ceo"]   // stand-in for /usr/share/dict/words
        let fresh = GlossaryMiner.candidates(
            transcriptsByMeeting: transcripts, dictionary: dictionary, excluded: [])
        XCTAssertEqual(fresh.map(\.term), ["MTB"],
                       "APIs dies to the dictionary (plural stem), CEO to the dictionary, MTB passes the 3-meeting floor")
        XCTAssertEqual(fresh[0].exampleMeetingId, "m1", "the meeting with the most usage lines is the example")
        XCTAssertFalse(fresh[0].contexts.isEmpty)

        let tombstoned = GlossaryMiner.candidates(
            transcriptsByMeeting: transcripts, dictionary: dictionary, excluded: ["MTB"])
        XCTAssertTrue(tombstoned.isEmpty, "hidden/stored terms never re-mine")
    }

    func testGlossaryDefinitionParsing() {
        let payload = GlossaryMiner.parseDefinitions(
            #"{"definitions":[{"term":"MTB","definition":"Molecular tumor board meeting"}]}"#)
        XCTAssertEqual(payload?.definitions.first?.term, "MTB")
        XCTAssertNil(GlossaryMiner.parseDefinitions("not json"))
    }

    // MARK: - FAQ & objections (TASK-063)

    func testObjectionsParseMapAndStayBackwardCompatible() throws {
        // New shape: objections fan out like other facts, owner preserved.
        let payload = try XCTUnwrap(InsightExtraction.parse(
            #"{"decisions":[],"commitments":[],"questions":[],"objections":[{"text":"Price is too high for phase 1","owner":"Dave Brown"}],"statusUpdates":[]}"#))
        var meeting = Meeting(title: "Acme Sync", startDate: Date(), endDate: nil, status: .complete)
        meeting.participants = "Parker Reid, Dave Brown"
        let facts = InsightExtraction.facts(from: payload, meeting: meeting, participantDomains: ["acme.com"])
        let objections = facts.filter { $0.kind == "objection" }
        XCTAssertTrue(objections.contains { $0.entityType == "company" && $0.entityKey == "acme.com" })
        XCTAssertTrue(objections.allSatisfy { $0.owner == "Dave Brown" })

        // Old shape (no objections key) still parses — optional field.
        XCTAssertNotNil(InsightExtraction.parse(
            #"{"decisions":[],"commitments":[],"questions":[],"statusUpdates":[]}"#))
    }

    // MARK: - Topic trajectories (TASK-057)

    func testTrajectoryMergesPerMeetingChronologically() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        func meeting(_ id: String, daysAgo: Double) -> Meeting {
            var m = Meeting(title: "T-\(id)", startDate: now.addingTimeInterval(-daysAgo * 86_400),
                            endDate: nil, status: .complete)
            m.id = id
            return m
        }
        let meetings = [meeting("a", daysAgo: 30), meeting("b", daysAgo: 10), meeting("c", daysAgo: 1)]
        let points = TrajectoryBuilder.build(
            semanticHits: [("b", "weak chunk", 0.5), ("b", "best chunk", 0.9), ("a", "old chunk", 0.6)],
            ftsHits: [("b", "fts snippet ignored — semantic won"), ("c", "fts only meeting")],
            meetings: meetings)
        XCTAssertEqual(points.map(\.meetingId), ["a", "b", "c"], "oldest first")
        XCTAssertEqual(points[1].excerpt, "best chunk", "highest-scoring chunk represents the meeting")
        XCTAssertEqual(points[2].excerpt, "fts only meeting", "FTS fills semantic gaps")
    }

    func testStanceApplicationClampsToEightWordsAndBadIndexes() {
        let base = [TrajectoryBuilder.Point(meetingId: "m", title: "t",
                                            date: Date(timeIntervalSince1970: 0), excerpt: "e")]
        let labeled = TrajectoryBuilder.applyStances(
            #"{"labels":[{"index":0,"stance":"one two three four five six seven eight nine ten"},{"index":7,"stance":"out of range"}]}"#,
            to: base)
        XCTAssertEqual(labeled[0].stance, "one two three four five six seven eight")
        XCTAssertEqual(TrajectoryBuilder.applyStances("garbage", to: base)[0].stance, nil,
                       "unparseable responses leave the timeline unlabeled")
    }

    // MARK: - Who-knows-what (TASK-060)

    func testAffinityRanksByScoreTimesRecencyAndExcludesSelf() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        func meeting(_ id: String, daysAgo: Double, people: [String]) -> Meeting {
            var m = Meeting(title: id, startDate: now.addingTimeInterval(-daysAgo * 86_400),
                            endDate: nil, status: .complete)
            m.id = id
            m.participants = people.joined(separator: ", ")
            return m
        }
        let meetings = [
            meeting("recent", daysAgo: 5, people: ["Parker Reid", "Erica Smith"]),
            meeting("old", daysAgo: 200, people: ["Parker Reid", "Dave Brown"]),
            meeting("weak", daysAgo: 5, people: ["Parker Reid", "Zoe Quinn"]),
        ]
        let hits: [(meetingId: String, score: Float)] = [
            ("recent", 0.8), ("recent", 0.6),   // dedupes to max 0.8
            ("old", 0.8),                        // same score, decayed by age
            ("weak", 0.3),                       // below minScore — dropped
        ]
        let ranked = PersonTopicAffinity.rank(hits: hits, meetings: meetings,
                                              excludingSelf: "Parker Reid", now: now)
        XCTAssertEqual(ranked.map(\.name), ["Erica Smith", "Dave Brown"],
                       "recency beats equal raw score; sub-threshold hits and self never appear")
        XCTAssertEqual(ranked[0].meetingCount, 1, "chunks from one meeting count once")
        XCTAssertGreaterThan(ranked[0].score, ranked[1].score)
    }

    // MARK: - Relationship health (TASK-061)

    private func daysAgo(_ d: Double, from now: Date) -> Date { now.addingTimeInterval(-d * 86_400) }

    func testHealthySteadyCadenceProducesNoSignals() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let dates = stride(from: 7.0, through: 70, by: 7).map { daysAgo($0, from: now) }
        XCTAssertTrue(RelationshipHealth.signals(meetingDates: dates, openItems: [], now: now).isEmpty,
                      "weekly cadence with a 7-day-old last meeting is healthy")
    }

    func testStaleContactNeedsDoubleTypicalGapAndFloor() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        // Weekly for 8 weeks, then 30 days of silence: 30 ≥ max(21, 14).
        let dates = stride(from: 30.0, through: 79, by: 7).map { daysAgo($0, from: now) }
        let signals = RelationshipHealth.signals(meetingDates: dates, openItems: [], now: now)
        XCTAssertEqual(signals.map(\.kind), [.staleContact])
        XCTAssertTrue(signals[0].detail.contains("30 days ago"))

        // Monthly cadence: a 30-day gap is NORMAL (2×30=60 not reached).
        let monthly = stride(from: 30.0, through: 120, by: 30).map { daysAgo($0, from: now) }
        XCTAssertTrue(RelationshipHealth.signals(meetingDates: monthly, openItems: [], now: now).isEmpty,
                      "a monthly relationship is not stale after one month")
    }

    func testCadenceDropHalvedButNotSilent() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        // Baseline window (30-90d ago): 6 meetings (~3/month). Recent 30d:
        // one meeting 5 days ago — not stale (gap small), but halved.
        var dates = stride(from: 35.0, through: 85, by: 10).map { daysAgo($0, from: now) }
        dates.append(daysAgo(5, from: now))
        let signals = RelationshipHealth.signals(meetingDates: dates, openItems: [], now: now)
        XCTAssertEqual(signals.map(\.kind), [.cadenceDrop])
        XCTAssertFalse(signals[0].detail.isEmpty)
    }

    func testNewContactsAndAgingItemsGates() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        // Two meetings = below the cadence floor; no cadence signals ever.
        let newbie = [daysAgo(50, from: now), daysAgo(2, from: now)]
        // One overdue item + one fresh no-due item: only the overdue counts.
        let items: [(extractedAt: Date, dueDate: Date?)] = [
            (daysAgo(10, from: now), daysAgo(3, from: now)),   // past due
            (daysAgo(5, from: now), nil),                       // fresh, no due date
        ]
        let signals = RelationshipHealth.signals(meetingDates: newbie, openItems: items, now: now)
        XCTAssertEqual(signals.map(\.kind), [.agingItems])
        XCTAssertTrue(signals[0].detail.hasPrefix("1 open item "))

        XCTAssertTrue(RelationshipHealth.signals(meetingDates: [daysAgo(1, from: now)],
                                                 openItems: items, now: now).isEmpty,
                      "a single meeting isn't a relationship yet — no signals at all")
    }

    // MARK: - Knowledge gardener (TASK-056)

    private func gardenFact(_ id: Int64, key: String = "weekly sync", kind: String = "decision",
                            meetingId: String, text: String, daysAgo: Double,
                            hidden: Bool = false) -> EntityFact {
        var f = EntityFact(id: id, entityType: "series", entityKey: key, meetingId: meetingId,
                           kind: kind, text: text, owner: nil, dueDate: nil,
                           extractedAt: Date(timeIntervalSince1970: 1_000_000 - daysAgo * 86_400))
        if hidden { f.hiddenAt = Date(timeIntervalSince1970: 999_999) }
        return f
    }

    func testGardenerCosine() {
        XCTAssertEqual(GardenerService.cosine([1, 0], [0, 1]), 0)
        XCTAssertEqual(GardenerService.cosine([1, 2], [1, 2]), 1, accuracy: 0.0001)
        XCTAssertEqual(GardenerService.cosine([], []), 0, "empty vectors score 0, not NaN")
    }

    func testCandidatePairsRespectGatesAndOrdering() {
        let a = gardenFact(1, meetingId: "m1", text: "Ship Friday", daysAgo: 10)
        let b = gardenFact(2, meetingId: "m2", text: "Ship next Monday", daysAgo: 1)
        let sameMeeting = gardenFact(3, meetingId: "m2", text: "Ship someday", daysAgo: 1)
        let otherKind = gardenFact(4, kind: "question", meetingId: "m3", text: "Ship when?", daysAgo: 2)
        let hidden = gardenFact(5, meetingId: "m4", text: "Ship eventually", daysAgo: 3, hidden: true)
        let near: [Float] = [1, 0.1], far: [Float] = [0, 1]
        let vectors: [String: [Float]] = [
            "Ship Friday": near, "Ship next Monday": near, "Ship someday": near,
            "Ship when?": near, "Ship eventually": near, "Unrelated topic": far,
        ]
        let pairs = GardenerService.candidatePairs(
            facts: [a, b, sameMeeting, otherKind, hidden],
            vectors: vectors)
        XCTAssertEqual(pairs.count, 1, "same-meeting, cross-kind, and hidden facts never pair")
        XCTAssertEqual(pairs.first?.older.id, 1, "older by extractedAt")
        XCTAssertEqual(pairs.first?.newer.id, 2)

        let excluded = GardenerService.candidatePairs(
            facts: [a, b], vectors: vectors, excludedPairKeys: ["1-2"])
        XCTAssertTrue(excluded.isEmpty, "already-classified pairs are skipped")

        let dissimilar = GardenerService.candidatePairs(
            facts: [a, gardenFact(6, meetingId: "m5", text: "Unrelated topic", daysAgo: 0)],
            vectors: vectors)
        XCTAssertTrue(dissimilar.isEmpty, "below-threshold similarity never reaches the LLM")
    }

    func testGardenerClassificationParses() {
        let payload = GardenerService.parseClassification(
            #"{"pairs":[{"index":0,"relation":"supersedes"},{"index":1,"relation":"unrelated"}]}"#)
        XCTAssertEqual(payload?.pairs.count, 2)
        XCTAssertEqual(payload?.pairs.first?.relation, "supersedes")
        XCTAssertNil(GardenerService.parseClassification("no json here"))
    }

    // MARK: - Receipts follow-ups (TASK-066)

    private func receiptFact(_ kind: String, _ text: String, owner: String? = nil,
                             at startTime: Double? = nil, type: String = "series") -> EntityFact {
        var f = EntityFact(id: nil, entityType: type, entityKey: "k", meetingId: "m",
                           kind: kind, text: text, owner: owner, dueDate: nil,
                           extractedAt: Date(timeIntervalSince1970: 0))
        f.sourceStartTime = startTime
        return f
    }

    func testReceiptTimestampFormatsMinutesAndHours() {
        XCTAssertEqual(ReceiptsBuilder.timestamp(0), "0:00")
        XCTAssertEqual(ReceiptsBuilder.timestamp(872), "14:32")
        XCTAssertEqual(ReceiptsBuilder.timestamp(3729), "1:02:09")
        XCTAssertEqual(ReceiptsBuilder.timestamp(-5), "0:00", "negative offsets clamp instead of crashing")
    }

    func testCommitmentsBlockDedupesFanOutAndPhrasesAnchors() {
        let block = ReceiptsBuilder.commitmentsBlock(facts: [
            receiptFact("commitment", "Ship the pilot Friday", owner: "Erica", at: 872),
            receiptFact("commitment", "Ship the pilot Friday", owner: "Erica", at: 872),
            receiptFact("decision", "Go with vendor B"),
            receiptFact("question", "Budget for Q3?"),
        ])
        XCTAssertEqual(block, "- Ship the pilot Friday (Erica — near 14:32)\n- Go with vendor B",
                       "dupes collapse, anchors read 'near MM:SS', questions excluded")
    }

    func testCommitmentsBlockFallsBackToAnchorSpeakerWhenOwnerless() {
        var fact = receiptFact("decision", "Go with vendor B", at: 95)
        fact.sourceTranscriptId = 7
        let block = ReceiptsBuilder.commitmentsBlock(facts: [fact], speakers: [7: "Dave Brown"])
        XCTAssertEqual(block, "- Go with vendor B (said by Dave Brown — near 1:35)")
    }

    func testCarriedQuestionsBlockOnlyCarriesQuestions() {
        let block = ReceiptsBuilder.carriedQuestionsBlock(facts: [
            receiptFact("question", "Who owns the rollout?"),
            receiptFact("question", "Who owns the rollout?"),
            receiptFact("commitment", "Send the deck"),
        ])
        XCTAssertEqual(block, "- Who owns the rollout?")
    }

    func testApplyAnchorsStampsEveryFanOutRowSharingText() {
        let facts = [
            receiptFact("commitment", "Send the contract", type: "series"),
            receiptFact("commitment", "Send the contract", type: "person"),
            receiptFact("decision", "Unanchored decision", type: "series"),
        ]
        let out = InsightExtraction.applyAnchors(facts, anchors: ["Send the contract": (42, 615.0)])
        let stamped = out.filter { $0.text == "Send the contract" }
        XCTAssertEqual(stamped.count, 2)
        XCTAssertTrue(stamped.allSatisfy { $0.sourceTranscriptId == 42 && $0.sourceStartTime == 615.0 },
                      "the same anchor lands on every fan-out row of the fact")
        XCTAssertNil(out.first { $0.text == "Unanchored decision" }?.sourceTranscriptId,
                     "facts without a match ship without a receipt")
    }

    // MARK: - Style learning from edits (TASK-070)

    func testMeetingSummaryOriginalTextSurvivesCodableRoundTrip() throws {
        // GRDB persists through Codable. originalText relies on synthesized
        // keys — if an explicit CodingKeys enum is ever added without it,
        // the column silently stops persisting. This round-trip catches that.
        var s = MeetingSummary(meetingId: "m1", promptUsed: "p", summaryText: "user-edited", isEdited: true)
        s.originalText = "the AI draft before editing"
        let back = try JSONDecoder().decode(MeetingSummary.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back.originalText, "the AI draft before editing")
        XCTAssertEqual(back.summaryText, "user-edited")
        XCTAssertTrue(back.isEdited)

        let fresh = MeetingSummary(meetingId: "m2", promptUsed: "p", summaryText: "new generation")
        let freshBack = try JSONDecoder().decode(MeetingSummary.self, from: JSONEncoder().encode(fresh))
        XCTAssertNil(freshBack.originalText, "new generations carry no style-example source")
    }

    // MARK: - Since you last met (TASK-058)

    func testCounterpartDetectsOneOnOne() {
        XCTAssertEqual(SinceLastMetBuilder.counterpart(
            participants: ["Parker Reid", "Erica Smith"], selfName: "Parker Reid"), "Erica Smith")
        XCTAssertNil(SinceLastMetBuilder.counterpart(
            participants: ["Parker Reid", "Erica Smith", "Dave Brown"], selfName: "Parker Reid"),
            "Two others = not a 1:1")
        XCTAssertNil(SinceLastMetBuilder.counterpart(
            participants: ["A","B","C","D"], selfName: "Parker"), "Big meetings skip")
    }

    func testLastMeetingPicksMostRecentPastWithPerson() {
        let key = VocativeMiningService.canonicalKey(for: "Erica Smith")
        let old = SampleData.makeMeeting(id: "old", title: "1:1", startDate: Date(timeIntervalSinceNow: -14*86400), status: .complete)
        let recent = SampleData.makeMeeting(id: "recent", title: "1:1", startDate: Date(timeIntervalSinceNow: -7*86400), status: .complete)
        var withPerson = [old, recent]
        for i in withPerson.indices { withPerson[i].participants = "Parker Reid, Erica Smith" }
        let without = SampleData.makeMeeting(id: "other", title: "Standup", startDate: Date(timeIntervalSinceNow: -2*86400), status: .complete)
        let result = SinceLastMetBuilder.lastMeeting(with: key, before: Date(), excluding: "upcoming", in: withPerson + [without])
        XCTAssertEqual(result?.id, "recent")
    }
}

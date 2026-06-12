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

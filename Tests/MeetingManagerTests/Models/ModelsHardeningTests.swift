import XCTest
@testable import MeetingManager

// MARK: - Helpers

// Builds a minimal JSON payload from a key/value dictionary using
// only the keys provided. Used to simulate forward/backward-compat
// decoding where newer keys are absent from stored JSON.
private func jsonData(_ dict: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: dict)
}

final class ModelsHardeningTests: XCTestCase {

    // -------------------------------------------------------------------------
    // MARK: - Meeting.duration edge cases
    // -------------------------------------------------------------------------

    // Existing tests cover: nil when start missing, nil when end missing, 3600s, 45 min.
    // Gaps: zero-span, negative span (end < start), sub-minute spans, exact hour boundary.

    func testDurationZeroWhenStartEqualsEnd() {
        let t = Date(timeIntervalSinceReferenceDate: 1000)
        let meeting = SampleData.makeMeeting(startDate: t, endDate: t)
        XCTAssertEqual(meeting.duration, 0)
    }

    func testDurationNegativeWhenEndBeforeStart() {
        let start = Date(timeIntervalSinceReferenceDate: 2000)
        let end   = Date(timeIntervalSinceReferenceDate: 1000)
        let meeting = SampleData.makeMeeting(startDate: start, endDate: end)
        // duration is end - start, which is negative; callers must guard
        XCTAssertEqual(meeting.duration, -1000, accuracy: 0.001)
    }

    func testDurationSubMinute() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let end   = start.addingTimeInterval(30)
        let meeting = SampleData.makeMeeting(startDate: start, endDate: end)
        XCTAssertEqual(meeting.duration, 30, accuracy: 0.001)
    }

    func testDurationExactHour() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let end   = start.addingTimeInterval(3600)
        let meeting = SampleData.makeMeeting(startDate: start, endDate: end)
        XCTAssertEqual(meeting.duration, 3600, accuracy: 0.001)
    }

    // -------------------------------------------------------------------------
    // MARK: - Meeting.formattedDuration edge cases
    // -------------------------------------------------------------------------

    // Existing: "--" when nil, "45 min", "1h 30m". Gaps: 0 min, negative span,
    // sub-minute (rounds to 0), exact 1h, exact 2h, 1h 0m boundary.

    func testFormattedDurationZeroMinutes() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let end   = start.addingTimeInterval(30) // 0 whole minutes
        let meeting = SampleData.makeMeeting(startDate: start, endDate: end)
        // Int(30/60) == 0, which is < 60, so "0 min"
        XCTAssertEqual(meeting.formattedDuration, "0 min")
    }

    func testFormattedDurationExactOneHour() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let end   = start.addingTimeInterval(3600)
        let meeting = SampleData.makeMeeting(startDate: start, endDate: end)
        // minutes == 60 → hours == 1, remaining == 0 → "1h 0m"
        XCTAssertEqual(meeting.formattedDuration, "1h 0m")
    }

    func testFormattedDurationTwoHoursFlat() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let end   = start.addingTimeInterval(7200)
        let meeting = SampleData.makeMeeting(startDate: start, endDate: end)
        XCTAssertEqual(meeting.formattedDuration, "2h 0m")
    }

    func testFormattedDurationNegativeSpanShowsMinFormat() {
        // Negative duration: Int(duration/60) is negative and < 60, so "-N min"
        let start = Date(timeIntervalSinceReferenceDate: 2000)
        let end   = Date(timeIntervalSinceReferenceDate: 1000)
        let meeting = SampleData.makeMeeting(startDate: start, endDate: end)
        // Int(-1000/60) == -16 (Swift truncates toward zero), -16 < 60 → "-16 min"
        XCTAssertEqual(meeting.formattedDuration, "-16 min")
    }

    // -------------------------------------------------------------------------
    // MARK: - Meeting.effectiveDate precedence
    // -------------------------------------------------------------------------

    // Existing tests cover: .scheduled prefers scheduledStartDate, falls back to
    // startDate, then createdAt. Gaps: active/finished statuses prefer startDate
    // first; all status branches tested.

    // For .recording/.transcribing/.summarizing/.complete/.archived:
    //   order = startDate ?? scheduledStartDate ?? createdAt
    func testEffectiveDateForRecordingPrefersStartDate() {
        let start     = Date(timeIntervalSinceReferenceDate: 2000)
        let scheduled = Date(timeIntervalSinceReferenceDate: 1000)
        let created   = Date(timeIntervalSinceReferenceDate: 500)
        let meeting = Meeting(
            title: "X",
            startDate: start,
            scheduledStartDate: scheduled,
            status: .recording,
            createdAt: created,
            updatedAt: created
        )
        XCTAssertEqual(meeting.effectiveDate, start)
    }

    func testEffectiveDateForRecordingFallsBackToScheduledWhenNoStart() {
        let scheduled = Date(timeIntervalSinceReferenceDate: 1000)
        let created   = Date(timeIntervalSinceReferenceDate: 500)
        let meeting = Meeting(
            title: "X",
            startDate: nil,
            scheduledStartDate: scheduled,
            status: .recording,
            createdAt: created,
            updatedAt: created
        )
        XCTAssertEqual(meeting.effectiveDate, scheduled)
    }

    func testEffectiveDateForCompleteFallsBackToCreatedAt() {
        let created = Date(timeIntervalSinceReferenceDate: 500)
        let meeting = Meeting(
            title: "X",
            startDate: nil,
            scheduledStartDate: nil,
            status: .complete,
            createdAt: created,
            updatedAt: created
        )
        XCTAssertEqual(meeting.effectiveDate, created)
    }

    func testEffectiveDateForArchivedPrefersStartDate() {
        let start   = Date(timeIntervalSinceReferenceDate: 3000)
        let created = Date(timeIntervalSinceReferenceDate: 500)
        let meeting = Meeting(
            title: "X",
            startDate: start,
            status: .archived,
            createdAt: created,
            updatedAt: created
        )
        XCTAssertEqual(meeting.effectiveDate, start)
    }

    // For .scheduled/.notified/.cancelled:
    //   order = scheduledStartDate ?? startDate ?? createdAt
    func testEffectiveDateForScheduledPrefersScheduledStart() {
        let start     = Date(timeIntervalSinceReferenceDate: 2000)
        let scheduled = Date(timeIntervalSinceReferenceDate: 1000)
        let created   = Date(timeIntervalSinceReferenceDate: 500)
        let meeting = Meeting(
            title: "X",
            startDate: start,
            scheduledStartDate: scheduled,
            status: .scheduled,
            createdAt: created,
            updatedAt: created
        )
        XCTAssertEqual(meeting.effectiveDate, scheduled)
    }

    func testEffectiveDateForNotifiedFallsBackToStartDate() {
        let start   = Date(timeIntervalSinceReferenceDate: 2000)
        let created = Date(timeIntervalSinceReferenceDate: 500)
        let meeting = Meeting(
            title: "X",
            startDate: start,
            scheduledStartDate: nil,
            status: .notified,
            createdAt: created,
            updatedAt: created
        )
        XCTAssertEqual(meeting.effectiveDate, start)
    }

    func testEffectiveDateForCancelledFallsBackToCreatedAt() {
        let created = Date(timeIntervalSinceReferenceDate: 500)
        let meeting = Meeting(
            title: "X",
            startDate: nil,
            scheduledStartDate: nil,
            status: .cancelled,
            createdAt: created,
            updatedAt: created
        )
        XCTAssertEqual(meeting.effectiveDate, created)
    }

    // -------------------------------------------------------------------------
    // MARK: - Meeting.participantList parsing
    // -------------------------------------------------------------------------

    func testParticipantListNilParticipantsReturnsEmpty() {
        let meeting = Meeting(title: "X", participants: nil, createdAt: SampleData.fixedDate, updatedAt: SampleData.fixedDate)
        XCTAssertEqual(meeting.participantList, [])
    }

    func testParticipantListEmptyStringReturnsEmpty() {
        let meeting = Meeting(title: "X", participants: "", createdAt: SampleData.fixedDate, updatedAt: SampleData.fixedDate)
        XCTAssertEqual(meeting.participantList, [])
    }

    func testParticipantListSingleEntry() {
        let meeting = Meeting(title: "X", participants: "Alice", createdAt: SampleData.fixedDate, updatedAt: SampleData.fixedDate)
        XCTAssertEqual(meeting.participantList, ["Alice"])
    }

    func testParticipantListMultipleEntries() {
        let meeting = Meeting(title: "X", participants: "Alice, Bob, Carol", createdAt: SampleData.fixedDate, updatedAt: SampleData.fixedDate)
        XCTAssertEqual(meeting.participantList, ["Alice", "Bob", "Carol"])
    }

    func testParticipantListDoesNotTrimInternalWhitespace() {
        // The separator is ", " (comma-space). An entry like " Bob " (with extra leading
        // space) comes from a split on ", " and is NOT additionally trimmed.
        let meeting = Meeting(title: "X", participants: "Alice,  Bob", createdAt: SampleData.fixedDate, updatedAt: SampleData.fixedDate)
        // "Alice,  Bob" split by ", " → ["Alice", " Bob"] (note leading space on Bob)
        // This is the actual behavior — no extra trim step.
        XCTAssertEqual(meeting.participantList, ["Alice", " Bob"])
    }

    func testParticipantListDropsEmptyTokens() {
        // components(separatedBy:) on ", , " yields an empty-string entry; filter removes it.
        let meeting = Meeting(title: "X", participants: "Alice, , Bob", createdAt: SampleData.fixedDate, updatedAt: SampleData.fixedDate)
        XCTAssertEqual(meeting.participantList, ["Alice", "Bob"])
    }

    // -------------------------------------------------------------------------
    // MARK: - Meeting.declinedAttendeeList parsing
    // -------------------------------------------------------------------------

    func testDeclinedAttendeeListNilReturnsEmpty() {
        let meeting = Meeting(title: "X", declinedAttendees: nil, createdAt: SampleData.fixedDate, updatedAt: SampleData.fixedDate)
        XCTAssertEqual(meeting.declinedAttendeeList, [])
    }

    func testDeclinedAttendeeListEmptyStringReturnsEmpty() {
        let meeting = Meeting(title: "X", declinedAttendees: "", createdAt: SampleData.fixedDate, updatedAt: SampleData.fixedDate)
        XCTAssertEqual(meeting.declinedAttendeeList, [])
    }

    func testDeclinedAttendeeListParsesMultiple() {
        let meeting = Meeting(title: "X", declinedAttendees: "Dave, Eve", createdAt: SampleData.fixedDate, updatedAt: SampleData.fixedDate)
        XCTAssertEqual(meeting.declinedAttendeeList, ["Dave", "Eve"])
    }

    // -------------------------------------------------------------------------
    // MARK: - Meeting.acceptedParticipantList
    // -------------------------------------------------------------------------

    func testAcceptedParticipantListNoDeclined() {
        let meeting = Meeting(
            title: "X",
            participants: "Alice, Bob",
            declinedAttendees: nil,
            createdAt: SampleData.fixedDate,
            updatedAt: SampleData.fixedDate
        )
        XCTAssertEqual(meeting.acceptedParticipantList, ["Alice", "Bob"])
    }

    func testAcceptedParticipantListDeclinedExcluded() {
        let meeting = Meeting(
            title: "X",
            participants: "Alice, Bob, Carol",
            declinedAttendees: "Bob",
            createdAt: SampleData.fixedDate,
            updatedAt: SampleData.fixedDate
        )
        XCTAssertEqual(meeting.acceptedParticipantList, ["Alice", "Carol"])
    }

    func testAcceptedParticipantListCaseInsensitiveExclusion() {
        // Identity key lowercases both sides.
        let meeting = Meeting(
            title: "X",
            participants: "Alice, BOB",
            declinedAttendees: "bob",
            createdAt: SampleData.fixedDate,
            updatedAt: SampleData.fixedDate
        )
        XCTAssertEqual(meeting.acceptedParticipantList, ["Alice"])
    }

    func testAcceptedParticipantListEmailLocalPartExclusion() {
        // declined "bob@example.com" → key "bob"; participant "bob@example.com" → key "bob"
        let meeting = Meeting(
            title: "X",
            participants: "Alice, bob@example.com",
            declinedAttendees: "bob@example.com",
            createdAt: SampleData.fixedDate,
            updatedAt: SampleData.fixedDate
        )
        XCTAssertEqual(meeting.acceptedParticipantList, ["Alice"])
    }

    func testAcceptedParticipantListDisplayNameWithEmailSuffixExclusion() {
        // "Bob Smith <bob@example.com>" → angle-bracket strip → "Bob Smith" → key "bob smith"
        // declined "Bob Smith" → key "bob smith" — matches
        let meeting = Meeting(
            title: "X",
            participants: "Alice, Bob Smith <bob@example.com>",
            declinedAttendees: "Bob Smith",
            createdAt: SampleData.fixedDate,
            updatedAt: SampleData.fixedDate
        )
        XCTAssertEqual(meeting.acceptedParticipantList, ["Alice"])
    }

    func testAcceptedParticipantListSubstringNonMatch() {
        // "Samantha" declined must NOT exclude "Sam" — no substring containment
        let meeting = Meeting(
            title: "X",
            participants: "Sam, Samantha",
            declinedAttendees: "Samantha",
            createdAt: SampleData.fixedDate,
            updatedAt: SampleData.fixedDate
        )
        // "Sam" key = "sam", "Samantha" key = "samantha" — not equal, Sam stays
        XCTAssertEqual(meeting.acceptedParticipantList, ["Sam"])
    }

    func testAcceptedParticipantListAllDeclined() {
        let meeting = Meeting(
            title: "X",
            participants: "Alice, Bob",
            declinedAttendees: "Alice, Bob",
            createdAt: SampleData.fixedDate,
            updatedAt: SampleData.fixedDate
        )
        XCTAssertEqual(meeting.acceptedParticipantList, [])
    }

    // -------------------------------------------------------------------------
    // MARK: - Meeting.audioFilePath computed getter
    // -------------------------------------------------------------------------

    func testAudioFilePathNilWhenEmpty() {
        let meeting = SampleData.makeMeeting(audioFilePaths: [])
        XCTAssertNil(meeting.audioFilePath)
    }

    func testAudioFilePathReturnFirstElement() {
        let meeting = SampleData.makeMeeting(audioFilePaths: ["/a/b.m4a", "/c/d.m4a"])
        XCTAssertEqual(meeting.audioFilePath, "/a/b.m4a")
    }

    func testAudioFilePathSingleElement() {
        let meeting = SampleData.makeMeeting(audioFilePaths: ["/only.m4a"])
        XCTAssertEqual(meeting.audioFilePath, "/only.m4a")
    }

    // -------------------------------------------------------------------------
    // MARK: - Meeting.speakerMapDictionary
    // -------------------------------------------------------------------------

    func testSpeakerMapDictionaryNilReturnsEmpty() {
        let meeting = Meeting(title: "X", speakerMap: nil, createdAt: SampleData.fixedDate, updatedAt: SampleData.fixedDate)
        XCTAssertEqual(meeting.speakerMapDictionary, [:])
    }

    func testSpeakerMapDictionaryMalformedJSONReturnsEmpty() {
        let meeting = Meeting(title: "X", speakerMap: "NOT JSON {{{", createdAt: SampleData.fixedDate, updatedAt: SampleData.fixedDate)
        // POTENTIAL BUG: malformed JSON silently returns [:] via try? — callers
        // get no signal that the stored value was corrupt. Verified: this is
        // the intended fallback per the inline doc comment ("Returns an empty
        // dict when the column is NULL or contains non-JSON garbage").
        XCTAssertEqual(meeting.speakerMapDictionary, [:])
    }

    func testSpeakerMapDictionaryWrongTypeReturnsEmpty() {
        // JSON array instead of object — decode as [String:String] fails → [:]
        let meeting = Meeting(title: "X", speakerMap: #"["Speaker 1","Alice"]"#, createdAt: SampleData.fixedDate, updatedAt: SampleData.fixedDate)
        XCTAssertEqual(meeting.speakerMapDictionary, [:])
    }

    func testSpeakerMapDictionaryRoundTrip() {
        var meeting = Meeting(title: "X", createdAt: SampleData.fixedDate, updatedAt: SampleData.fixedDate)
        let map = ["Speaker 1": "Alice Chen", "Speaker 2": "Bob Kumar"]
        meeting.setSpeakerMap(map)
        XCTAssertEqual(meeting.speakerMapDictionary, map)
    }

    func testSpeakerMapDictionaryEmptyMapClearsToNil() {
        var meeting = Meeting(title: "X", speakerMap: #"{"Speaker 1":"Alice"}"#, createdAt: SampleData.fixedDate, updatedAt: SampleData.fixedDate)
        meeting.setSpeakerMap([:])
        XCTAssertNil(meeting.speakerMap)
        XCTAssertEqual(meeting.speakerMapDictionary, [:])
    }

    // -------------------------------------------------------------------------
    // MARK: - Meeting.speakerConfidenceMapDictionary
    // -------------------------------------------------------------------------

    func testSpeakerConfidenceMapDictionaryNilReturnsEmpty() {
        let meeting = Meeting(title: "X", speakerConfidenceMap: nil, createdAt: SampleData.fixedDate, updatedAt: SampleData.fixedDate)
        XCTAssertEqual(meeting.speakerConfidenceMapDictionary, [:])
    }

    func testSpeakerConfidenceMapDictionaryMalformedJSONReturnsEmpty() {
        let meeting = Meeting(title: "X", speakerConfidenceMap: "garbage", createdAt: SampleData.fixedDate, updatedAt: SampleData.fixedDate)
        XCTAssertEqual(meeting.speakerConfidenceMapDictionary, [:])
    }

    func testSpeakerConfidenceMapDictionaryRoundTrip() {
        var meeting = Meeting(title: "X", createdAt: SampleData.fixedDate, updatedAt: SampleData.fixedDate)
        let map: [String: Float] = ["Speaker 1": 0.92, "Speaker 2": 0.65]
        meeting.setSpeakerConfidenceMap(map)
        let decoded = meeting.speakerConfidenceMapDictionary
        XCTAssertEqual(decoded["Speaker 1"]!, 0.92, accuracy: 0.001)
        XCTAssertEqual(decoded["Speaker 2"]!, 0.65, accuracy: 0.001)
    }

    func testSpeakerConfidenceMapDictionaryEmptyMapClearsToNil() {
        var meeting = Meeting(title: "X", speakerConfidenceMap: #"{"S1":0.9}"#, createdAt: SampleData.fixedDate, updatedAt: SampleData.fixedDate)
        meeting.setSpeakerConfidenceMap([:])
        XCTAssertNil(meeting.speakerConfidenceMap)
    }

    // -------------------------------------------------------------------------
    // MARK: - Meeting.isReopenable
    // -------------------------------------------------------------------------
    // Condition (from source):
    //   !isAllDay
    //   && (status == .complete || status == .cancelled)
    //   For .cancelled with scheduled window: now in [start, end+3600]
    //   For .cancelled without scheduled window: now <= createdAt+7200
    //   For .complete with scheduled window: now in [start, end+3600]
    //   For .complete without scheduled window: now <= endDate+3600
    //   Otherwise: false

    func testIsReopenable_AllDayReturnsFalse() {
        let now = Date()
        let meeting = Meeting(
            title: "X",
            endDate: now.addingTimeInterval(3600),
            status: .complete,
            isAllDay: true,
            createdAt: now.addingTimeInterval(-60),
            updatedAt: now
        )
        XCTAssertFalse(meeting.isReopenable)
    }

    func testIsReopenable_ScheduledStatusReturnsFalse() {
        let now = Date()
        let meeting = Meeting(
            title: "X",
            startDate: now.addingTimeInterval(-60),
            endDate: now.addingTimeInterval(60),
            status: .scheduled,
            createdAt: now.addingTimeInterval(-120),
            updatedAt: now
        )
        XCTAssertFalse(meeting.isReopenable)
    }

    func testIsReopenable_CompleteWithScheduledWindowCurrentlyInWindow() {
        let now = Date()
        let meeting = Meeting(
            title: "X",
            scheduledStartDate: now.addingTimeInterval(-60),
            scheduledEndDate: now.addingTimeInterval(60),
            status: .complete,
            createdAt: now.addingTimeInterval(-120),
            updatedAt: now
        )
        XCTAssertTrue(meeting.isReopenable)
    }

    func testIsReopenable_CompleteWithScheduledWindowWithin60MinAfterEnd() {
        let now = Date()
        // end was 30 min ago → still within 60 min grace
        let meeting = Meeting(
            title: "X",
            scheduledStartDate: now.addingTimeInterval(-90 * 60),
            scheduledEndDate: now.addingTimeInterval(-30 * 60),
            status: .complete,
            createdAt: now.addingTimeInterval(-100 * 60),
            updatedAt: now
        )
        XCTAssertTrue(meeting.isReopenable)
    }

    func testIsReopenable_CompleteWithScheduledWindowExpired() {
        let now = Date()
        // end was 2 hours ago → beyond 60 min grace
        let meeting = Meeting(
            title: "X",
            scheduledStartDate: now.addingTimeInterval(-3 * 3600),
            scheduledEndDate: now.addingTimeInterval(-2 * 3600),
            status: .complete,
            createdAt: now.addingTimeInterval(-4 * 3600),
            updatedAt: now
        )
        XCTAssertFalse(meeting.isReopenable)
    }

    func testIsReopenable_CompleteNoScheduleWithinEndPlusHour() {
        let now = Date()
        // No scheduledStart/End; endDate was 30 min ago
        let meeting = Meeting(
            title: "X",
            startDate: now.addingTimeInterval(-60 * 60),
            endDate: now.addingTimeInterval(-30 * 60),
            status: .complete,
            createdAt: now.addingTimeInterval(-70 * 60),
            updatedAt: now
        )
        XCTAssertTrue(meeting.isReopenable)
    }

    func testIsReopenable_CompleteNoScheduleNoEndDateReturnsFalse() {
        let now = Date()
        let meeting = Meeting(
            title: "X",
            startDate: now.addingTimeInterval(-60),
            endDate: nil,
            scheduledStartDate: nil,
            scheduledEndDate: nil,
            status: .complete,
            createdAt: now.addingTimeInterval(-120),
            updatedAt: now
        )
        XCTAssertFalse(meeting.isReopenable)
    }

    func testIsReopenable_CancelledWithScheduledWindowActive() {
        let now = Date()
        let meeting = Meeting(
            title: "X",
            scheduledStartDate: now.addingTimeInterval(-10 * 60),
            scheduledEndDate: now.addingTimeInterval(50 * 60),
            status: .cancelled,
            createdAt: now.addingTimeInterval(-15 * 60),
            updatedAt: now
        )
        XCTAssertTrue(meeting.isReopenable)
    }

    func testIsReopenable_CancelledWithNoScheduleWithinTwoHoursOfCreation() {
        let now = Date()
        // No schedule; created 30 min ago → within 2h grace
        let meeting = Meeting(
            title: "X",
            scheduledStartDate: nil,
            scheduledEndDate: nil,
            status: .cancelled,
            createdAt: now.addingTimeInterval(-30 * 60),
            updatedAt: now
        )
        XCTAssertTrue(meeting.isReopenable)
    }

    func testIsReopenable_CancelledWithNoScheduleExpired() {
        let now = Date()
        // Created 3 hours ago → beyond 2h grace
        let meeting = Meeting(
            title: "X",
            scheduledStartDate: nil,
            scheduledEndDate: nil,
            status: .cancelled,
            createdAt: now.addingTimeInterval(-3 * 3600),
            updatedAt: now
        )
        XCTAssertFalse(meeting.isReopenable)
    }

    // -------------------------------------------------------------------------
    // MARK: - Meeting Codable round-trip with JSON-backed and optional fields
    // -------------------------------------------------------------------------

    func testMeetingCodableRoundTripWithAllFields() throws {
        let base = SampleData.fixedDate
        var meeting = Meeting(
            id: "full-roundtrip",
            title: "All Fields Meeting",
            startDate: base,
            endDate: base.addingTimeInterval(3600),
            scheduledStartDate: base.addingTimeInterval(-300),
            scheduledEndDate: base.addingTimeInterval(3900),
            status: .complete,
            calendarEventId: "cal-abc",
            audioFilePaths: ["/a.m4a", "/b.m4a"],
            isAllDay: false,
            participants: "Alice, Bob",
            contextJSON: #"{"related":[]}"#,
            meetLink: "https://meet.google.com/xyz",
            templateId: "tmpl-1",
            speakerMap: nil,
            declinedAttendees: "Charlie",
            speakerConfidenceMap: nil,
            transcriptionAttemptedAt: base.addingTimeInterval(4000),
            createdAt: base,
            updatedAt: base
        )
        meeting.setSpeakerMap(["Speaker 1": "Alice"])
        meeting.setSpeakerConfidenceMap(["Speaker 1": 0.88])

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSinceReferenceDate
        let data = try encoder.encode(meeting)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSinceReferenceDate
        let decoded = try decoder.decode(Meeting.self, from: data)

        XCTAssertEqual(meeting, decoded)
    }

    func testMeetingCodableRoundTripNilOptionals() throws {
        let base = SampleData.fixedDate
        let meeting = Meeting(
            id: "nil-optionals",
            title: "Nil Optionals",
            startDate: nil,
            endDate: nil,
            scheduledStartDate: nil,
            scheduledEndDate: nil,
            status: .scheduled,
            calendarEventId: nil,
            audioFilePaths: [],
            isAllDay: false,
            participants: nil,
            contextJSON: nil,
            meetLink: nil,
            templateId: nil,
            speakerMap: nil,
            declinedAttendees: nil,
            speakerConfidenceMap: nil,
            transcriptionAttemptedAt: nil,
            createdAt: base,
            updatedAt: base
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSinceReferenceDate
        let data = try encoder.encode(meeting)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSinceReferenceDate
        let decoded = try decoder.decode(Meeting.self, from: data)

        XCTAssertEqual(meeting, decoded)
        XCTAssertNil(decoded.audioFilePath)
        XCTAssertEqual(decoded.participantList, [])
        XCTAssertEqual(decoded.speakerMapDictionary, [:])
    }

    // -------------------------------------------------------------------------
    // MARK: - Transcript Codable round-trip with nil optionals
    // -------------------------------------------------------------------------

    func testTranscriptCodableRoundTripNilOptionals() throws {
        let transcript = Transcript(
            id: nil,
            meetingId: "m-1",
            speakerLabel: nil,
            text: "Some text",
            startTime: 10.0,
            endTime: 12.5,
            confidence: nil,
            createdAt: SampleData.fixedDate
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSinceReferenceDate
        let data = try encoder.encode(transcript)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSinceReferenceDate
        let decoded = try decoder.decode(Transcript.self, from: data)

        XCTAssertEqual(transcript, decoded)
        XCTAssertNil(decoded.id)
        XCTAssertNil(decoded.speakerLabel)
        XCTAssertNil(decoded.confidence)
    }

    // -------------------------------------------------------------------------
    // MARK: - ActionItem Codable round-trip with nil optionals
    // -------------------------------------------------------------------------

    func testActionItemCodableRoundTripAllNilOptionals() throws {
        let item = ActionItem(
            id: nil,
            meetingId: "m-1",
            title: "Task",
            assignee: nil,
            dueDate: nil,
            isCompleted: false,
            extractedAt: SampleData.fixedDate
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSinceReferenceDate
        let data = try encoder.encode(item)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSinceReferenceDate
        let decoded = try decoder.decode(ActionItem.self, from: data)

        XCTAssertEqual(item, decoded)
        XCTAssertNil(decoded.id)
        XCTAssertNil(decoded.assignee)
        XCTAssertNil(decoded.dueDate)
    }

    // -------------------------------------------------------------------------
    // MARK: - Recipe Codable round-trip (all categories)
    // -------------------------------------------------------------------------

    func testRecipeCodableRoundTripAllCategories() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSinceReferenceDate
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSinceReferenceDate

        for category in RecipeCategory.allCases {
            let original = Recipe(
                id: "r-\(category.rawValue)",
                name: "Recipe \(category.rawValue)",
                description: "Desc",
                promptTemplate: "Template {{transcript}}",
                category: category,
                isBuiltIn: category == .summary,
                createdAt: SampleData.fixedDate
            )
            let data = try encoder.encode(original)
            let decoded = try decoder.decode(Recipe.self, from: data)
            XCTAssertEqual(original, decoded, "Round-trip failed for category \(category)")
        }
    }

    // -------------------------------------------------------------------------
    // MARK: - AppSettings defaults
    // -------------------------------------------------------------------------
    // Existing tests cover whisperModel, claudeModel, calendarSyncIntervalMinutes,
    // notificationLeadTimeMinutes, launchAtLogin, theme, id.
    // Gaps: newer fields added in later migrations that have default values in Swift.

    func testDefaultAiEnabledFalse() {
        XCTAssertFalse(AppSettings.default.aiEnabled)
    }

    func testDefaultAutoRecordFalse() {
        XCTAssertFalse(AppSettings.default.autoRecord)
    }

    func testDefaultAutoInviteTrue() {
        XCTAssertTrue(AppSettings.default.autoInvite)
    }

    func testDefaultUseLocalLLMFalse() {
        XCTAssertFalse(AppSettings.default.useLocalLLM)
    }

    func testDefaultOllamaModelIsAuto() {
        XCTAssertEqual(AppSettings.default.ollamaModel, "auto")
    }

    func testDefaultAutoGenerateSummaryFalse() {
        XCTAssertFalse(AppSettings.default.autoGenerateSummary)
    }

    func testDefaultAutoFollowUpEmailFalse() {
        XCTAssertFalse(AppSettings.default.autoFollowUpEmail)
    }

    func testDefaultMorningBriefEnabledFalse() {
        XCTAssertFalse(AppSettings.default.morningBriefEnabled)
    }

    func testDefaultMorningBriefHour() {
        XCTAssertEqual(AppSettings.default.morningBriefHour, 8)
    }

    func testDefaultMorningBriefMinute() {
        XCTAssertEqual(AppSettings.default.morningBriefMinute, 30)
    }

    func testDefaultKbWriteBackFalse() {
        XCTAssertFalse(AppSettings.default.kbWriteBack)
    }

    func testDefaultContactsImportEnabledFalse() {
        XCTAssertFalse(AppSettings.default.contactsImportEnabled)
    }

    func testDefaultApolloProfilePrepEnabledFalse() {
        XCTAssertFalse(AppSettings.default.apolloProfilePrepEnabled)
    }

    func testDefaultApolloKeyValidatedFalse() {
        XCTAssertFalse(AppSettings.default.apolloKeyValidated)
    }

    func testDefaultSelectedCalendarIdNil() {
        XCTAssertNil(AppSettings.default.selectedCalendarId)
    }

    func testDefaultSelectedGoogleCalendarIdsNil() {
        XCTAssertNil(AppSettings.default.selectedGoogleCalendarIds)
    }

    func testDefaultDetailedOutlinePromptTemplateNil() {
        XCTAssertNil(AppSettings.default.detailedOutlinePromptTemplate)
    }

    func testDefaultDefaultRecipeIdNil() {
        XCTAssertNil(AppSettings.default.defaultRecipeId)
    }

    // -------------------------------------------------------------------------
    // MARK: - AppSettings forward/backward-compat decoding
    // -------------------------------------------------------------------------
    // A stored JSON that lacks newer keys must still decode successfully and
    // fall back to the property-level defaults. This is critical for a shipped
    // app where old settings rows lack new columns.

    func testAppSettingsDecodesFromMinimalJSON() throws {
        // Only the fields that were in the initial schema. All newer fields must
        // decode to their Swift default values.
        let minimalDict: [String: Any] = [
            "id": 1,
            "whisperModel": "large-v3-turbo",
            "summaryPromptTemplate": "Summarize this",
            "claudeModel": "claude-sonnet-4-20250514",
            "calendarSyncIntervalMinutes": 15,
            "notificationLeadTimeMinutes": 5,
            "launchAtLogin": false,
            "theme": "dark"
        ]
        let data = try jsonData(minimalDict)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(decoded.whisperModel, "large-v3-turbo")
        XCTAssertFalse(decoded.aiEnabled)
        XCTAssertFalse(decoded.autoRecord)
        XCTAssertTrue(decoded.autoInvite)
        XCTAssertFalse(decoded.useLocalLLM)
        XCTAssertEqual(decoded.ollamaModel, "auto")
        XCTAssertFalse(decoded.autoGenerateSummary)
        XCTAssertNil(decoded.defaultRecipeId)
        XCTAssertFalse(decoded.morningBriefEnabled)
        XCTAssertEqual(decoded.morningBriefHour, 8)
        XCTAssertEqual(decoded.morningBriefMinute, 30)
        XCTAssertFalse(decoded.kbWriteBack)
        XCTAssertFalse(decoded.contactsImportEnabled)
        XCTAssertNil(decoded.detailedOutlinePromptTemplate)
        XCTAssertFalse(decoded.apolloProfilePrepEnabled)
        XCTAssertFalse(decoded.apolloKeyValidated)
        XCTAssertNil(decoded.apolloKeyLastValidatedAt)
    }

    func testAppSettingsDecodesWithOnlySomeNewerKeys() throws {
        // Simulates a mid-upgrade settings row that has some newer keys but not all.
        let partialDict: [String: Any] = [
            "id": 1,
            "whisperModel": "large-v3-turbo",
            "summaryPromptTemplate": "Summarize",
            "claudeModel": "claude-sonnet-4-20250514",
            "calendarSyncIntervalMinutes": 15,
            "notificationLeadTimeMinutes": 5,
            "launchAtLogin": true,
            "theme": "light",
            "aiEnabled": true,
            "useLocalLLM": true,
            "ollamaModel": "llama3.2:3b"
            // morningBrief*, kbWriteBack, contactsImport, apollo* absent
        ]
        let data = try jsonData(partialDict)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertTrue(decoded.aiEnabled)
        XCTAssertTrue(decoded.useLocalLLM)
        XCTAssertEqual(decoded.ollamaModel, "llama3.2:3b")
        // absent keys fall back to defaults
        XCTAssertFalse(decoded.morningBriefEnabled)
        XCTAssertEqual(decoded.morningBriefHour, 8)
        XCTAssertFalse(decoded.kbWriteBack)
        XCTAssertFalse(decoded.apolloProfilePrepEnabled)
    }

    func testAppSettingsCodableRoundTripWithAllFieldsPopulated() throws {
        var settings = AppSettings.default
        settings.aiEnabled = true
        settings.autoRecord = true
        settings.autoInvite = false
        settings.selectedCalendarId = "primary"
        settings.selectedGoogleCalendarIds = "cal1,cal2"
        settings.selectedAppleCalendarIds = "uuid-1,uuid-2"
        settings.useLocalLLM = true
        settings.ollamaModel = "llama3.2:3b"
        settings.autoGenerateSummary = true
        settings.defaultRecipeId = "recipe-abc"
        settings.autoFollowUpEmail = true
        settings.morningBriefEnabled = true
        settings.morningBriefHour = 7
        settings.morningBriefMinute = 0
        settings.kbWriteBack = true
        settings.contactsImportEnabled = true
        settings.detailedOutlinePromptTemplate = "Custom outline prompt"
        settings.apolloProfilePrepEnabled = true
        settings.apolloKeyValidated = true
        settings.apolloKeyLastValidatedAt = SampleData.fixedDate

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSinceReferenceDate
        let data = try encoder.encode(settings)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSinceReferenceDate
        let decoded = try decoder.decode(AppSettings.self, from: data)

        XCTAssertEqual(settings, decoded)
    }

    // -------------------------------------------------------------------------
    // MARK: - MeetingStatus rawValue stability (persisted in DB)
    // -------------------------------------------------------------------------
    // Existing tests already verify rawValues match the string literals.
    // Add a round-trip via rawValue init to confirm no silent renames.

    func testMeetingStatusRoundTripViaRawValue() {
        for status in MeetingStatus.allCases {
            let reconstructed = MeetingStatus(rawValue: status.rawValue)
            XCTAssertEqual(reconstructed, status,
                "MeetingStatus rawValue '\(status.rawValue)' failed round-trip — DB records would silently break")
        }
    }

    func testMeetingStatusUnknownRawValueReturnsNil() {
        // If a new value is added to the DB before this version of the app ships
        // the enum, Codable decoding must fail gracefully rather than crashing.
        XCTAssertNil(MeetingStatus(rawValue: "processing"))
        XCTAssertNil(MeetingStatus(rawValue: ""))
        XCTAssertNil(MeetingStatus(rawValue: "COMPLETE")) // case-sensitive
    }
}

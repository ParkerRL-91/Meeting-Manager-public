import XCTest
@testable import MeetingManager

final class TranscriptCleanupTests: XCTestCase {

    // MARK: - Helpers

    /// Convenience wrapper so tests read clearly without boilerplate.
    private func makeTranscript(
        speaker: String?,
        text: String,
        startTime: Double,
        endTime: Double
    ) -> Transcript {
        SampleData.makeTranscript(
            speakerLabel: speaker,
            text: text,
            startTime: startTime,
            endTime: endTime
        )
    }

    // MARK: - stitch: empty input

    func testStitch_emptyInput_returnsEmpty() {
        let result = TranscriptCleanupService.stitch([])
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - stitch: single segment

    func testStitch_singleSegment_returnsSingleTurn() {
        let t = makeTranscript(speaker: "Alice", text: "Hello world", startTime: 0, endTime: 5)
        let result = TranscriptCleanupService.stitch([t])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].speaker, "Alice")
        XCTAssertEqual(result[0].text, "Hello world")
        XCTAssertEqual(result[0].startTime, 0)
        XCTAssertEqual(result[0].endTime, 5)
    }

    // MARK: - stitch: nil/blank speaker fallback to "Unknown"

    func testStitch_nilSpeaker_fallsBackToUnknown() {
        let t = makeTranscript(speaker: nil, text: "Anybody there?", startTime: 0, endTime: 3)
        let result = TranscriptCleanupService.stitch([t])
        XCTAssertEqual(result[0].speaker, "Unknown")
    }

    func testStitch_blankSpeaker_fallsBackToUnknown() {
        let t = makeTranscript(speaker: "   ", text: "Testing", startTime: 0, endTime: 2)
        let result = TranscriptCleanupService.stitch([t])
        XCTAssertEqual(result[0].speaker, "Unknown")
    }

    // MARK: - stitch: adjacent same-speaker merge within gap

    func testStitch_adjacentSameSpeakerWithinGap_mergesIntoOneTurn() {
        // Gap = 1.0s, well within 1.5s threshold.
        let t1 = makeTranscript(speaker: "Bob", text: "Good morning", startTime: 0, endTime: 3)
        let t2 = makeTranscript(speaker: "Bob", text: "everyone", startTime: 4, endTime: 6)
        let result = TranscriptCleanupService.stitch([t1, t2])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].text, "Good morning everyone")
        XCTAssertEqual(result[0].startTime, 0)
        XCTAssertEqual(result[0].endTime, 6)
    }

    func testStitch_adjacentSameSpeakerAtExactGap_merges() {
        // Gap = exactly 1.5s — the condition is `<=` so this must merge.
        let t1 = makeTranscript(speaker: "Bob", text: "One", startTime: 0, endTime: 2.0)
        let t2 = makeTranscript(speaker: "Bob", text: "Two", startTime: 3.5, endTime: 5)
        let result = TranscriptCleanupService.stitch([t1, t2])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].text, "One Two")
    }

    func testStitch_adjacentSameSpeakerGapExceedsThreshold_splitsIntoTwoTurns() {
        // Gap = 2.0s, just over 1.5s — must NOT merge.
        let t1 = makeTranscript(speaker: "Alice", text: "First sentence", startTime: 0, endTime: 3.0)
        let t2 = makeTranscript(speaker: "Alice", text: "Second sentence", startTime: 5.0, endTime: 8.0)
        let result = TranscriptCleanupService.stitch([t1, t2])
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].text, "First sentence")
        XCTAssertEqual(result[1].text, "Second sentence")
    }

    // MARK: - stitch: different speakers never merge

    func testStitch_differentSpeakers_neverMerge() {
        let t1 = makeTranscript(speaker: "Alice", text: "Hello", startTime: 0, endTime: 2)
        let t2 = makeTranscript(speaker: "Bob", text: "Hi there", startTime: 2.5, endTime: 5)
        let result = TranscriptCleanupService.stitch([t1, t2])
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].speaker, "Alice")
        XCTAssertEqual(result[1].speaker, "Bob")
    }

    // MARK: - stitch: skips empty-text segments

    func testStitch_emptyTextSegments_areSkipped() {
        let t1 = makeTranscript(speaker: "Alice", text: "Hello", startTime: 0, endTime: 2)
        let t2 = makeTranscript(speaker: "Alice", text: "   ", startTime: 2.5, endTime: 3)
        let t3 = makeTranscript(speaker: "Alice", text: "World", startTime: 3.5, endTime: 5)
        let result = TranscriptCleanupService.stitch([t1, t2, t3])
        // t2 is whitespace-only so trimmed to empty and skipped.
        // t1 and t3 gap: 3.5 - 2 = 1.5, which is <= 1.5 — they merge.
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].text, "Hello World")
    }

    func testStitch_allEmptySegments_returnsEmpty() {
        let t1 = makeTranscript(speaker: "Alice", text: "", startTime: 0, endTime: 1)
        let t2 = makeTranscript(speaker: "Bob", text: "  ", startTime: 2, endTime: 3)
        let result = TranscriptCleanupService.stitch([t1, t2])
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - stitch: char cap splits even same-speaker close segments

    func testStitch_charCapExceeded_splitsIntoNewTurn() {
        // Build two segments whose combined text+space would exceed 600 chars.
        let longText1 = String(repeating: "a", count: 550)
        let longText2 = String(repeating: "b", count: 60) // 550 + 1 + 60 = 611 > 600
        let t1 = makeTranscript(speaker: "Alice", text: longText1, startTime: 0, endTime: 5)
        let t2 = makeTranscript(speaker: "Alice", text: longText2, startTime: 5.5, endTime: 10)
        // gap = 0.5 <= 1.5, but char count exceeded — must NOT merge
        let result = TranscriptCleanupService.stitch([t1, t2])
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].text, longText1)
        XCTAssertEqual(result[1].text, longText2)
    }

    func testStitch_charCapJustUnder_merges() {
        // 550 + 1 + 49 = 600 exactly — should merge (condition is `<=`).
        let longText1 = String(repeating: "a", count: 550)
        let longText2 = String(repeating: "b", count: 49)
        let t1 = makeTranscript(speaker: "Alice", text: longText1, startTime: 0, endTime: 5)
        let t2 = makeTranscript(speaker: "Alice", text: longText2, startTime: 5.5, endTime: 10)
        let result = TranscriptCleanupService.stitch([t1, t2])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].text, longText1 + " " + longText2)
    }

    // MARK: - stitch: ordering preserved (inputs are iterated in array order)

    func testStitch_multiSpeakerAlternating_preservesOrder() {
        let t1 = makeTranscript(speaker: "Alice", text: "First", startTime: 0, endTime: 2)
        let t2 = makeTranscript(speaker: "Bob", text: "Second", startTime: 3, endTime: 5)
        let t3 = makeTranscript(speaker: "Alice", text: "Third", startTime: 6, endTime: 8)
        let t4 = makeTranscript(speaker: "Bob", text: "Fourth", startTime: 9, endTime: 11)
        let result = TranscriptCleanupService.stitch([t1, t2, t3, t4])
        XCTAssertEqual(result.count, 4)
        XCTAssertEqual(result.map(\.speaker), ["Alice", "Bob", "Alice", "Bob"])
        XCTAssertEqual(result.map(\.text), ["First", "Second", "Third", "Fourth"])
    }

    func testStitch_manySegmentsSameSpeakerCloseTogether_mergesAll() {
        // 5 segments, all within gap and well under char cap.
        let segments = (0..<5).map { i in
            makeTranscript(speaker: "Carol", text: "word\(i)", startTime: Double(i * 2), endTime: Double(i * 2 + 1))
        }
        let result = TranscriptCleanupService.stitch(segments)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].text, "word0 word1 word2 word3 word4")
        XCTAssertEqual(result[0].startTime, 0)
        XCTAssertEqual(result[0].endTime, 9)
    }

    // MARK: - stitch: unicode in text

    func testStitch_unicodeTextPreserved() {
        let t = makeTranscript(speaker: "Anya", text: "Привет мир 🌍", startTime: 0, endTime: 3)
        let result = TranscriptCleanupService.stitch([t])
        XCTAssertEqual(result[0].text, "Привет мир 🌍")
        XCTAssertEqual(result[0].speaker, "Anya")
    }

    // MARK: - renderMarkdown: format contract

    func testRenderMarkdown_emptyInput_returnsEmptyString() {
        let result = TranscriptCleanupService.renderMarkdown([])
        XCTAssertEqual(result, "")
    }

    func testRenderMarkdown_singleTurn_exactFormat() {
        let turn = TranscriptCleanupService.StitchedTurn(
            speaker: "Alice",
            text: "Hello world",
            startTime: 0,
            endTime: 5
        )
        let result = TranscriptCleanupService.renderMarkdown([turn])
        XCTAssertEqual(result, "**Alice** _[0:00]_\n\nHello world")
    }

    func testRenderMarkdown_timestampZero_formatsAs0Colon00() {
        let turn = TranscriptCleanupService.StitchedTurn(
            speaker: "X",
            text: "body",
            startTime: 0,
            endTime: 1
        )
        let md = TranscriptCleanupService.renderMarkdown([turn])
        XCTAssertTrue(md.hasPrefix("**X** _[0:00]_"), "0s should render as 0:00, got: \(md)")
    }

    func testRenderMarkdown_timestamp72Seconds_formatsAs1Colon12() {
        let turn = TranscriptCleanupService.StitchedTurn(
            speaker: "Bob",
            text: "body",
            startTime: 72,
            endTime: 75
        )
        let md = TranscriptCleanupService.renderMarkdown([turn])
        XCTAssertTrue(md.hasPrefix("**Bob** _[1:12]_"), "72s should render as 1:12, got: \(md)")
    }

    func testRenderMarkdown_timestamp59Seconds_formatsAs0Colon59() {
        let turn = TranscriptCleanupService.StitchedTurn(
            speaker: "Bob",
            text: "body",
            startTime: 59,
            endTime: 62
        )
        let md = TranscriptCleanupService.renderMarkdown([turn])
        XCTAssertTrue(md.hasPrefix("**Bob** _[0:59]_"), "59s should render as 0:59, got: \(md)")
    }

    func testRenderMarkdown_timestamp3600Seconds_includesHour() {
        // 3600s = 1:00:00
        let turn = TranscriptCleanupService.StitchedTurn(
            speaker: "Alice",
            text: "One hour mark",
            startTime: 3600,
            endTime: 3605
        )
        let md = TranscriptCleanupService.renderMarkdown([turn])
        XCTAssertTrue(md.hasPrefix("**Alice** _[1:00:00]_"), "3600s should render as 1:00:00, got: \(md)")
    }

    func testRenderMarkdown_timestamp3723Seconds_formatsAs1Colon02Colon03() {
        // 3723s = 1h 2m 3s → 1:02:03
        let turn = TranscriptCleanupService.StitchedTurn(
            speaker: "Dave",
            text: "Late in the meeting",
            startTime: 3723,
            endTime: 3730
        )
        let md = TranscriptCleanupService.renderMarkdown([turn])
        XCTAssertTrue(md.hasPrefix("**Dave** _[1:02:03]_"), "3723s should render as 1:02:03, got: \(md)")
    }

    func testRenderMarkdown_twoTurns_separatedByDoubleNewline() {
        let turns = [
            TranscriptCleanupService.StitchedTurn(speaker: "Alice", text: "First", startTime: 0, endTime: 5),
            TranscriptCleanupService.StitchedTurn(speaker: "Bob", text: "Second", startTime: 6, endTime: 10),
        ]
        let md = TranscriptCleanupService.renderMarkdown(turns)
        let expected = "**Alice** _[0:00]_\n\nFirst\n\n**Bob** _[0:06]_\n\nSecond"
        XCTAssertEqual(md, expected)
    }

    func testRenderMarkdown_bodyAppearsAfterHeader() {
        let turn = TranscriptCleanupService.StitchedTurn(
            speaker: "Eve",
            text: "This is the body text",
            startTime: 10,
            endTime: 15
        )
        let md = TranscriptCleanupService.renderMarkdown([turn])
        // Header line, blank line, then body
        let lines = md.components(separatedBy: "\n")
        XCTAssertTrue(lines[0].hasPrefix("**Eve**"), "First line should be the speaker header")
        XCTAssertEqual(lines[1], "", "Second line (after \\n) should be blank")
        XCTAssertTrue(lines[2].contains("This is the body text"), "Third line should be body")
    }

    // MARK: - renderMarkdown: speaker names never leaking or mangled

    func testRenderMarkdown_unicodeSpeakerName_preservedExactly() {
        let turn = TranscriptCleanupService.StitchedTurn(
            speaker: "日本語名",
            text: "テスト",
            startTime: 5,
            endTime: 10
        )
        let md = TranscriptCleanupService.renderMarkdown([turn])
        XCTAssertTrue(md.hasPrefix("**日本語名**"), "Unicode speaker name must be preserved verbatim")
    }

    // MARK: - parseTurnBodies: correct count

    func testParseTurnBodies_exactCount_returnsBodiesInOrder() {
        let raw = """
        [TURN 1]
        First cleaned body

        [TURN 2]
        Second cleaned body

        [TURN 3]
        Third cleaned body
        """
        let result = TranscriptCleanupService.parseTurnBodies(raw, expectedCount: 3)
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0], "First cleaned body")
        XCTAssertEqual(result[1], "Second cleaned body")
        XCTAssertEqual(result[2], "Third cleaned body")
    }

    func testParseTurnBodies_singleTurn_returnsSingleBody() {
        let raw = "[TURN 1]\nOnly one turn here."
        let result = TranscriptCleanupService.parseTurnBodies(raw, expectedCount: 1)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0], "Only one turn here.")
    }

    // MARK: - parseTurnBodies: count mismatch triggers fall-back signal

    func testParseTurnBodies_modelDroppedABlock_countMismatch_callerShouldFallBack() {
        // Model returns 2 blocks but we expected 3. The function returns
        // whatever array it parsed — the CALLER detects .count != expectedCount
        // and falls back. This test confirms the returned count differs from
        // expectedCount so the fallback guard fires.
        let raw = """
        [TURN 1]
        Body one

        [TURN 2]
        Body two
        """
        let result = TranscriptCleanupService.parseTurnBodies(raw, expectedCount: 3)
        XCTAssertNotEqual(result.count, 3, "Mismatched count must not equal expectedCount — caller uses this to detect fallback")
        XCTAssertEqual(result.count, 2)
    }

    func testParseTurnBodies_modelAddedExtraBlock_countMismatch_callerShouldFallBack() {
        let raw = """
        [TURN 1]
        Body one

        [TURN 2]
        Body two

        [TURN 3]
        Body three
        """
        let result = TranscriptCleanupService.parseTurnBodies(raw, expectedCount: 2)
        XCTAssertNotEqual(result.count, 2, "Extra block must not equal expectedCount")
        XCTAssertEqual(result.count, 3)
    }

    // MARK: - parseTurnBodies: empty / no markers

    func testParseTurnBodies_noMarkers_returnsEmpty() {
        let raw = "This text has no TURN markers at all."
        let result = TranscriptCleanupService.parseTurnBodies(raw, expectedCount: 2)
        XCTAssertEqual(result.count, 0, "No markers → empty array signals fallback")
    }

    func testParseTurnBodies_emptyString_returnsEmpty() {
        let result = TranscriptCleanupService.parseTurnBodies("", expectedCount: 1)
        XCTAssertEqual(result.count, 0)
    }

    func testParseTurnBodies_emptyBody_returnsEmptyStringForThatSlot() {
        // A valid marker but no body text between it and the next marker.
        let raw = """
        [TURN 1]

        [TURN 2]
        Some content
        """
        let result = TranscriptCleanupService.parseTurnBodies(raw, expectedCount: 2)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0], "", "Empty body between markers should be an empty string after trimming")
        XCTAssertEqual(result[1], "Some content")
    }

    // MARK: - parseTurnBodies: tolerant of formatting variants

    func testParseTurnBodies_extraWhitespaceAroundMarker_stillParsed() {
        // The regex accepts leading/trailing whitespace on the marker line.
        let raw = """
           [TURN 1]
        Body with leading spaces on marker

           [TURN 2]
        Second body
        """
        let result = TranscriptCleanupService.parseTurnBodies(raw, expectedCount: 2)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0], "Body with leading spaces on marker")
        XCTAssertEqual(result[1], "Second body")
    }

    func testParseTurnBodies_alternateMarkerFormat_TurnNColon_accepted() {
        // The regex also accepts `Turn N:` (no brackets, trailing colon).
        let raw = """
        Turn 1:
        First body

        Turn 2:
        Second body
        """
        let result = TranscriptCleanupService.parseTurnBodies(raw, expectedCount: 2)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0], "First body")
        XCTAssertEqual(result[1], "Second body")
    }

    func testParseTurnBodies_alternateMarkerFormat_TurnNPlain_accepted() {
        // The regex accepts `Turn N` (no brackets, no colon).
        let raw = """
        Turn 1
        First body text

        Turn 2
        Second body text
        """
        let result = TranscriptCleanupService.parseTurnBodies(raw, expectedCount: 2)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0], "First body text")
        XCTAssertEqual(result[1], "Second body text")
    }

    // MARK: - parseTurnBodies: out-of-order markers are sorted by number

    func testParseTurnBodies_outOfOrderMarkers_returnedSortedByNumber() {
        // The implementation sorts `ordered` by idx (the parsed turn number).
        let raw = """
        [TURN 2]
        Second body

        [TURN 1]
        First body
        """
        let result = TranscriptCleanupService.parseTurnBodies(raw, expectedCount: 2)
        XCTAssertEqual(result.count, 2)
        // After sorting by turn number, [0] should be TURN 1's body.
        XCTAssertEqual(result[0], "First body")
        XCTAssertEqual(result[1], "Second body")
    }

    // MARK: - parseTurnBodies: adversarial — body containing [TURN N] text

    func testParseTurnBodies_bodyContainsTurnMarkerText_treatedAsMarker() {
        // ADR-005 POTENTIAL BUG: if a turn body contains text like "[TURN 2]"
        // on its own line, parseTurnBodies will treat it as a real marker.
        // This would produce an extra block, causing a count mismatch and
        // a fallback — which is safe behaviour (fallback, not wrong output),
        // but the cleaned body is lost. Documenting here for awareness.
        //
        // The regex is line-anchored ((?m)^) and requires the marker text to
        // stand alone on a line, so this only fires if the model writes
        // "[TURN 2]" on its own line inside a body. Verify fallback fires.
        let raw = """
        [TURN 1]
        Some body text that mentions [TURN 2] in prose and
        keeps going here

        [TURN 2]
        Real second body
        """
        // The inline "[TURN 2]" in TURN 1's body is NOT on its own line, so
        // the regex should NOT match it. Count should remain correct.
        let result = TranscriptCleanupService.parseTurnBodies(raw, expectedCount: 2)
        XCTAssertEqual(result.count, 2, "Inline [TURN N] mid-sentence should not split the block")
    }

    func testParseTurnBodies_bodyContainsTurnMarkerOnOwnLine_causesExtraBlock() {
        // POTENTIAL BUG: if the model places [TURN 2] alone on a line inside
        // a body, it will be treated as a real marker. The count mismatch
        // triggers the fallback (safe), but demonstrates the attack surface.
        let raw = """
        [TURN 1]
        Here the model wrote:
        [TURN 2]
        which started a phantom block

        [TURN 2]
        Real second body
        """
        let result = TranscriptCleanupService.parseTurnBodies(raw, expectedCount: 2)
        // We get 3 parsed blocks (the phantom + the real TURN 2 twice).
        // The caller detects count(3) != expectedCount(2) and falls back.
        XCTAssertNotEqual(result.count, 2, "Phantom marker on its own line causes extra block — caller must fall back")
    }

    // MARK: - parseTurnBodies: unicode in body

    func testParseTurnBodies_unicodeBodyPreserved() {
        let raw = """
        [TURN 1]
        مرحبا بالعالم 🌍

        [TURN 2]
        Ñoño y más ñoño
        """
        let result = TranscriptCleanupService.parseTurnBodies(raw, expectedCount: 2)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0], "مرحبا بالعالم 🌍")
        XCTAssertEqual(result[1], "Ñoño y más ñoño")
    }

    // MARK: - parseTurnBodies: multi-line body preserved

    func testParseTurnBodies_multilineBody_preservedAsOneTrimmedString() {
        let raw = """
        [TURN 1]
        Line one of the body.
        Line two of the body.

        [TURN 2]
        Only one line here.
        """
        let result = TranscriptCleanupService.parseTurnBodies(raw, expectedCount: 2)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0], "Line one of the body.\nLine two of the body.")
        XCTAssertEqual(result[1], "Only one line here.")
    }

    // MARK: - Round-trip: renderMarkdown(stitch(x)) preserves speaker labels and bodies

    func testRoundTrip_speakerLabelsPreservedAndNotLeakedOrLost() {
        let transcripts = [
            makeTranscript(speaker: "Alice", text: "Let us start the meeting.", startTime: 0, endTime: 5),
            makeTranscript(speaker: "Bob", text: "Agreed.", startTime: 6, endTime: 8),
            makeTranscript(speaker: "Alice", text: "I have three items.", startTime: 10, endTime: 14),
        ]
        let turns = TranscriptCleanupService.stitch(transcripts)
        let md = TranscriptCleanupService.renderMarkdown(turns)

        // Speaker names appear in Markdown headers — exactly as input.
        XCTAssertTrue(md.contains("**Alice**"), "Alice must appear as a Markdown bold header")
        XCTAssertTrue(md.contains("**Bob**"), "Bob must appear as a Markdown bold header")

        // Bodies present.
        XCTAssertTrue(md.contains("Let us start the meeting."))
        XCTAssertTrue(md.contains("Agreed."))
        XCTAssertTrue(md.contains("I have three items."))

        // No name appears in a body position (not proof-of-absence, but a
        // sanity check that the literal text "**Alice**" appears only in
        // headers, not anywhere else unexpected).
        let headerCount = md.components(separatedBy: "**Alice**").count - 1
        XCTAssertEqual(headerCount, 2, "Alice appears in 2 turns so bold-header should appear exactly twice")
    }

    func testRoundTrip_emptyTranscripts_producesEmptyMarkdown() {
        let turns = TranscriptCleanupService.stitch([])
        let md = TranscriptCleanupService.renderMarkdown(turns)
        XCTAssertEqual(md, "")
    }

    func testRoundTrip_singleTurn_markdownFormatIntact() {
        let t = makeTranscript(speaker: "Carol", text: "Just one utterance.", startTime: 0, endTime: 4)
        let turns = TranscriptCleanupService.stitch([t])
        let md = TranscriptCleanupService.renderMarkdown(turns)
        XCTAssertEqual(md, "**Carol** _[0:00]_\n\nJust one utterance.")
    }

    func testRoundTrip_noNameLeakageFromBodyIntoHeader() {
        // Adversarial: body text contains a different speaker's name.
        // The round-trip must not absorb "Dave" into any header.
        let t1 = makeTranscript(speaker: "Alice", text: "Dave was not in this meeting.", startTime: 0, endTime: 5)
        let t2 = makeTranscript(speaker: "Bob", text: "Correct.", startTime: 6, endTime: 8)
        let turns = TranscriptCleanupService.stitch([t1, t2])
        let md = TranscriptCleanupService.renderMarkdown(turns)

        XCTAssertFalse(md.contains("**Dave**"), "Dave should not appear as a Markdown speaker header")
        XCTAssertTrue(md.contains("Dave was not in this meeting."), "Dave's name in body text should be preserved as-is")
    }

    func testRoundTrip_manyTurns_allSpeakersAndBodiesPresent() {
        let speakers = ["Alice", "Bob", "Carol", "Dave", "Eve"]
        let transcripts = speakers.enumerated().map { i, name in
            makeTranscript(speaker: name, text: "Turn \(i + 1) body text.", startTime: Double(i * 10), endTime: Double(i * 10 + 5))
        }
        let turns = TranscriptCleanupService.stitch(transcripts)
        let md = TranscriptCleanupService.renderMarkdown(turns)
        for (i, speaker) in speakers.enumerated() {
            XCTAssertTrue(md.contains("**\(speaker)**"), "\(speaker) header missing")
            XCTAssertTrue(md.contains("Turn \(i + 1) body text."), "Body for \(speaker) missing")
        }
    }

    // MARK: - ADR-005 guarantee: LLM input never contains speaker names

    func testADR005_stitchedBodiesForLLMInput_containNoSpeakerLabels() {
        // Reconstruct the body-only input the service would send to the LLM
        // (same logic as `clean`). Verify speaker names are absent.
        let transcripts = [
            makeTranscript(speaker: "Alice", text: "so we should ship next sprint", startTime: 0, endTime: 5),
            makeTranscript(speaker: "Bob", text: "yeah definitely", startTime: 6, endTime: 8),
        ]
        let turns = TranscriptCleanupService.stitch(transcripts)
        let bodyOnlyInput = turns.enumerated().map { idx, turn in
            "[TURN \(idx + 1)]\n\(turn.text)"
        }.joined(separator: "\n\n")

        XCTAssertFalse(bodyOnlyInput.contains("Alice"), "Speaker name 'Alice' must not appear in LLM input")
        XCTAssertFalse(bodyOnlyInput.contains("Bob"), "Speaker name 'Bob' must not appear in LLM input")
        XCTAssertTrue(bodyOnlyInput.contains("[TURN 1]"), "Must have TURN 1 marker")
        XCTAssertTrue(bodyOnlyInput.contains("[TURN 2]"), "Must have TURN 2 marker")
    }

    func testADR005_reassembledMarkdown_speakerComesFromStitchNotLLM() {
        // After parseTurnBodies, speaker labels come from the original stitch,
        // NOT from any LLM output. Simulate what `clean` does when AI succeeds.
        let original = TranscriptCleanupService.StitchedTurn(
            speaker: "Alice",
            text: "so we should ship next sprint",
            startTime: 0,
            endTime: 5
        )
        // Simulate a cleaned body that the LLM returned (no names).
        let cleanedBody = "So we should ship next sprint."

        // Reassemble: speaker and timestamp from original, body from LLM.
        var copy = original
        copy.text = cleanedBody
        let md = TranscriptCleanupService.renderMarkdown([copy])

        XCTAssertTrue(md.hasPrefix("**Alice**"), "Speaker must come from original stitch, not LLM output")
        XCTAssertTrue(md.contains("So we should ship next sprint."), "Cleaned body must be present")
    }
}

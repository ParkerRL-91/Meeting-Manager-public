import XCTest
@testable import MeetingManager

// Unit coverage for the pure word-level speaker aligner. These pin the
// safety-critical behavior: sub-rows exactly tile the segment span with
// strictly increasing, non-overlapping times (unique-index safety), the
// word-less/uncovered cases degrade to the proven ≥25% best-overlap rule,
// and one-word DTW-jitter fragments are merged rather than emitted.
final class TranscriptAlignerTests: XCTestCase {

    // MARK: - Helpers

    private func word(_ t: String, _ s: Double, _ e: Double) -> WordStamp {
        WordStamp(text: t, start: s, end: e)
    }
    private func seg(_ text: String, _ s: Double, _ e: Double, words: [WordStamp]? = nil) -> TranscriptSegment {
        TranscriptSegment(text: text, startTime: s, endTime: e, confidence: 0.9, words: words)
    }
    private func turn(_ sid: Int, _ s: Double, _ e: Double) -> TranscriptAligner.Turn {
        TranscriptAligner.Turn(sid: sid, start: s, end: e)
    }

    // MARK: - Word path

    func testSegmentFullyInsideOneTurnYieldsOneRow() {
        let words = [word("the", 1, 1.4), word("quick", 1.4, 1.9), word("brown", 2, 2.5),
                     word("fox", 2.5, 3), word("jumps", 3, 3.6), word("high", 3.6, 4)]
        let s = seg("the quick brown fox jumps high", 1, 4, words: words)
        let rows = TranscriptAligner.align(segment: s, turns: [turn(1, 0, 10)])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].sid, 1)
        XCTAssertEqual(rows[0].startTime, 1)
        XCTAssertEqual(rows[0].endTime, 4)
        XCTAssertEqual(rows[0].text, "the quick brown fox jumps high")
    }

    func testSegmentSpanningTwoTurnsSplitsAtBoundaryWord() {
        // Two speakers, boundary at 5s. Words 1-2 (mid <5) → sid 1; words 3-4 (mid >5) → sid 2.
        let words = [word("hello", 1, 2), word("there", 2.5, 3.5), word("hi", 6, 7), word("back", 8, 9)]
        let s = seg("hello there hi back", 1, 9, words: words)
        let rows = TranscriptAligner.align(segment: s, turns: [turn(1, 0, 5), turn(2, 5, 12)])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.map(\.sid), [1, 2])
        XCTAssertEqual(rows[0].startTime, 1, "first row starts at segment start")
        XCTAssertEqual(rows[1].endTime, 9, "last row ends at segment end")
        // Boundary is the midpoint of word2.end (3.5) and word3.start (6) = 4.75.
        XCTAssertEqual(rows[0].endTime, 4.75, accuracy: 0.0001)
        XCTAssertEqual(rows[1].startTime, 4.75, accuracy: 0.0001)
        XCTAssertEqual(rows[0].text, "hello there")
        XCTAssertEqual(rows[1].text, "hi back")
    }

    func testSingleWordFragmentMergesIntoNeighbor() {
        // A lone word lands in turn 2 between two turn-1 stretches → merged away.
        let words = [word("a", 0.2, 0.6), word("b", 0.7, 1.1), word("c", 1.2, 1.6), word("d", 1.7, 2.1),
                     word("x", 4.1, 4.5),   // sole word in turn 2 (fragment)
                     word("e", 5, 5.4), word("f", 5.5, 5.9), word("g", 6, 6.4), word("h", 6.5, 6.9)]
        let s = seg("a b c d x e f g h", 0.2, 6.9, words: words)
        let rows = TranscriptAligner.align(segment: s, turns: [turn(1, 0, 4), turn(2, 4, 4.6), turn(1, 4.6, 10)])
        XCTAssertEqual(rows.count, 1, "fragment merges, then same-sid groups coalesce")
        XCTAssertEqual(rows[0].sid, 1)
        XCTAssertTrue(rows[0].text.contains("x"), "fragment word is preserved in the merged row")
    }

    func testUncoveredWordsInheritNearerFlank() {
        // Middle word's midpoint is in no turn; it should join the nearer flank.
        let words = [word("aa", 1, 1.5), word("bb", 2, 2.5),
                     word("mid", 4.5, 4.8),   // midpoint 4.65 — uncovered (gap 3..7)
                     word("cc", 8, 8.5), word("dd", 9, 9.5)]
        let s = seg("aa bb mid cc dd", 1, 9.5, words: words)
        let rows = TranscriptAligner.align(segment: s, turns: [turn(1, 0, 3), turn(2, 7, 10)])
        // No nil-sid rows; every word attributed.
        XCTAssertFalse(rows.contains { $0.sid == nil })
        // "mid" (4.65) is closer to the left anchor (bb mid 2.25, dist 2.4) than
        // the right anchor (cc mid 8.25, dist 3.6) → joins sid 1.
        XCTAssertEqual(rows.first?.sid, 1)
        XCTAssertTrue(rows.first?.text.contains("mid") ?? false)
    }

    func testAllWordsUncoveredFallsBackToSegmentOverlap() {
        // Words cluster at the segment start; no word midpoint lands in any turn,
        // but turn 2 still overlaps the segment enough for the best-overlap rule.
        let words = [word("aa", 5, 5.3), word("bb", 5.4, 5.7)]   // midpoints 5.15, 5.55
        let s = seg("aa bb", 5, 8, words: words)
        let rows = TranscriptAligner.align(segment: s, turns: [turn(1, 0, 1), turn(2, 6.5, 10)])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].sid, 2, "no word covered → segment-level best-overlap picks turn 2")
        XCTAssertEqual(rows[0].text, "aa bb")
        XCTAssertEqual(rows[0].startTime, 5)
        XCTAssertEqual(rows[0].endTime, 8)
    }

    func testOverlappingTurnsPickGreaterWordOverlap() {
        // Two turns overlap; the word interval overlaps turn 2 more.
        let words = [word("w", 4.9, 5.15)]   // midpoint 5.025, inside both turns
        let s = seg("w", 4.9, 5.15, words: words)
        let rows = TranscriptAligner.align(segment: s, turns: [turn(1, 0, 5.05), turn(2, 4.95, 10)])
        XCTAssertEqual(rows.count, 1)
        // Overlap with turn1 = 5.05-4.9 = 0.15; with turn2 = 5.15-4.95 = 0.20 → turn 2.
        XCTAssertEqual(rows[0].sid, 2)
    }

    func testZeroLengthAndOutOfRangeWordsAreHandled() {
        let words = [word("zero", 1, 1),           // zero-length
                     word("past", 3, 12),          // extends past segment end (10)
                     word("neg", 5, 4)]            // end < start
        let s = seg("zero past neg", 1, 10, words: words)
        let rows = TranscriptAligner.align(segment: s, turns: [turn(1, 0, 10)])
        XCTAssertFalse(rows.isEmpty)
        let allText = rows.map(\.text).joined(separator: " ")
        for w in ["zero", "past", "neg"] { XCTAssertTrue(allText.contains(w)) }
        for r in rows {
            XCTAssertGreaterThanOrEqual(r.startTime, s.startTime)
            XCTAssertLessThanOrEqual(r.endTime, s.endTime)
        }
    }

    func testSubRowTimesStrictlyIncreasingAndNonOverlapping() {
        // 3-speaker split — assert the unique-index safety property.
        let words = [word("a", 0.5, 1), word("b", 1, 1.5),
                     word("c", 3, 3.5), word("d", 3.5, 4),
                     word("e", 6, 6.5), word("f", 6.5, 7)]
        let s = seg("a b c d e f", 0.5, 7, words: words)
        let rows = TranscriptAligner.align(segment: s, turns: [turn(1, 0, 2.5), turn(2, 2.5, 5), turn(3, 5, 10)])
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.map(\.sid), [1, 2, 3])
        for i in 0..<rows.count {
            XCTAssertLessThan(rows[i].startTime, rows[i].endTime, "row \(i) has positive duration")
            if i + 1 < rows.count {
                XCTAssertLessThanOrEqual(rows[i].endTime, rows[i + 1].startTime, "rows \(i)/\(i+1) don't overlap")
            }
        }
    }

    // MARK: - Fallback path (no words)

    func testNoWordsFallsBackToBestOverlap() {
        let s = seg("some words here", 0, 10)   // words: nil
        let rows = TranscriptAligner.align(segment: s, turns: [turn(1, 0, 3), turn(2, 3, 10)])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].sid, 2, "turn 2 has the greater overlap")
        XCTAssertEqual(rows[0].text, "some words here")
    }

    func testFallbackBelowMinimumOverlapYieldsNilSid() {
        let s = seg("some words here", 0, 10)   // words: nil
        let rows = TranscriptAligner.align(segment: s, turns: [turn(1, 0, 1)])   // 10% < 25%
        XCTAssertEqual(rows.count, 1)
        XCTAssertNil(rows[0].sid)
    }

    func testEmptyTurnsYieldsSingleNilRow() {
        let withWords = seg("a b", 0, 2, words: [word("a", 0, 1), word("b", 1, 2)])
        let withoutWords = seg("a b", 0, 2)
        for s in [withWords, withoutWords] {
            let rows = TranscriptAligner.align(segment: s, turns: [])
            XCTAssertEqual(rows.count, 1)
            XCTAssertNil(rows[0].sid)
            XCTAssertEqual(rows[0].startTime, 0)
            XCTAssertEqual(rows[0].endTime, 2)
        }
    }

    // MARK: - bestOverlapSid direct

    func testBestOverlapSidThresholdExactly25Percent() {
        // 10s interval. 2.5s overlap == exactly 25% → passes; 2.49s → fails.
        XCTAssertEqual(TranscriptAligner.bestOverlapSid(start: 0, end: 10, turns: [turn(1, 0, 2.5)]), 1)
        XCTAssertNil(TranscriptAligner.bestOverlapSid(start: 0, end: 10, turns: [turn(1, 0, 2.49)]))
    }
}

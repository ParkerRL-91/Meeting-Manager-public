import XCTest
@testable import MeetingManager

// Tests for the deterministic text-shaping logic in TitleGenerationService.
// Covers sanitize(_:maxLength:) and extractFromSummary(_:) in full.
// Does NOT call generate(fromTranscript:claudeAPIKey:ollama:) — network I/O.
//
// TitleGenerationService is @MainActor; the class is annotated @MainActor so
// all static helpers are reachable without await overhead (same pattern as
// DailyBriefVerifierTests).
@MainActor
final class TitleGenerationTests: XCTestCase {

    // MARK: - Convenience

    private let svc = TitleGenerationService.shared

    // sanitize with the production maxLength (private constant hardcoded to 80).
    private func sanitize(_ raw: String) -> String? {
        TitleGenerationService.sanitize(raw, maxLength: 80)
    }

    // MARK: - Quote stripping — straight double quotes

    func testSanitize_straightDoubleQuotes_stripped() {
        XCTAssertEqual(sanitize("\"Q3 Roadmap Review\""), "Q3 Roadmap Review")
    }

    // MARK: - Quote stripping — smart double quotes (U+201C / U+201D)

    func testSanitize_smartDoubleQuotes_stripped() {
        let input = "\u{201C}Budget Forecast Meeting\u{201D}"
        XCTAssertEqual(sanitize(input), "Budget Forecast Meeting")
    }

    // MARK: - Quote stripping — straight single quotes

    func testSanitize_straightSingleQuotes_stripped() {
        XCTAssertEqual(sanitize("'Design Review'"), "Design Review")
    }

    // MARK: - Quote stripping — smart single quotes (U+2018 / U+2019)

    func testSanitize_smartSingleQuotes_stripped() {
        let input = "\u{2018}Sprint Planning\u{2019}"
        XCTAssertEqual(sanitize(input), "Sprint Planning")
    }

    // MARK: - Quote stripping — only ONE matched pair is removed

    func testSanitize_doubleWrappedQuotes_onlyOuterPairStripped() {
        // Outer straight double quotes are stripped; inner content returned as-is.
        let result = sanitize("\"inner quotes stay\"")
        XCTAssertEqual(result, "inner quotes stay")
    }

    // MARK: - Quote stripping — unmatched leading quote is NOT stripped

    func testSanitize_leadingOnlyQuote_notStripped() {
        // Leading " but no matching closing " — the pair check fails, quote stays.
        let result = sanitize("\"Unmatched leading quote")
        XCTAssertEqual(result, "\"Unmatched leading quote",
            "An unmatched leading quote must not be stripped")
    }

    // MARK: - Quote stripping — unmatched trailing quote is NOT stripped

    func testSanitize_trailingOnlyQuote_notStripped() {
        let result = sanitize("Unmatched trailing quote\"")
        XCTAssertEqual(result, "Unmatched trailing quote\"",
            "An unmatched trailing quote must not be stripped")
    }

    // MARK: - Prefix stripping — "Title:"

    func testSanitize_titleColonPrefix_stripped() {
        XCTAssertEqual(sanitize("Title: Q3 Roadmap"), "Q3 Roadmap")
    }

    // MARK: - Prefix stripping — "title:" (lowercase)

    func testSanitize_titleColonLowercase_stripped() {
        XCTAssertEqual(sanitize("title: Sprint Demo"), "Sprint Demo")
    }

    // MARK: - Prefix stripping — "Meeting Title:"

    func testSanitize_meetingTitleColonPrefix_stripped() {
        XCTAssertEqual(sanitize("Meeting Title: Weekly Sync"), "Weekly Sync")
    }

    // MARK: - Prefix stripping — "meeting title:" (lowercase)

    func testSanitize_meetingTitleColonLowercase_stripped() {
        XCTAssertEqual(sanitize("meeting title: Eng Standup"), "Eng Standup")
    }

    // MARK: - Prefix stripping — "Title" mid-string is NOT stripped

    func testSanitize_titleMidString_notStripped() {
        // The prefix check only fires when the string starts with "Title:" etc.
        let result = sanitize("Discuss the Title of the Report")
        XCTAssertEqual(result, "Discuss the Title of the Report",
            "\"Title\" mid-string must not be stripped")
    }

    // MARK: - Trailing punctuation — single period

    func testSanitize_trailingPeriod_dropped() {
        XCTAssertEqual(sanitize("Q3 Roadmap Review."), "Q3 Roadmap Review")
    }

    // MARK: - Trailing punctuation — exclamation mark

    func testSanitize_trailingExclamation_dropped() {
        XCTAssertEqual(sanitize("Kickoff Meeting!"), "Kickoff Meeting")
    }

    // MARK: - Trailing punctuation — question mark

    func testSanitize_trailingQuestion_dropped() {
        XCTAssertEqual(sanitize("What is the plan?"), "What is the plan")
    }

    // MARK: - Trailing punctuation — comma

    func testSanitize_trailingComma_dropped() {
        XCTAssertEqual(sanitize("Budget Review,"), "Budget Review")
    }

    // MARK: - Trailing punctuation — semicolon

    func testSanitize_trailingSemicolon_dropped() {
        XCTAssertEqual(sanitize("Ops Sync;"), "Ops Sync")
    }

    // MARK: - Trailing punctuation — colon

    func testSanitize_trailingColon_dropped() {
        XCTAssertEqual(sanitize("Architecture Review:"), "Architecture Review")
    }

    // MARK: - Trailing punctuation — multiple consecutive marks all dropped

    func testSanitize_multipleTrailingPunctuation_allDropped() {
        XCTAssertEqual(sanitize("Roadmap Review..."), "Roadmap Review")
    }

    // MARK: - Internal punctuation is preserved

    func testSanitize_internalPunctuation_preserved() {
        // Hyphen and comma inside the title must survive.
        XCTAssertEqual(sanitize("Q3, Q4 Go-to-Market"), "Q3, Q4 Go-to-Market")
    }

    // MARK: - Multi-line input — only first non-empty line is kept

    func testSanitize_multiLineInput_firstLineKept() {
        let raw = "First non-empty line\nSecond line is ignored"
        XCTAssertEqual(sanitize(raw), "First non-empty line")
    }

    func testSanitize_multiLineWithLeadingBlank_firstNonEmptyLineKept() {
        let raw = "\n\nActual Title Here\nExtra line"
        XCTAssertEqual(sanitize(raw), "Actual Title Here")
    }

    // MARK: - Word-count contract: 8 words → unchanged

    func testSanitize_exactlyEightWords_unchanged() {
        let raw = "Discuss Q3 roadmap hiring plan growth and risk"
        let result = sanitize(raw)
        XCTAssertEqual(result, "Discuss Q3 roadmap hiring plan growth and risk",
            "Exactly 8 words must pass through unclamped")
        XCTAssertEqual(result?.components(separatedBy: " ").count, 8)
    }

    // MARK: - Word-count contract: 3 words → unchanged

    func testSanitize_threeWords_unchanged() {
        XCTAssertEqual(sanitize("Q3 Budget Review"), "Q3 Budget Review")
    }

    // MARK: - Word-count contract: 9-word input → clamped to 8 words

    func testSanitize_nineWords_clampedToEight() {
        let raw = "Discuss the Q3 roadmap and the hiring plan now"
        // words: Discuss(1) the(2) Q3(3) roadmap(4) and(5) the(6) hiring(7) plan(8) now(9)
        let result = sanitize(raw)
        XCTAssertEqual(result, "Discuss the Q3 roadmap and the hiring plan",
            "9-word input must be clamped to 8 words")
        XCTAssertEqual(result?.components(separatedBy: " ").count, 8)
    }

    // MARK: - Word-count contract: 12-word input → clamped to exactly 8 words

    func testSanitize_twelveWords_clampedToEight() {
        let raw = "Discuss the Q3 roadmap hiring plan growth risk timeline budget and milestones"
        let result = sanitize(raw)
        XCTAssertEqual(result,
            "Discuss the Q3 roadmap hiring plan growth risk",
            "12-word input must be clamped to exactly the first 8 words")
        XCTAssertEqual(result?.components(separatedBy: " ").count, 8)
    }

    // MARK: - Nil for empty input

    func testSanitize_emptyString_returnsNil() {
        XCTAssertNil(sanitize(""))
    }

    // MARK: - Nil for whitespace-only input

    func testSanitize_whitespaceOnly_returnsNil() {
        XCTAssertNil(sanitize("   \n\t  "))
    }

    // MARK: - Nil for all-punctuation input (becomes empty after stripping)

    func testSanitize_allTrailingPunctuationInput_returnsNil() {
        // After stripping trailing punct from "..." we get "" → nil.
        XCTAssertNil(sanitize("..."))
    }

    // MARK: - Length cap: string > 80 chars but ≤ 8 words → nil

    func testSanitize_shortWordCountButExceedsMaxLength_returnsNil() {
        // 8 words, each 11 chars — total = 8*11 + 7 spaces = 95 > 80
        let raw = "abcdefghijk bcdefghijkl cdefghijklm defghijklmn efghijklmno fghijklmnop ghijklmnopq hijklmnopqr"
        let words = raw.components(separatedBy: " ")
        // Verify our construction: 8 words, each long
        XCTAssertEqual(words.count, 8)
        XCTAssertGreaterThan(raw.count, 80)
        XCTAssertNil(sanitize(raw),
            "A string ≤8 words but >80 characters must return nil")
    }

    // MARK: - Length cap: normal short title passes

    func testSanitize_normalShortTitle_passes() {
        let result = sanitize("Q3 Roadmap Review")
        XCTAssertNotNil(result)
        XCTAssertLessThanOrEqual(result!.count, 80)
    }

    // MARK: - Combined case: quotes + "Title:" prefix + trailing period + word clamp

    /// Input: `  "Title: Discuss the Q3 roadmap and hiring plan now."  `
    ///
    /// Processing chain:
    /// 1. Trim → `"Title: Discuss the Q3 roadmap and hiring plan now."`
    /// 2. Matched straight double quotes → strip → `Title: Discuss the Q3 roadmap and hiring plan now.`
    /// 3. First non-empty line (no newlines) → same
    /// 4. "Title:" prefix → drop → `Discuss the Q3 roadmap and hiring plan now.`
    /// 5. Trailing period → drop → `Discuss the Q3 roadmap and hiring plan now`
    /// 6. Word count: Discuss(1) the(2) Q3(3) roadmap(4) and(5) hiring(6) plan(7) now(8) = 8 words
    ///    → exactly 8, no clamping
    /// Expected: `"Discuss the Q3 roadmap and hiring plan now"`
    func testSanitize_combined_quotesAndPrefixAndTrailingPeriod() {
        let raw = "  \"Title: Discuss the Q3 roadmap and hiring plan now.\"  "
        let result = sanitize(raw)
        XCTAssertEqual(result, "Discuss the Q3 roadmap and hiring plan now",
            "Quote stripping + Title: prefix removal + trailing period removal should yield 8 clean words")
    }

    // MARK: - Combined case: quotes + "Meeting Title:" + word clamp fires

    /// A 10-word content inside quotes with "Meeting Title:" prefix — after prefix
    /// removal the word clamp fires.
    func testSanitize_combined_meetingTitlePrefixAndWordClamp() {
        // 10 words after prefix removal
        let raw = "\"Meeting Title: Alpha Beta Gamma Delta Epsilon Zeta Eta Theta Iota Kappa\""
        let result = sanitize(raw)
        XCTAssertEqual(result, "Alpha Beta Gamma Delta Epsilon Zeta Eta Theta",
            "After Meeting Title: removal and 10-word content, clamp to first 8")
        XCTAssertEqual(result?.components(separatedBy: " ").count, 8)
    }

    // MARK: - Combined case: smart double quotes + trailing comma

    func testSanitize_combined_smartQuotesAndTrailingComma() {
        let raw = "\u{201C}Weekly team sync update,\u{201D}"
        XCTAssertEqual(sanitize(raw), "Weekly team sync update")
    }

    // MARK: - extractFromSummary: multi-line summary — first line used

    func testExtractFromSummary_multiLineSummary_firstLineUsed() {
        let summary = "Short title line\nThis second line should be ignored entirely"
        let result = svc.extractFromSummary(summary)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("Short"),
            "First line content must appear in result")
        XCTAssertFalse(result!.contains("second"),
            "Second line must not appear in result")
    }

    // MARK: - extractFromSummary: long first line — split on ". " for first sentence

    func testExtractFromSummary_longFirstLine_firstSentenceUsed() {
        // First sentence ends at ". " separator; second sentence ignored.
        let summary = "This meeting covered the agenda items. Other topics were also discussed at length."
        let result = svc.extractFromSummary(summary)
        XCTAssertNotNil(result)
        // First sentence: "This meeting covered the agenda items" → 6 words → not clamped
        XCTAssertTrue(result!.contains("This"),
            "First sentence must be present in result")
        XCTAssertFalse(result!.contains("Other"),
            "Second sentence must not appear in result")
    }

    // MARK: - extractFromSummary: one long sentence > 8 words → clamped to 8

    func testExtractFromSummary_longSentence_clampedToEightWords() {
        // No ". " separator so the whole line is the "sentence", then word-clamped.
        let summary = "We discussed the quarterly roadmap and all upcoming milestones for the next two quarters"
        let result = svc.extractFromSummary(summary)
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.components(separatedBy: " ").count, 8,
            "A one-sentence summary longer than 8 words must be clamped to exactly 8")
        XCTAssertEqual(result!, "We discussed the quarterly roadmap and all upcoming")
    }

    // MARK: - extractFromSummary: empty string → nil

    func testExtractFromSummary_emptyString_returnsNil() {
        XCTAssertNil(svc.extractFromSummary(""))
    }

    // MARK: - extractFromSummary: whitespace-only string → nil

    func testExtractFromSummary_whitespaceOnly_returnsNil() {
        XCTAssertNil(svc.extractFromSummary("   \n  \n  "))
    }

    // MARK: - extractFromSummary: exactly 8-word first sentence unchanged

    func testExtractFromSummary_exactlyEightWordSentence_unchangedAfterClamp() {
        let summary = "Reviewed the Q3 roadmap budget hiring and risk"
        let result = svc.extractFromSummary(summary)
        XCTAssertEqual(result, "Reviewed the Q3 roadmap budget hiring and risk",
            "An 8-word summary must pass through unmodified")
    }

    // MARK: - extractFromSummary: trailing punctuation stripped by sanitize pass

    func testExtractFromSummary_trailingPunctuation_stripped() {
        let summary = "Short meeting about onboarding."
        let result = svc.extractFromSummary(summary)
        XCTAssertNotNil(result)
        XCTAssertFalse(result!.hasSuffix("."),
            "Trailing period must be stripped by the sanitize pass inside extractFromSummary")
    }

    // MARK: - extractFromSummary: leading whitespace trimmed

    func testExtractFromSummary_leadingWhitespace_trimmed() {
        let result = svc.extractFromSummary("   Q3 Planning Session")
        XCTAssertEqual(result, "Q3 Planning Session")
    }

    // MARK: - extractFromSummary: single word

    func testExtractFromSummary_singleWord_returned() {
        let result = svc.extractFromSummary("Kickoff")
        XCTAssertEqual(result, "Kickoff")
    }
}

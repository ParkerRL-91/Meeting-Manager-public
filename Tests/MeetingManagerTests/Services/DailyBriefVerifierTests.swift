import XCTest
@testable import MeetingManager

// Tests for the anti-hallucination verifier in DailyBriefAIService.
// Covers all 8 adversarial cases listed in ADR-008 plus boundary cases for
// every helper function the verifier depends on.
//
// The struct is @MainActor so all static helpers inherit that isolation.
// The class is annotated @MainActor to call them without await overhead.
@MainActor
final class DailyBriefVerifierTests: XCTestCase {

    // MARK: - Citation factory (private; avoids redefining any app type)

    /// Build a Citation whose meeting title contains a distinctive term so the
    /// misattribution guard passes. `meetingTitle` defaults to "Acme Renewal"
    /// which yields distinctive term "acme".
    private func makeCitation(
        id: String = "KB1",
        meetingTitle: String = "Acme Renewal",
        relativePath: String = "vendors/acme.md",
        body: String = "Acme requires SOC 2 Type II before signing any enterprise agreement."
    ) -> DailyBriefAIService.Citation {
        DailyBriefAIService.Citation(
            id: id,
            meetingTitle: meetingTitle,
            relativePath: relativePath,
            body: body
        )
    }

    // MARK: - ADR-008 Adversarial Case 1: valid quote kept

    /// A Background sub-bullet whose quoted span is a verbatim substring of the
    /// cited chunk body, attributed to the correct meeting → survives unchanged
    /// (except that extra ids on the same line are stripped, which is a separate
    /// case; here there is exactly one id).
    func testVerify_validQuote_survives() {
        let citation = makeCitation(
            id: "KB1",
            meetingTitle: "Acme Renewal",
            relativePath: "vendors/acme.md",
            body: "Acme requires SOC 2 Type II before signing any enterprise agreement."
        )
        let citations = ["KB1": citation]

        let input = """
        - **11:00 AM** — Acme Renewal · Alex Chen
            - Background: "Acme requires SOC 2 Type II before signing any enterprise agreement" [KB1]
        """

        let result = DailyBriefAIService.verify(text: input, citations: citations).text

        XCTAssertTrue(
            result.contains("Background:"),
            "Valid Background sub-bullet must survive verification"
        )
        XCTAssertTrue(
            result.contains("[KB1]"),
            "Valid citation id must be preserved in surviving sub-bullet"
        )
        XCTAssertTrue(
            result.contains("_Sources: vendors/acme.md_"),
            "Sources footer must be appended listing the used relative path"
        )
    }

    // MARK: - ADR-008 Adversarial Case 2: unknown id dropped

    /// A Background sub-bullet citing [KB99] which is not in the citation map
    /// → the sub-bullet is dropped entirely.
    func testVerify_unknownCitationId_subBulletDropped() {
        let citations: [String: DailyBriefAIService.Citation] = [:]   // empty map

        let input = """
        - **11:00 AM** — Acme Renewal
            - Background: "Acme requires SOC 2 Type II before signing any enterprise agreement" [KB99]
        """

        let result = DailyBriefAIService.verify(text: input, citations: citations).text

        XCTAssertFalse(result.contains("Background:"), "Sub-bullet with unknown id must be dropped")
        XCTAssertFalse(result.contains("[KB99]"), "Unknown id must not appear in output")
        XCTAssertFalse(result.contains("_Sources:"), "No sources footer when nothing survives")
    }

    // MARK: - ADR-008 Adversarial Case 3: paraphrase dropped

    /// A Background sub-bullet whose quoted text is a paraphrase (not a verbatim
    /// substring) of the cited chunk body → the sub-bullet is dropped.
    func testVerify_paraphrase_subBulletDropped() {
        let citation = makeCitation(
            id: "KB1",
            body: "Acme requires SOC 2 Type II before signing any enterprise agreement."
        )
        let citations = ["KB1": citation]

        // "SOC 2 certification is mandatory for Acme" is not a substring of the body
        let input = """
        - **11:00 AM** — Acme Renewal
            - Background: "SOC 2 certification is mandatory for Acme contracts" [KB1]
        """

        let result = DailyBriefAIService.verify(text: input, citations: citations).text

        XCTAssertFalse(result.contains("Background:"), "Paraphrased sub-bullet must be dropped")
        XCTAssertFalse(result.contains("_Sources:"), "No sources footer when nothing survives")
    }

    // MARK: - ADR-008 Adversarial Case 4: misattribution dropped

    /// A Background sub-bullet has a valid verbatim quote from KB1, but KB1's
    /// meeting is "Globex Pricing" while the top-level bullet is "Acme Renewal" —
    /// no shared distinctive term → the sub-bullet is dropped.
    func testVerify_misattribution_subBulletDropped() {
        let citation = makeCitation(
            id: "KB1",
            meetingTitle: "Globex Pricing",   // distinctive term: "globex"
            relativePath: "vendors/globex.md",
            body: "Globex requires net-60 payment terms on all contracts exceeding five thousand dollars."
        )
        let citations = ["KB1": citation]

        // Top-level bullet mentions "Acme Renewal" — no "globex" term overlap
        let input = """
        - **2:00 PM** — Acme Renewal Discussion
            - Background: "Globex requires net-60 payment terms on all contracts exceeding five thousand dollars" [KB1]
        """

        let result = DailyBriefAIService.verify(text: input, citations: citations).text

        XCTAssertFalse(
            result.contains("Background:"),
            "Sub-bullet citing a note from a different meeting must be dropped (misattribution guard)"
        )
    }

    // MARK: - ADR-008 Adversarial Case 5: correct attribution kept

    /// Verifying the positive side of the misattribution guard: when the citation's
    /// meeting title and the containing top-level bullet share a distinctive term,
    /// the sub-bullet survives.
    func testVerify_correctAttribution_survives() {
        // meetingTitle "Globex Pricing" → distinctive term "globex"
        // Top-level bullet also mentions "Globex" → shared term → passes guard
        let citation = makeCitation(
            id: "KB1",
            meetingTitle: "Globex Pricing",
            relativePath: "vendors/globex.md",
            body: "Globex requires net-60 payment terms on all contracts exceeding five thousand dollars."
        )
        let citations = ["KB1": citation]

        let input = """
        - **2:00 PM** — Globex Pricing Review · Alex Chen
            - Background: "Globex requires net-60 payment terms on all contracts exceeding five thousand dollars" [KB1]
        """

        let result = DailyBriefAIService.verify(text: input, citations: citations).text

        XCTAssertTrue(
            result.contains("Background:"),
            "Sub-bullet correctly attributed must survive"
        )
        XCTAssertTrue(result.contains("_Sources: vendors/globex.md_"), "Sources footer must list used path")
    }

    // MARK: - ADR-008 Adversarial Case 6: bare main-line marker stripped

    /// A [KBn] marker appearing on a top-level bullet line (not a Background
    /// sub-bullet) → the marker is stripped but the surrounding prose is kept.
    func testVerify_bareMarkerOnMainLine_markerStrippedProseKept() {
        let citation = makeCitation(id: "KB1")
        let citations = ["KB1": citation]

        // Top-level line — no indentation, no Background prefix
        let input = "- **11:00 AM** — Acme Renewal is important [KB1] this quarter."

        let result = DailyBriefAIService.verify(text: input, citations: citations).text

        XCTAssertFalse(result.contains("[KB1]"), "Unverifiable marker on main line must be stripped")
        XCTAssertTrue(
            result.contains("Acme Renewal is important"),
            "Prose on main line must be preserved after marker is stripped"
        )
        XCTAssertFalse(
            result.contains("_Sources:"),
            "No sources footer when the citation didn't survive as a verified sub-bullet"
        )
    }

    // MARK: - ADR-008 Adversarial Case 7: smart quotes accepted

    /// A Background sub-bullet using Unicode smart quotes (U+201C / U+201D) around
    /// a verbatim extract → the normForMatch check treats them the same as straight
    /// quotes, and the sub-bullet survives.
    func testVerify_smartQuotes_subBulletSurvives() {
        let citation = makeCitation(
            id: "KB1",
            meetingTitle: "Acme Renewal",
            body: "Acme requires SOC 2 Type II before signing any enterprise agreement."
        )
        let citations = ["KB1": citation]

        // U+201C and U+201D smart quotes
        let input = "- **11:00 AM** — Acme Renewal\n    - Background: \u{201C}Acme requires SOC 2 Type II before signing any enterprise agreement\u{201D} [KB1]"

        let result = DailyBriefAIService.verify(text: input, citations: citations).text

        XCTAssertTrue(
            result.contains("Background:"),
            "Smart-quoted verbatim extract must survive verification (smart quotes accepted)"
        )
        XCTAssertTrue(result.contains("[KB1]"), "Citation id must be preserved in smart-quote case")
    }

    // MARK: - ADR-008 Adversarial Case 8: too-short quote dropped (<8 normalized chars)

    /// A Background sub-bullet whose quoted span normalizes to fewer than 8 characters
    /// → the sub-bullet is dropped.
    func testVerify_tooShortQuote_subBulletDropped() {
        let citation = makeCitation(
            id: "KB1",
            body: "SOC 2 required for enterprise deals."
        )
        let citations = ["KB1": citation]

        // "SOC 2" normalizes to "soc 2" — 5 chars (< 8) → dropped
        let input = """
        - **11:00 AM** — Acme Renewal
            - Background: "SOC 2" [KB1]
        """

        let result = DailyBriefAIService.verify(text: input, citations: citations).text

        XCTAssertFalse(result.contains("Background:"), "Quote shorter than 8 normalized chars must be dropped")
    }

    // MARK: - ADR-008 Adversarial Case 8 boundary: exactly 8 normalized chars accepted

    /// A quoted span that normalizes to exactly 8 characters is the threshold —
    /// it must be accepted (≥ 8 is the condition).
    func testVerify_exactlyEightNormalizedChars_accepted() {
        // Body contains "acme soc" after normalization (8 chars: a,c,m,e, ,s,o,c)
        // Quote is "acme soc" verbatim in body
        let citation = makeCitation(
            id: "KB1",
            meetingTitle: "Acme Renewal",
            body: "acme soc review required before signing contracts"
        )
        let citations = ["KB1": citation]

        // Quoted span "acme soc" → normForMatch → "acme soc" → 8 chars (exactly threshold)
        let input = """
        - **11:00 AM** — Acme Renewal
            - Background: "acme soc" [KB1]
        """

        let result = DailyBriefAIService.verify(text: input, citations: citations).text

        XCTAssertTrue(
            result.contains("Background:"),
            "Exactly 8 normalized chars must meet the ≥8 threshold and be accepted"
        )
    }

    // MARK: - ADR-008 Adversarial Case 8 boundary: exactly 7 normalized chars rejected

    func testVerify_sevenNormalizedChars_rejected() {
        // Body contains "acmesoc" (7 alpha chars with no separator after norm)
        // "acmesoc" is 7 chars — below threshold
        let citation = makeCitation(
            id: "KB1",
            meetingTitle: "Acme Renewal",
            body: "acmesoc review required"
        )
        let citations = ["KB1": citation]

        let input = """
        - **11:00 AM** — Acme Renewal
            - Background: "acmesoc" [KB1]
        """

        let result = DailyBriefAIService.verify(text: input, citations: citations).text

        XCTAssertFalse(
            result.contains("Background:"),
            "7 normalized chars must be below the ≥8 threshold and be rejected"
        )
    }

    // MARK: - Multiple ids on one surviving line: extras stripped, one kept

    func testVerify_multipleIdsOnOneLine_onlyValidIdKept() {
        let c1 = makeCitation(
            id: "KB1",
            meetingTitle: "Acme Renewal",
            relativePath: "vendors/acme.md",
            body: "Acme requires SOC 2 Type II before signing any enterprise agreement."
        )
        let c2 = makeCitation(
            id: "KB2",
            meetingTitle: "Globex Pricing",
            relativePath: "vendors/globex.md",
            body: "Globex has a net-60 payment requirement for contracts."
        )
        let citations = ["KB1": c1, "KB2": c2]

        // Line has both [KB1] (valid for Acme) and [KB2] (wrong meeting, Globex)
        let input = """
        - **11:00 AM** — Acme Renewal
            - Background: "Acme requires SOC 2 Type II before signing any enterprise agreement" [KB1] [KB2]
        """

        let result = DailyBriefAIService.verify(text: input, citations: citations).text

        XCTAssertTrue(result.contains("[KB1]"), "Valid id must be kept on surviving line")
        XCTAssertFalse(result.contains("[KB2]"), "Extra invalid id must be stripped from surviving line")
    }

    // MARK: - Sources footer lists only paths actually used

    func testVerify_sourcesFooter_listsOnlyUsedPaths() {
        let c1 = makeCitation(
            id: "KB1",
            meetingTitle: "Acme Renewal",
            relativePath: "vendors/acme.md",
            body: "Acme requires SOC 2 Type II before signing any enterprise agreement."
        )
        let c2 = makeCitation(
            id: "KB2",
            meetingTitle: "Globex Pricing",
            relativePath: "vendors/globex.md",
            body: "Globex has a net-60 payment requirement for contracts."
        )
        let citations = ["KB1": c1, "KB2": c2]

        // Only KB1's sub-bullet is attributable; KB2's sub-bullet has wrong meeting
        let input = """
        - **11:00 AM** — Acme Renewal
            - Background: "Acme requires SOC 2 Type II before signing any enterprise agreement" [KB1]
        - **2:00 PM** — Acme Renewal
            - Background: "Globex has a net-60 payment requirement for contracts" [KB2]
        """

        let result = DailyBriefAIService.verify(text: input, citations: citations).text

        XCTAssertTrue(
            result.contains("vendors/acme.md"),
            "Sources footer must list path for KB1 which survived"
        )
        XCTAssertFalse(
            result.contains("vendors/globex.md"),
            "Sources footer must NOT list path for KB2 which was dropped (misattribution)"
        )
    }

    // MARK: - Sources footer absent when nothing survives

    func testVerify_sourcesFooter_absentWhenNothingSurvives() {
        let citation = makeCitation(id: "KB1")
        let citations = ["KB1": citation]

        // The marker appears on a main line (not a sub-bullet) so it is stripped but
        // never adds to usedPaths → no footer
        let input = "- Acme Renewal note [KB1]"

        let result = DailyBriefAIService.verify(text: input, citations: citations).text

        XCTAssertFalse(
            result.contains("_Sources:"),
            "Sources footer must be absent when no KB citation survived as a verified sub-bullet"
        )
    }

    // MARK: - De-duplicated sources footer

    /// When the same relativePath appears via multiple citations, it must appear
    /// only once in the _Sources: …_ footer.
    func testVerify_sourcesFooter_deduplicatesPaths() {
        let c1 = makeCitation(
            id: "KB1",
            meetingTitle: "Acme Renewal",
            relativePath: "vendors/acme.md",
            body: "Acme requires SOC 2 Type II before signing any enterprise agreement."
        )
        let c2 = DailyBriefAIService.Citation(
            id: "KB2",
            meetingTitle: "Acme Renewal",
            relativePath: "vendors/acme.md",  // same file
            body: "Acme also requests a dedicated account manager during the first year."
        )
        let citations = ["KB1": c1, "KB2": c2]

        let input = """
        - **11:00 AM** — Acme Renewal
            - Background: "Acme requires SOC 2 Type II before signing any enterprise agreement" [KB1]
            - Background: "Acme also requests a dedicated account manager during the first year" [KB2]
        """

        let result = DailyBriefAIService.verify(text: input, citations: citations).text

        // Count occurrences of the path in the sources footer
        let footerStart = result.range(of: "_Sources:")
        XCTAssertNotNil(footerStart, "Sources footer must be present when citations survive")
        let footer = footerStart.map { String(result[$0.lowerBound...]) } ?? ""
        let occurrences = footer.components(separatedBy: "vendors/acme.md").count - 1
        XCTAssertEqual(occurrences, 1, "Same relative path must appear only once in Sources footer")
    }

    // MARK: - Empty input passes through untouched

    func testVerify_emptyInput_returnsEmpty() {
        let result = DailyBriefAIService.verify(text: "", citations: [:]).text
        XCTAssertEqual(result, "", "Empty input must return empty string")
    }

    // MARK: - No [KB markers present, non-empty citations: passes through untouched

    func testVerify_noKBMarkers_textPassesThroughUntouched() {
        let citation = makeCitation(id: "KB1")
        let citations = ["KB1": citation]

        let input = "## Today's read\nThis is a normal brief with no citation markers."

        let result = DailyBriefAIService.verify(text: input, citations: citations).text

        XCTAssertEqual(result, input, "Text with no [KB markers must pass through unchanged")
    }

    // MARK: - Empty citations map and no markers: passes through untouched

    func testVerify_emptyCitationsAndNoMarkers_returnsInputUnchanged() {
        let input = "## Today's read\nA brief with no citations configured."
        let result = DailyBriefAIService.verify(text: input, citations: [:]).text
        XCTAssertEqual(result, input, "Completely citation-free brief must return unchanged")
    }

    // MARK: - Citation ids that never appear in the text

    func testVerify_citationIdsNeverAppearInText_noFooter() {
        let c1 = makeCitation(id: "KB1")
        let c2 = makeCitation(id: "KB2")
        let citations = ["KB1": c1, "KB2": c2]

        // Text contains no [KB…] markers at all
        let input = "- **9:00 AM** — Engineering standup\n- **11:00 AM** — Acme Renewal"

        let result = DailyBriefAIService.verify(text: input, citations: citations).text

        XCTAssertEqual(result, input, "Text with no [KB markers must be returned unchanged")
        XCTAssertFalse(result.contains("_Sources:"), "No sources footer when no markers appear")
    }

    // MARK: - Misattribution guard skipped when title has no distinctive term

    /// When the citation's meeting title yields no distinctive terms (all stopwords
    /// or short tokens), the guard is skipped entirely and the sub-bullet can survive
    /// if the quote is verbatim. This is the escape hatch documented in the verifier
    /// comment: "Skipped when the title has no distinctive term."
    func testVerify_citationTitleHasNoDistinctiveTerms_guardSkippedAndSurvives() {
        // "Weekly Sync" → "weekly" is a stopword, "sync" is a stopword → no distinctive terms
        let citation = DailyBriefAIService.Citation(
            id: "KB1",
            meetingTitle: "Weekly Sync",
            relativePath: "notes/weekly.md",
            body: "The deployment window is every Thursday at midnight Eastern time."
        )
        let citations = ["KB1": citation]

        // Top-level bullet has nothing in common with "Weekly Sync" — but guard is skipped
        let input = """
        - **9:00 AM** — Engineering standup
            - Background: "The deployment window is every Thursday at midnight Eastern time" [KB1]
        """

        let result = DailyBriefAIService.verify(text: input, citations: citations).text

        XCTAssertTrue(
            result.contains("Background:"),
            "When citation title has no distinctive terms the misattribution guard is skipped and a verbatim sub-bullet survives"
        )
    }

    // MARK: - firstQuotedSpan: straight double quotes

    func testFirstQuotedSpan_straightDoubleQuotes_returnsInnerText() {
        let line = "- Background: \"Acme requires SOC 2\" [KB1]"
        let span = DailyBriefAIService.firstQuotedSpan(in: line)
        XCTAssertEqual(span, "Acme requires SOC 2")
    }

    // MARK: - firstQuotedSpan: smart quotes (U+201C / U+201D)

    func testFirstQuotedSpan_smartDoubleQuotes_returnsInnerText() {
        let line = "- Background: \u{201C}Acme requires SOC 2\u{201D} [KB1]"
        let span = DailyBriefAIService.firstQuotedSpan(in: line)
        XCTAssertEqual(span, "Acme requires SOC 2")
    }

    // MARK: - firstQuotedSpan: straight quotes take precedence over smart quotes

    func testFirstQuotedSpan_straightQuotesPrecedeSmartQuotes() {
        // Line has a straight-quoted span first; smart quotes also present
        let line = "\"straight first\" then \u{201C}smart second\u{201D}"
        let span = DailyBriefAIService.firstQuotedSpan(in: line)
        XCTAssertEqual(span, "straight first", "Straight quotes must be matched before smart quotes")
    }

    // MARK: - firstQuotedSpan: no quotes → nil

    func testFirstQuotedSpan_noQuotes_returnsNil() {
        let line = "- Background: Acme requires SOC 2 [KB1]"
        let span = DailyBriefAIService.firstQuotedSpan(in: line)
        XCTAssertNil(span, "Line with no quotes must return nil")
    }

    // MARK: - firstQuotedSpan: empty straight-quoted string → nil

    /// The regex `"[^\"]{1,400}"` requires at least 1 character inside the quotes,
    /// so "" (zero inner chars) does not match → nil.
    func testFirstQuotedSpan_emptyQuote_returnsNil() {
        let line = "- Background: \"\" [KB1]"
        let span = DailyBriefAIService.firstQuotedSpan(in: line)
        XCTAssertNil(span, "Empty double-quoted string must return nil (regex requires ≥1 inner char)")
    }

    // MARK: - firstQuotedSpan: single quotes are not recognized

    func testFirstQuotedSpan_singleQuotes_returnsNil() {
        let line = "- Background: 'single quoted span' [KB1]"
        let span = DailyBriefAIService.firstQuotedSpan(in: line)
        XCTAssertNil(span, "Single-quoted spans must not be recognized by firstQuotedSpan")
    }

    // MARK: - normForMatch: lowercases input

    func testNormForMatch_lowercasesInput() {
        let result = DailyBriefAIService.normForMatch("HELLO WORLD")
        XCTAssertEqual(result, "hello world")
    }

    // MARK: - normForMatch: collapses non-alphanumeric runs to a single space

    func testNormForMatch_collapsesNonAlphanumericRunsToSingleSpace() {
        let result = DailyBriefAIService.normForMatch("hello,  world!!!")
        XCTAssertEqual(result, "hello world")
    }

    // MARK: - normForMatch: no leading or trailing space

    func testNormForMatch_noLeadingOrTrailingSpace() {
        let result = DailyBriefAIService.normForMatch("  leading and trailing  ")
        XCTAssertFalse(result.hasPrefix(" "), "Normalized string must not start with a space")
        XCTAssertFalse(result.hasSuffix(" "), "Normalized string must not end with a space")
    }

    // MARK: - normForMatch: punctuation drift doesn't break substring match

    /// A quote with a comma and period that differs from the stored body in
    /// punctuation still matches after normalization.
    func testNormForMatch_punctuationDriftStillMatchesAfterNorm() {
        let bodyNorm = DailyBriefAIService.normForMatch(
            "Acme requires SOC 2 Type II before signing any enterprise agreement."
        )
        // Model quoted with extra comma and no period
        let quoteNorm = DailyBriefAIService.normForMatch(
            "Acme requires SOC 2, Type II before signing any enterprise agreement"
        )
        XCTAssertTrue(
            bodyNorm.contains(quoteNorm),
            "normForMatch must collapse punctuation differences so quote still matches body"
        )
    }

    // MARK: - normForMatch: empty string

    func testNormForMatch_emptyString_returnsEmpty() {
        let result = DailyBriefAIService.normForMatch("")
        XCTAssertEqual(result, "")
    }

    // MARK: - normForMatch: only non-alphanumeric characters

    func testNormForMatch_allPunctuation_returnsEmpty() {
        let result = DailyBriefAIService.normForMatch("... --- !!!")
        XCTAssertEqual(result, "", "String of only non-alphanumeric chars must normalize to empty")
    }

    // MARK: - singleLineExcerpt: collapses newlines to spaces

    func testSingleLineExcerpt_collapsesNewlines() {
        let input = "Line one\nLine two\nLine three"
        let result = DailyBriefAIService.singleLineExcerpt(input, limit: 1000)
        XCTAssertEqual(result, "Line one Line two Line three")
        XCTAssertFalse(result.contains("\n"), "Result must contain no newlines")
    }

    // MARK: - singleLineExcerpt: respects limit with ellipsis

    func testSingleLineExcerpt_truncatesAtLimit() {
        let input = "ABCDEFGHIJ"  // 10 chars
        let result = DailyBriefAIService.singleLineExcerpt(input, limit: 5)
        // count > limit → truncate
        XCTAssertTrue(result.hasSuffix("…"), "Truncated excerpt must end with ellipsis")
        XCTAssertTrue(
            result.hasPrefix("ABCDE"),
            "Truncated excerpt must preserve leading characters up to the limit"
        )
    }

    // MARK: - singleLineExcerpt: does NOT truncate when count == limit

    /// The guard is `count > limit` so at exact equality the string passes through.
    func testSingleLineExcerpt_exactlyAtLimit_notTruncated() {
        let input = "ABCDE"  // 5 chars
        let result = DailyBriefAIService.singleLineExcerpt(input, limit: 5)
        XCTAssertEqual(result, "ABCDE", "String exactly at limit must not be truncated")
    }

    // MARK: - singleLineExcerpt: empty string

    func testSingleLineExcerpt_emptyInput_returnsEmpty() {
        let result = DailyBriefAIService.singleLineExcerpt("", limit: 100)
        XCTAssertEqual(result, "")
    }

    // MARK: - singleLineExcerpt: collapses multiple blank lines and leading whitespace

    func testSingleLineExcerpt_multipleNewlinesCollapsedAndTrimmed() {
        let input = "\n  header\n\nbody text\n"
        let result = DailyBriefAIService.singleLineExcerpt(input, limit: 1000)
        XCTAssertFalse(result.hasPrefix(" "), "Leading whitespace must be trimmed after collapse")
        XCTAssertFalse(result.contains("\n"), "Newlines must be fully collapsed")
    }

    // MARK: - verify: valid Background sub-bullet + valid id = verbatim match via normalization

    /// Covers that normForMatch is actually applied when comparing the quote to the body,
    /// so minor whitespace differences in the quoted text still count as verbatim.
    func testVerify_normalizationBridgesBetweenQuoteAndBody() {
        let citation = makeCitation(
            id: "KB1",
            meetingTitle: "Acme Renewal",
            body: "Acme's security team requires SOC 2 Type II; review is owned by their CISO."
        )
        let citations = ["KB1": citation]

        // Quote has different punctuation from body but normalizes to the same substring
        // Body norm: "acme s security team requires soc 2 type ii review is owned by their ciso"
        // Quote: "acme s security team requires soc 2 type ii" → subset after norm
        let input = """
        - **11:00 AM** — Acme Renewal
            - Background: "Acme's security team requires SOC 2 Type II" [KB1]
        """

        let result = DailyBriefAIService.verify(text: input, citations: citations).text

        XCTAssertTrue(
            result.contains("Background:"),
            "Quote that normalizes to a verbatim substring of the body must survive"
        )
    }

    // MARK: - verify: sub-bullet without a top-level parent still uses the last seen top bullet

    /// The misattribution guard tracks `lastTopBullet` across all lines. A sub-bullet
    /// appearing after a top-level bullet (even with non-bullet lines between) must be
    /// evaluated against that top-level bullet.
    func testVerify_lastTopBulletTrackedAcrossNonBulletLines() {
        let citation = makeCitation(
            id: "KB1",
            meetingTitle: "Acme Renewal",
            relativePath: "vendors/acme.md",
            body: "Acme requires SOC 2 Type II before signing any enterprise agreement."
        )
        let citations = ["KB1": citation]

        let input = """
        - **11:00 AM** — Acme Renewal · Alex Chen
        Some non-bullet prose line in between.
            - Background: "Acme requires SOC 2 Type II before signing any enterprise agreement" [KB1]
        """

        let result = DailyBriefAIService.verify(text: input, citations: citations).text

        XCTAssertTrue(
            result.contains("Background:"),
            "lastTopBullet must persist across non-bullet lines and allow valid sub-bullet to survive"
        )
    }

    // MARK: - verify: POTENTIAL BUG — sub-bullet with valid id but no quoted span at all

    /// ADR-008 specifies the format `- Background: "<exact quote>" [KB1]`. If the
    /// model omits the quotes entirely (just `- Background: some text [KB1]`), there
    /// is no quoted span, so `firstQuotedSpan` returns nil. With no quote the sub-bullet
    /// falls through to the `isSubBullet` branch and is dropped — which is the correct
    /// ADR behavior (no verifiable quote → drop).
    ///
    /// This test documents that the drop happens as expected.
    func testVerify_subBulletWithNoQuotedSpan_dropped() {
        let citation = makeCitation(
            id: "KB1",
            body: "Acme requires SOC 2 Type II before signing any enterprise agreement."
        )
        let citations = ["KB1": citation]

        // No quote characters at all — the sub-bullet uses prose directly
        let input = """
        - **11:00 AM** — Acme Renewal
            - Background: Acme requires SOC 2 Type II before signing [KB1]
        """

        let result = DailyBriefAIService.verify(text: input, citations: citations).text

        XCTAssertFalse(
            result.contains("[KB1]"),
            "Sub-bullet with no quoted span must be dropped — no verifiable quote means no valid citation"
        )
    }

    // MARK: - verify: multiple Background sub-bullets, only valid one survives

    func testVerify_mixOfValidAndInvalidSubBullets_onlyValidSurvives() {
        let c1 = makeCitation(
            id: "KB1",
            meetingTitle: "Acme Renewal",
            relativePath: "vendors/acme.md",
            body: "Acme requires SOC 2 Type II before signing any enterprise agreement."
        )
        let c2 = makeCitation(
            id: "KB2",
            meetingTitle: "Acme Renewal",
            relativePath: "vendors/acme2.md",
            body: "Acme prefers quarterly billing cycles over annual upfront payment."
        )
        let citations = ["KB1": c1, "KB2": c2]

        let input = """
        - **11:00 AM** — Acme Renewal
            - Background: "Acme requires SOC 2 Type II before signing any enterprise agreement" [KB1]
            - Background: "Acme insists on free professional services for onboarding" [KB2]
        """

        let result = DailyBriefAIService.verify(text: input, citations: citations).text

        XCTAssertTrue(result.contains("[KB1]"), "Valid sub-bullet KB1 must survive")
        XCTAssertFalse(result.contains("[KB2]"), "Invalid sub-bullet KB2 (paraphrase) must be dropped")
        XCTAssertTrue(result.contains("vendors/acme.md"), "Sources footer must include KB1's path")
        XCTAssertFalse(result.contains("vendors/acme2.md"), "Sources footer must not include KB2's path")
    }
}

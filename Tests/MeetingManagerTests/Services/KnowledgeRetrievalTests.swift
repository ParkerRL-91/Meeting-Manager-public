import XCTest
@testable import MeetingManager

// Tests for the KB relevance gate and daily-brief cache invalidation (ADR-008).
//
// KnowledgeBaseService.distinctiveTerms and KnowledgeBaseService.formatChunks
// are both `static` but `formatChunks` carries @MainActor isolation on the
// class, so the whole suite is annotated @MainActor.
@MainActor
final class KnowledgeRetrievalTests: XCTestCase {

    // MARK: - Helpers

    private func makeKBDocument(
        relativePath: String = "notes/acme.md",
        chunkIndex: Int = 0,
        heading: String? = nil,
        body: String = "Sample body text."
    ) -> KBDocument {
        KBDocument(
            id: nil,
            filePath: "/kb/\(relativePath)",
            fileName: relativePath.components(separatedBy: "/").last ?? relativePath,
            relativePath: relativePath,
            chunkIndex: chunkIndex,
            heading: heading,
            body: body,
            indexedAt: SampleData.fixedDate
        )
    }

    private func makeEmptyPrepBrief(meetingId: String = "m1") -> MeetingPrepBrief {
        MeetingPrepBrief(
            meetingId: meetingId,
            participants: [],
            openActionItems: [],
            relatedMeetings: [],
            lastSummaryExcerpt: nil,
            meetLink: nil,
            previousSession: nil,
            sinceLastMet: nil,
            seriesOpenLoops: nil
        )
    }

    private func makeBriefEntry(
        meeting: Meeting,
        kbChunks: [KBDocument] = []
    ) -> DailyBriefEntry {
        DailyBriefEntry(
            meeting: meeting,
            prepBrief: makeEmptyPrepBrief(meetingId: meeting.id),
            category: .new,
            kbChunks: kbChunks
        )
    }

    private func makeDailyBrief(
        entries: [DailyBriefEntry],
        date: Date = SampleData.fixedDate
    ) -> DailyBrief {
        DailyBrief(
            date: date,
            meetings: entries,
            totalOpenItems: entries.reduce(0) { $0 + $1.prepBrief.openActionItems.count },
            meetingsNeedingPrep: entries.filter { $0.category == .carryOver }.count
        )
    }

    // MARK: - distinctiveTerms: basic tokenization

    func testDistinctiveTerms_returnsLowercasedTerms() {
        let terms = KnowledgeBaseService.distinctiveTerms(in: "Acme Requires Enterprise")
        XCTAssertTrue(terms.contains("acme"), "Terms must be lowercased")
        XCTAssertTrue(terms.contains("requires"), "Terms must be lowercased")
        XCTAssertTrue(terms.contains("enterprise"), "Terms must be lowercased")
    }

    func testDistinctiveTerms_excludesTermsShorterThanFourChars() {
        // "yes", "no", "ok", "hi" are all < 4 chars
        let terms = KnowledgeBaseService.distinctiveTerms(in: "yes no ok hi")
        XCTAssertTrue(terms.isEmpty, "Terms shorter than 4 chars must be excluded")
    }

    func testDistinctiveTerms_includesExactlyFourCharTerm() {
        // "risk" is 4 chars — must be included
        let terms = KnowledgeBaseService.distinctiveTerms(in: "risk")
        XCTAssertTrue(terms.contains("risk"), "4-char token must be included (≥4 threshold is inclusive)")
    }

    func testDistinctiveTerms_deduplicatesTerms() {
        // "acme" appears three times but set should contain it once
        let terms = KnowledgeBaseService.distinctiveTerms(in: "acme acme acme")
        XCTAssertEqual(terms.count, 1)
        XCTAssertTrue(terms.contains("acme"))
    }

    func testDistinctiveTerms_stripsPunctuation() {
        // Commas, periods, colons should not be part of tokens
        let terms = KnowledgeBaseService.distinctiveTerms(in: "acme, requires: enterprise.")
        XCTAssertTrue(terms.contains("acme"))
        XCTAssertTrue(terms.contains("requires"))
        XCTAssertTrue(terms.contains("enterprise"))
        XCTAssertFalse(terms.contains("acme,"), "Punctuation must not be included in tokens")
    }

    func testDistinctiveTerms_emptyInput_returnsEmptySet() {
        let terms = KnowledgeBaseService.distinctiveTerms(in: "")
        XCTAssertTrue(terms.isEmpty)
    }

    func testDistinctiveTerms_garbageInput_returnsEmptySet() {
        // Only digits and punctuation with nothing ≥4 alphanum chars
        let terms = KnowledgeBaseService.distinctiveTerms(in: "!!! ??? ### --- 123 42")
        // "123" is 3 chars (< 4) and "42" is 2 chars; all punctuation runs are split off
        XCTAssertTrue(terms.isEmpty, "Garbage input with no ≥4-char alphanumeric tokens must yield empty set")
    }

    // MARK: - distinctiveTerms: stopword filtering

    func testDistinctiveTerms_dropsMeetingNoiseSynonyms() {
        // ADR-008 stopwords: meeting, sync, weekly, zoom among others
        let noiseTitle = "Meeting Weekly Sync Zoom Standup Daily"
        let terms = KnowledgeBaseService.distinctiveTerms(in: noiseTitle)
        XCTAssertTrue(terms.isEmpty, "Title composed entirely of meeting-noise stopwords must yield empty set")
    }

    func testDistinctiveTerms_dropsMeeting() {
        let terms = KnowledgeBaseService.distinctiveTerms(in: "meeting")
        XCTAssertFalse(terms.contains("meeting"), "'meeting' must be filtered as a stopword")
    }

    func testDistinctiveTerms_dropsSync() {
        let terms = KnowledgeBaseService.distinctiveTerms(in: "sync")
        XCTAssertFalse(terms.contains("sync"), "'sync' must be filtered as a stopword")
    }

    func testDistinctiveTerms_dropsWeekly() {
        let terms = KnowledgeBaseService.distinctiveTerms(in: "weekly")
        XCTAssertFalse(terms.contains("weekly"), "'weekly' must be filtered as a stopword")
    }

    func testDistinctiveTerms_dropsZoom() {
        let terms = KnowledgeBaseService.distinctiveTerms(in: "zoom")
        XCTAssertFalse(terms.contains("zoom"), "'zoom' must be filtered as a stopword")
    }

    func testDistinctiveTerms_dropsStandup() {
        let terms = KnowledgeBaseService.distinctiveTerms(in: "standup")
        XCTAssertFalse(terms.contains("standup"), "'standup' must be filtered as a stopword")
    }

    func testDistinctiveTerms_dropsReview() {
        let terms = KnowledgeBaseService.distinctiveTerms(in: "review")
        XCTAssertFalse(terms.contains("review"), "'review' must be filtered as a stopword")
    }

    func testDistinctiveTerms_dropsTeam() {
        let terms = KnowledgeBaseService.distinctiveTerms(in: "team")
        XCTAssertFalse(terms.contains("team"), "'team' must be filtered as a stopword")
    }

    func testDistinctiveTerms_dropsSession() {
        let terms = KnowledgeBaseService.distinctiveTerms(in: "session")
        XCTAssertFalse(terms.contains("session"), "'session' must be filtered as a stopword")
    }

    func testDistinctiveTerms_keepsDomainSpecificTermsAlongsideStopwords() {
        // "acme" is distinctive; "weekly" is a stopword
        let terms = KnowledgeBaseService.distinctiveTerms(in: "Acme Weekly Review")
        XCTAssertTrue(terms.contains("acme"), "'acme' must survive — it is not a stopword")
        XCTAssertFalse(terms.contains("weekly"), "'weekly' must be filtered as a stopword")
        XCTAssertFalse(terms.contains("review"), "'review' must be filtered as a stopword")
    }

    // MARK: - distinctiveTerms: overlap semantics used by the relevance gate

    func testDistinctiveTerms_twoStringsShareingTwoTerms_overlap() {
        // Gate requires ≥2 overlapping distinctive terms.
        let queryTerms = KnowledgeBaseService.distinctiveTerms(in: "Acme security contract")
        let chunkTerms = KnowledgeBaseService.distinctiveTerms(in: "Acme security posture review required")
        let overlap = queryTerms.intersection(chunkTerms)
        XCTAssertGreaterThanOrEqual(overlap.count, 2,
            "Strings sharing 'acme' and 'security' must produce ≥2 overlapping distinctive terms")
    }

    func testDistinctiveTerms_coincidentalStopwordOnly_noOverlap() {
        // Two titles that share only the stopword "meeting" — after filtering, zero overlap
        let t1 = KnowledgeBaseService.distinctiveTerms(in: "meeting planning")
        let t2 = KnowledgeBaseService.distinctiveTerms(in: "meeting budget")
        // "planning" and "budget" are not stopwords but they don't appear in both
        // The point: a shared stopword ("meeting") contributes zero to overlap
        let onlyStopwordShared = t1.intersection(t2)
        XCTAssertFalse(onlyStopwordShared.contains("meeting"),
            "Shared stopword 'meeting' must not appear in distinctive-term overlap")
    }

    func testDistinctiveTerms_singleDistinctiveTermOverlap_doesNotMeetTwoTermGate() {
        // One shared term should not satisfy the ≥2 term gate
        let t1 = KnowledgeBaseService.distinctiveTerms(in: "acme planning budget")
        let t2 = KnowledgeBaseService.distinctiveTerms(in: "acme security posture")
        let overlap = t1.intersection(t2)
        XCTAssertEqual(overlap.count, 1, "Only 'acme' is shared — overlap count must be 1 (< 2 gate threshold)")
    }

    func testDistinctiveTerms_noSharedTerms_emptyIntersection() {
        let t1 = KnowledgeBaseService.distinctiveTerms(in: "acme enterprise contract")
        let t2 = KnowledgeBaseService.distinctiveTerms(in: "globex pricing payment")
        let overlap = t1.intersection(t2)
        XCTAssertTrue(overlap.isEmpty, "Completely distinct titles must produce empty intersection")
    }

    // MARK: - formatChunks: empty input

    func testFormatChunks_emptyArray_returnsEmptyString() {
        let result = KnowledgeBaseService.formatChunks([])
        XCTAssertEqual(result, "", "Empty chunk array must return empty string")
    }

    // MARK: - formatChunks: single chunk without heading

    func testFormatChunks_singleChunkNoHeading_formattedCorrectly() {
        let chunk = makeKBDocument(
            relativePath: "notes/acme.md",
            heading: nil,
            body: "Acme requires SOC 2 Type II."
        )
        let result = KnowledgeBaseService.formatChunks([chunk])

        XCTAssertTrue(result.contains("_notes/acme.md_"),
            "Output must contain the relative path as italic Markdown")
        XCTAssertTrue(result.contains("Acme requires SOC 2 Type II."),
            "Output must contain the body text")
        XCTAssertFalse(result.contains("**"), "No heading markers expected when heading is nil")
    }

    // MARK: - formatChunks: single chunk with heading

    func testFormatChunks_singleChunkWithHeading_formattedCorrectly() {
        let chunk = makeKBDocument(
            relativePath: "vendors/acme.md",
            heading: "Security Requirements",
            body: "Acme requires SOC 2 Type II before signing."
        )
        let result = KnowledgeBaseService.formatChunks([chunk])

        XCTAssertTrue(result.contains("**Security Requirements**"),
            "Heading must be wrapped in bold Markdown markers")
        XCTAssertTrue(result.contains("_vendors/acme.md_"),
            "Path must be formatted as italic Markdown")
        XCTAssertTrue(result.contains("Acme requires SOC 2 Type II before signing."),
            "Body must appear after the heading")
    }

    // MARK: - formatChunks: multiple chunks joined by separator

    func testFormatChunks_multipleChunks_joinedBySeparator() {
        let c1 = makeKBDocument(relativePath: "notes/a.md", chunkIndex: 0, body: "Body of chunk A.")
        let c2 = makeKBDocument(relativePath: "notes/b.md", chunkIndex: 0, body: "Body of chunk B.")
        let result = KnowledgeBaseService.formatChunks([c1, c2])

        XCTAssertTrue(result.contains("\n\n---\n\n"),
            "Multiple chunks must be separated by the Markdown horizontal-rule separator")
        XCTAssertTrue(result.contains("Body of chunk A."))
        XCTAssertTrue(result.contains("Body of chunk B."))
    }

    // MARK: - formatChunks: body is trimmed of leading/trailing whitespace

    func testFormatChunks_bodyWithLeadingTrailingWhitespace_trimmed() {
        let chunk = makeKBDocument(body: "   trimmed content   ")
        let result = KnowledgeBaseService.formatChunks([chunk])
        XCTAssertTrue(result.contains("trimmed content"),
            "Body must be included in output")
        XCTAssertFalse(result.hasSuffix("   "),
            "Trailing whitespace on body must be trimmed")
    }

    // MARK: - dayString: deterministic ISO format

    func testDayString_returnsISODateString() {
        // fixedDate = 2023-03-07 in the reference date epoch
        let result = DailyBriefCache.dayString(for: SampleData.fixedDate)
        // Must match yyyy-MM-dd pattern
        let regex = try? NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2}$"#)
        let range = NSRange(result.startIndex..., in: result)
        let match = regex?.firstMatch(in: result, range: range)
        XCTAssertNotNil(match, "dayString must return a yyyy-MM-dd formatted string; got: \(result)")
    }

    func testDayString_sameDayTwoCalls_identicalString() {
        let d1 = SampleData.fixedDate
        let d2 = SampleData.fixedDate.addingTimeInterval(60 * 30) // 30 min later, same day
        XCTAssertEqual(
            DailyBriefCache.dayString(for: d1),
            DailyBriefCache.dayString(for: d2),
            "Two dates on the same calendar day must produce the same dayString"
        )
    }

    func testDayString_differentDays_differentStrings() {
        let d1 = SampleData.fixedDate
        let d2 = SampleData.fixedDate.addingTimeInterval(60 * 60 * 24) // +1 day
        XCTAssertNotEqual(
            DailyBriefCache.dayString(for: d1),
            DailyBriefCache.dayString(for: d2),
            "Dates on different calendar days must produce different dayStrings"
        )
    }

    // MARK: - signature: identical briefs produce identical signatures

    func testSignature_identicalBriefs_identicalSignature() {
        let meeting = SampleData.makeMeeting(
            id: "m1",
            title: "Acme Renewal",
            scheduledStartDate: SampleData.fixedDate
        )
        let chunk = makeKBDocument(relativePath: "vendors/acme.md", chunkIndex: 0, body: "SOC 2 required.")
        let entry = makeBriefEntry(meeting: meeting, kbChunks: [chunk])
        let brief = makeDailyBrief(entries: [entry])

        let sig1 = DailyBriefCache.signature(for: brief)
        let sig2 = DailyBriefCache.signature(for: brief)
        XCTAssertEqual(sig1, sig2, "Identical briefs must produce identical signatures (stable hash)")
    }

    // MARK: - signature: different meeting IDs → different signatures

    func testSignature_differentMeetingIds_differentSignatures() {
        let m1 = SampleData.makeMeeting(id: "m1", title: "Acme Renewal",
                                        scheduledStartDate: SampleData.fixedDate)
        let m2 = SampleData.makeMeeting(id: "m2", title: "Acme Renewal",
                                        scheduledStartDate: SampleData.fixedDate)
        let brief1 = makeDailyBrief(entries: [makeBriefEntry(meeting: m1)])
        let brief2 = makeDailyBrief(entries: [makeBriefEntry(meeting: m2)])

        XCTAssertNotEqual(
            DailyBriefCache.signature(for: brief1),
            DailyBriefCache.signature(for: brief2),
            "Different meeting IDs must produce different signatures"
        )
    }

    // MARK: - signature: different meeting titles → different signatures

    func testSignature_differentTitles_differentSignatures() {
        let m1 = SampleData.makeMeeting(id: "m1", title: "Acme Renewal",
                                        scheduledStartDate: SampleData.fixedDate)
        let m2 = SampleData.makeMeeting(id: "m1", title: "Globex Pricing",
                                        scheduledStartDate: SampleData.fixedDate)
        let brief1 = makeDailyBrief(entries: [makeBriefEntry(meeting: m1)])
        let brief2 = makeDailyBrief(entries: [makeBriefEntry(meeting: m2)])

        XCTAssertNotEqual(
            DailyBriefCache.signature(for: brief1),
            DailyBriefCache.signature(for: brief2),
            "Different meeting titles must produce different signatures"
        )
    }

    // MARK: - signature: different scheduled times → different signatures

    func testSignature_differentScheduledTimes_differentSignatures() {
        let t1 = SampleData.fixedDate
        let t2 = SampleData.fixedDate.addingTimeInterval(3600)
        let m1 = SampleData.makeMeeting(id: "m1", title: "Acme Renewal", scheduledStartDate: t1)
        let m2 = SampleData.makeMeeting(id: "m1", title: "Acme Renewal", scheduledStartDate: t2)
        let brief1 = makeDailyBrief(entries: [makeBriefEntry(meeting: m1)])
        let brief2 = makeDailyBrief(entries: [makeBriefEntry(meeting: m2)])

        XCTAssertNotEqual(
            DailyBriefCache.signature(for: brief1),
            DailyBriefCache.signature(for: brief2),
            "Different scheduled times must produce different signatures"
        )
    }

    // MARK: - signature: kbChunks body change (same length) → different signatures

    /// ADR-008: "same-length edit still invalidates — content-hashed, not counted."
    func testSignature_sameLengthKBBodyEdit_differentSignatures() {
        let meeting = SampleData.makeMeeting(
            id: "m1",
            title: "Acme Renewal",
            scheduledStartDate: SampleData.fixedDate
        )
        // Two bodies of identical length, different content
        let bodyA = "SOC 2 required for all enterprise agreements signing."  // 52 chars
        let bodyB = "SOC 2 required for all enterprise agreements signing!"  // 52 chars (final char changed)
        XCTAssertEqual(bodyA.count, bodyB.count, "Test setup: bodies must have the same character count")

        let chunkA = makeKBDocument(relativePath: "vendors/acme.md", chunkIndex: 0, body: bodyA)
        let chunkB = makeKBDocument(relativePath: "vendors/acme.md", chunkIndex: 0, body: bodyB)

        let brief1 = makeDailyBrief(entries: [makeBriefEntry(meeting: meeting, kbChunks: [chunkA])])
        let brief2 = makeDailyBrief(entries: [makeBriefEntry(meeting: meeting, kbChunks: [chunkB])])

        XCTAssertNotEqual(
            DailyBriefCache.signature(for: brief1),
            DailyBriefCache.signature(for: brief2),
            "A same-length edit to a KB chunk body must still invalidate the signature (content-hashed)"
        )
    }

    // MARK: - signature: adding a kbChunk → different signature

    func testSignature_addingKBChunk_differentSignature() {
        let meeting = SampleData.makeMeeting(
            id: "m1",
            title: "Acme Renewal",
            scheduledStartDate: SampleData.fixedDate
        )
        let chunk1 = makeKBDocument(relativePath: "vendors/acme.md", chunkIndex: 0, body: "SOC 2 required.")
        let chunk2 = makeKBDocument(relativePath: "vendors/acme.md", chunkIndex: 1, body: "Annual renewal cycle.")

        let brief1 = makeDailyBrief(entries: [makeBriefEntry(meeting: meeting, kbChunks: [chunk1])])
        let brief2 = makeDailyBrief(entries: [makeBriefEntry(meeting: meeting, kbChunks: [chunk1, chunk2])])

        XCTAssertNotEqual(
            DailyBriefCache.signature(for: brief1),
            DailyBriefCache.signature(for: brief2),
            "Adding a KB chunk must change the signature"
        )
    }

    // MARK: - signature: removing kbChunks (non-empty → empty) → different signature

    func testSignature_removingAllKBChunks_differentSignature() {
        let meeting = SampleData.makeMeeting(
            id: "m1",
            title: "Acme Renewal",
            scheduledStartDate: SampleData.fixedDate
        )
        let chunk = makeKBDocument(relativePath: "vendors/acme.md", chunkIndex: 0, body: "SOC 2 required.")

        let briefWith = makeDailyBrief(entries: [makeBriefEntry(meeting: meeting, kbChunks: [chunk])])
        let briefWithout = makeDailyBrief(entries: [makeBriefEntry(meeting: meeting, kbChunks: [])])

        XCTAssertNotEqual(
            DailyBriefCache.signature(for: briefWith),
            DailyBriefCache.signature(for: briefWithout),
            "Removing KB chunks must change the signature"
        )
    }

    // MARK: - signature: kbChunk relativePath change → different signature

    func testSignature_kbChunkRelativePathChange_differentSignature() {
        let meeting = SampleData.makeMeeting(
            id: "m1",
            title: "Acme Renewal",
            scheduledStartDate: SampleData.fixedDate
        )
        let chunkA = makeKBDocument(relativePath: "vendors/acme.md", chunkIndex: 0, body: "SOC 2 required.")
        let chunkB = makeKBDocument(relativePath: "vendors/acme-v2.md", chunkIndex: 0, body: "SOC 2 required.")

        let brief1 = makeDailyBrief(entries: [makeBriefEntry(meeting: meeting, kbChunks: [chunkA])])
        let brief2 = makeDailyBrief(entries: [makeBriefEntry(meeting: meeting, kbChunks: [chunkB])])

        XCTAssertNotEqual(
            DailyBriefCache.signature(for: brief1),
            DailyBriefCache.signature(for: brief2),
            "A KB chunk relative path change must invalidate the signature"
        )
    }

    // MARK: - signature: meeting order independence

    func testSignature_meetingOrder_isOrderIndependent() {
        let m1 = SampleData.makeMeeting(id: "aaa", title: "Alpha Meeting",
                                        scheduledStartDate: SampleData.fixedDate)
        let m2 = SampleData.makeMeeting(id: "bbb", title: "Beta Meeting",
                                        scheduledStartDate: SampleData.fixedDate)

        let briefAB = makeDailyBrief(entries: [makeBriefEntry(meeting: m1), makeBriefEntry(meeting: m2)])
        let briefBA = makeDailyBrief(entries: [makeBriefEntry(meeting: m2), makeBriefEntry(meeting: m1)])

        XCTAssertEqual(
            DailyBriefCache.signature(for: briefAB),
            DailyBriefCache.signature(for: briefBA),
            "Meeting entry order must not affect the signature (sorted by id before hashing)"
        )
    }

    // MARK: - signature: empty brief

    func testSignature_emptyBrief_stableNonEmptyHash() {
        let brief = makeDailyBrief(entries: [])
        let sig1 = DailyBriefCache.signature(for: brief)
        let sig2 = DailyBriefCache.signature(for: brief)
        XCTAssertFalse(sig1.isEmpty, "Empty brief must still produce a non-empty signature string")
        XCTAssertEqual(sig1, sig2, "Empty brief signature must be stable across calls")
    }

    // MARK: - signature: output is a valid lowercase hex string

    func testSignature_outputIsLowercaseHexString() {
        let meeting = SampleData.makeMeeting(id: "m1", title: "Acme Renewal",
                                             scheduledStartDate: SampleData.fixedDate)
        let sig = DailyBriefCache.signature(for: makeDailyBrief(entries: [makeBriefEntry(meeting: meeting)]))
        let validHex = CharacterSet(charactersIn: "0123456789abcdef")
        XCTAssertTrue(
            sig.unicodeScalars.allSatisfy { validHex.contains($0) },
            "signature must be a lowercase hex string (SHA-256 output)"
        )
        // SHA-256 → 64 hex chars
        XCTAssertEqual(sig.count, 64, "SHA-256 hex digest must be 64 characters")
    }
}

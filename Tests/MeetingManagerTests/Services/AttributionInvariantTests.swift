import XCTest
@testable import MeetingManager

/// Pins the attribution invariants repaired in TASK-025 so they can't
/// silently regress: resolveAttendee grade ordering and ambiguity rejection,
/// vocative ambiguous-first-name dropping, candidate-pool dedupe semantics,
/// elimination respecting already-consumed names, and voice-profile EMA
/// re-normalization.
/// @MainActor: SpeakerAttributionService (and its statics) are
/// MainActor-isolated.
@MainActor
final class AttributionInvariantTests: XCTestCase {

    // MARK: - resolveAttendee grade order

    func testResolveAttendeeExactMatchWins() {
        let candidates: Set<String> = ["Samantha Jones", "Sam Smith"]
        XCTAssertEqual(
            SpeakerAttributionService.resolveAttendee(name: "Sam Smith", candidates: candidates),
            "Sam Smith"
        )
    }

    func testResolveAttendeeFirstTokenBeatsSubstring() {
        // "Sam" substring-matches BOTH candidates ("Samantha Jones" contains
        // "sam"), so the old substring-first ordering returned an arbitrary
        // Set element. First-token uniqueness must resolve it to Sam Smith.
        let candidates: Set<String> = ["Samantha Jones", "Sam Smith"]
        XCTAssertEqual(
            SpeakerAttributionService.resolveAttendee(name: "Sam", candidates: candidates),
            "Sam Smith"
        )
    }

    func testResolveAttendeeAmbiguousFirstTokenRejects() {
        let candidates: Set<String> = ["Sam Smith", "Sam Jones"]
        XCTAssertNil(
            SpeakerAttributionService.resolveAttendee(name: "Sam", candidates: candidates),
            "Two attendees share the first token — resolving would be a coin flip"
        )
    }

    func testResolveAttendeeUniqueSubstringResolvesEmailForm() {
        let candidates: Set<String> = ["Priya Patel <priya@example.com>", "Dave Smith"]
        XCTAssertEqual(
            SpeakerAttributionService.resolveAttendee(name: "Priya Patel", candidates: candidates),
            "Priya Patel <priya@example.com>"
        )
    }

    func testResolveAttendeeAmbiguousSubstringRejects() {
        // Neither token-unique nor substring-unique → reject rather than
        // returning a nondeterministic Set element.
        let candidates: Set<String> = ["Ann Lee-Park", "Ann Leeson"]
        XCTAssertNil(
            SpeakerAttributionService.resolveAttendee(name: "Ann Lee", candidates: candidates)
        )
    }

    // MARK: - Vocative ambiguous first names

    private func turns(_ entries: [(speaker: String, text: String)]) -> [Transcript] {
        entries.enumerated().map { idx, e in
            SampleData.makeTranscript(
                meetingId: "m1",
                speakerLabel: e.speaker,
                text: e.text,
                startTime: Double(idx) * 5,
                endTime: Double(idx) * 5 + 4
            )
        }
    }

    func testVocativeDropsFirstNameSharedByTwoAttendees() {
        let transcripts = turns([
            ("Speaker 1", "Hey Sam, what do you think?"),
            ("Speaker 2", "I think we should ship it."),
            ("Speaker 1", "Thanks Sam."),
            ("Speaker 2", "Any time."),
        ])
        let result = VocativeMiningService.attributeWithConfidence(
            transcripts: transcripts,
            attendees: ["Sam Smith", "Sam Jones", "Parker Reid"],
            userFirstName: "Parker",
            existingMapping: [:]
        )
        XCTAssertNil(
            result.mapping["Speaker 2"],
            "\"Sam\" is shared by two attendees — a vote would name an arbitrary one"
        )
    }

    func testVocativeStillResolvesUnambiguousFirstName() {
        let transcripts = turns([
            ("Speaker 1", "Hey Sam, what do you think?"),
            ("Speaker 2", "I think we should ship it."),
            ("Speaker 1", "Thanks Sam."),
            ("Speaker 2", "Any time."),
        ])
        let result = VocativeMiningService.attributeWithConfidence(
            transcripts: transcripts,
            attendees: ["Sam Smith", "Dana Wu", "Parker Reid"],
            userFirstName: "Parker",
            existingMapping: [:]
        )
        XCTAssertEqual(result.mapping["Speaker 2"], "Sam Smith")
    }

    // MARK: - Candidate-pool dedupe

    func testCleanCandidatesKeepsDistinctPeopleSharingFirstToken() {
        let cleaned = SpeakerNamingEngine.cleanCandidates(["Sam", "Sam Smith"])
        XCTAssertEqual(
            Set(cleaned), Set(["Sam", "Sam Smith"]),
            "Two plain names are never merged — they can be distinct attendees"
        )
    }

    func testCleanCandidatesMergesEmailFormOfSamePerson() {
        let cleaned = SpeakerNamingEngine.cleanCandidates(["Dave Smith", "dave@example.com"])
        XCTAssertEqual(cleaned.count, 1)
    }

    func testCleanCandidatesDropsExactDuplicates() {
        let cleaned = SpeakerNamingEngine.cleanCandidates(["Dana Wu", "dana wu"])
        XCTAssertEqual(cleaned.count, 1)
    }

    // MARK: - Elimination respects consumed names

    func testEliminationDoesNotMintDuplicateOfExistingAssignment() {
        // One open cluster, two candidates — but Alice is already assigned
        // (existing map from a prior pass). Elimination may only use Bob.
        let result = SpeakerNamingEngine.eliminate(
            allClusters: ["Speaker 2"],
            candidates: ["Alice Chen", "Bob Diaz"],
            assigned: ["Speaker 1": "Alice Chen"]
        )
        XCTAssertEqual(result["Speaker 2"]?.name, "Bob Diaz")
    }

    func testEliminationAbstainsWhenAllCandidatesConsumed() {
        let result = SpeakerNamingEngine.eliminate(
            allClusters: ["Speaker 2"],
            candidates: ["Alice Chen"],
            assigned: ["Speaker 1": "Alice Chen"]
        )
        XCTAssertTrue(result.isEmpty, "The only candidate is already used — abstain")
    }

    // MARK: - Voice profile EMA re-normalization

    func testMergeRenormalizesEmbeddingToUnitLength() async throws {
        let database = try TestDatabase.create()
        let repo = VoiceProfileRepository(database: database)

        // Two orthogonal unit vectors: their lerp has norm < 1 unless the
        // merge re-normalizes (0.75·a + 0.25·b → ‖·‖ ≈ 0.79).
        var a = [Float](repeating: 0, count: 40); a[0] = 1
        var b = [Float](repeating: 0, count: 40); b[1] = 1

        try await repo.merge(personName: "Dana Wu", newEmbedding: a, personRepo: nil, source: .voiceMatch)
        try await repo.merge(personName: "Dana Wu", newEmbedding: b, personRepo: nil, source: .voiceMatch)

        let profile = try await repo.profile(for: "Dana Wu")
        let embedding = try XCTUnwrap(profile?.embedding)
        let norm = sqrt(embedding.reduce(Float(0)) { $0 + $1 * $1 })
        XCTAssertEqual(norm, 1.0, accuracy: 0.001,
                       "EMA-merged embeddings must stay unit length — the matcher treats dot product as cosine")
    }

    // MARK: - Enrollment confidence clamp

    func testEnrollmentConfidenceClampsMeasuredSimilarity() {
        // Weak match floors at 0.50 (below the 0.60 amber bar → draws the dot).
        XCTAssertEqual(AppState.enrollmentConfidence(for: 0.3), 0.50, accuracy: 0.0001)
        // Strong match caps at 0.99 (1.0 is reserved for manual renames).
        XCTAssertEqual(AppState.enrollmentConfidence(for: 0.995), 0.99, accuracy: 0.0001)
        // Mid-range passes through unclamped.
        XCTAssertEqual(AppState.enrollmentConfidence(for: 0.82), 0.82, accuracy: 0.0001)
        // Unmeasured → the fixed legacy tier.
        XCTAssertEqual(AppState.enrollmentConfidence(for: nil),
                       AppState.enrollmentMatchFallbackConfidence, accuracy: 0.0001)
    }
}

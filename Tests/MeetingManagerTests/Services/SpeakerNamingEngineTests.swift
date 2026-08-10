import XCTest
@testable import MeetingManager

// Unit coverage for the pure naming logic in SpeakerNamingEngine. These pin the
// safety-critical behavior of the naming design:
// elimination only fires when unambiguous, hygiene drops non-persons, and the
// contradiction flags surface (rather than apply) every uncertain case.
final class SpeakerNamingEngineTests: XCTestCase {

    // MARK: - eliminate

    func testOneOnOneElimination() {
        // You already anchored to Speaker 1; exactly one cluster + one candidate left.
        let result = SpeakerNamingEngine.eliminate(
            allClusters: ["Speaker 1", "Speaker 2"],
            candidates: ["Connor McLeod"],
            assigned: ["Speaker 1": "Parker Reid"]
        )
        XCTAssertEqual(result["Speaker 2"]?.name, "Connor McLeod")
        XCTAssertEqual(result["Speaker 2"]?.confidence, SpeakerNamingEngine.eliminationConfidence)
    }

    func testNPersonEliminationCascades() {
        // 3 clusters, 2 anchored, 1 candidate left → the lone candidate fills the lone cluster.
        let result = SpeakerNamingEngine.eliminate(
            allClusters: ["Speaker 1", "Speaker 2", "Speaker 3"],
            candidates: ["Sam Carter"],
            assigned: ["Speaker 1": "Parker Reid", "Speaker 2": "Connor McLeod"]
        )
        XCTAssertEqual(result["Speaker 3"]?.name, "Sam Carter")
    }

    func testNoEliminationWhenTwoCandidatesRemain() {
        // Ambiguous: 1 cluster open but 2 candidates → must NOT guess.
        let result = SpeakerNamingEngine.eliminate(
            allClusters: ["Speaker 1", "Speaker 2"],
            candidates: ["Connor McLeod", "Sam Carter"],
            assigned: ["Speaker 1": "Parker Reid"]
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testNoEliminationWhenTwoClustersRemain() {
        // Over-split: 2 clusters open, 1 candidate → must NOT guess which is which.
        let result = SpeakerNamingEngine.eliminate(
            allClusters: ["Speaker 1", "Speaker 2", "Speaker 3"],
            candidates: ["Connor McLeod"],
            assigned: ["Speaker 1": "Parker Reid"]
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testNoCandidatesProducesNothing() {
        let result = SpeakerNamingEngine.eliminate(
            allClusters: ["Speaker 1"],
            candidates: [],
            assigned: [:]
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testAlreadyUsedCandidateIsNotReassigned_fuzzy() {
        // The assigned name is a SUPERSTRING of the candidate (pronouns appended,
        // different case) — the substring/case-insensitive "used" check must
        // still treat Connor as taken, so Speaker 2 is NOT given Connor again.
        let result = SpeakerNamingEngine.eliminate(
            allClusters: ["Speaker 1", "Speaker 2"],
            candidates: ["Connor McLeod"],
            assigned: ["Speaker 1": "connor mcleod (he/him)"]
        )
        XCTAssertNil(result["Speaker 2"], "a fuzzily-matched assigned name must not be reassigned")
    }

    func testEliminateIsIdempotentAcrossRepeatedCalls() {
        // Pure + monotonic: re-running with the engine's own output folded into
        // `assigned` yields no further assignments (no oscillation).
        let clusters: Set<String> = ["Speaker 1", "Speaker 2"]
        let first = SpeakerNamingEngine.eliminate(
            allClusters: clusters, candidates: ["Connor McLeod"],
            assigned: ["Speaker 1": "Parker Reid"]
        )
        XCTAssertEqual(first["Speaker 2"]?.name, "Connor McLeod")
        var merged = ["Speaker 1": "Parker Reid"]
        for (c, v) in first { merged[c] = v.name }
        let second = SpeakerNamingEngine.eliminate(
            allClusters: clusters, candidates: ["Connor McLeod"], assigned: merged
        )
        XCTAssertTrue(second.isEmpty, "nothing left to eliminate on the second pass")
    }

    // MARK: - cleanCandidates

    func testCleanCandidatesDropsBots() {
        let cleaned = SpeakerNamingEngine.cleanCandidates([
            "Parker Reid", "Otter.ai Notetaker", "Fireflies.ai", "Connor McLeod",
        ])
        XCTAssertEqual(cleaned.sorted(), ["Connor McLeod", "Parker Reid"])
    }

    func testCleanCandidatesDropsRoomsAndResources() {
        let cleaned = SpeakerNamingEngine.cleanCandidates([
            "Sam Carter", "Boardroom A", "Large Conference Room", "noreply@acme.com",
        ])
        XCTAssertEqual(cleaned, ["Sam Carter"])
    }

    func testCleanCandidatesDropsDistributionLists() {
        let cleaned = SpeakerNamingEngine.cleanCandidates([
            "team@acme.com", "all@acme.com", "jordan@acme.com",
        ])
        XCTAssertEqual(cleaned, ["jordan@acme.com"])
    }

    func testCleanCandidatesDedupesSamePerson() {
        // Name and email of the same person should collapse to one.
        let cleaned = SpeakerNamingEngine.cleanCandidates([
            "Connor McLeod", "connor mcleod", "  Connor McLeod  ",
        ])
        XCTAssertEqual(cleaned.count, 1)
    }

    func testCleanCandidatesDropsEmpties() {
        let cleaned = SpeakerNamingEngine.cleanCandidates(["", "   ", "Parker Reid"])
        XCTAssertEqual(cleaned, ["Parker Reid"])
    }

    // MARK: - flags

    func testFlagNameNotInvited() {
        let flags = SpeakerNamingEngine.flags(
            finalMapping: ["Speaker 1": "Connor McLeod"],
            allClusters: ["Speaker 1"],
            acceptedCandidates: ["Sam Carter"],
            userNames: ["Parker Reid"]
        )
        XCTAssertTrue(flags.contains { $0.kind == .nameNotInvited })
    }

    func testUserNotFlaggedAsNotInvited() {
        // The local user named on their own cluster is never flagged, even when
        // they aren't on an externally-organized invite.
        let flags = SpeakerNamingEngine.flags(
            finalMapping: ["Speaker 1": "Parker Reid"],
            allClusters: ["Speaker 1"],
            acceptedCandidates: ["Sam Carter"],
            userNames: ["Parker Reid"]
        )
        XCTAssertFalse(flags.contains { $0.kind == .nameNotInvited })
    }

    func testFlagDuplicateName() {
        let flags = SpeakerNamingEngine.flags(
            finalMapping: ["Speaker 1": "Connor McLeod", "Speaker 2": "Connor McLeod"],
            allClusters: ["Speaker 1", "Speaker 2"],
            acceptedCandidates: ["Connor McLeod", "Parker Reid"],
            userNames: ["Parker Reid"]
        )
        XCTAssertTrue(flags.contains { $0.kind == .duplicateName })
    }

    func testFlagMoreVoicesThanInvited() {
        let flags = SpeakerNamingEngine.flags(
            finalMapping: ["Speaker 1": "Parker Reid"],
            allClusters: ["Speaker 1", "Speaker 2", "Speaker 3"],
            acceptedCandidates: ["Parker Reid", "Connor McLeod"],
            userNames: ["Parker Reid"]
        )
        XCTAssertTrue(flags.contains { $0.kind == .moreVoicesThanInvited })
    }

    func testFlagUnexpectedSpeaker() {
        // An unassigned cluster while every invitee is already accounted for.
        let flags = SpeakerNamingEngine.flags(
            finalMapping: ["Speaker 1": "Parker Reid", "Speaker 2": "Connor McLeod"],
            allClusters: ["Speaker 1", "Speaker 2", "Speaker 3"],
            acceptedCandidates: ["Parker Reid", "Connor McLeod"],
            userNames: ["Parker Reid"]
        )
        // Note: with 3 clusters > 2 invited this also raises moreVoicesThanInvited;
        // assert the unexpectedSpeaker flag specifically.
        XCTAssertTrue(flags.contains { $0.kind == .unexpectedSpeaker })
    }

    func testCleanMappingProducesNoFlags() {
        let flags = SpeakerNamingEngine.flags(
            finalMapping: ["Speaker 1": "Parker Reid", "Speaker 2": "Connor McLeod"],
            allClusters: ["Speaker 1", "Speaker 2"],
            acceptedCandidates: ["Parker Reid", "Connor McLeod"],
            userNames: ["Parker Reid"]
        )
        XCTAssertTrue(flags.isEmpty)
    }
}

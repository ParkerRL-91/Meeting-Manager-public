import XCTest
import GRDB
@testable import MeetingManager

/// PRJ-020 / TASK-128: decision triage gate + correctable ownership.
///
/// Covers the seams the change introduces:
///  1. The v73 backfill predicate — which rows enter the inbox, which are spared.
///  2. `mergeForMeeting` shielding — confirmed/dismissed/corrected rows survive
///     re-extraction; an untouched suggestion is refreshed in place.
///  3. Repository status transitions — confirm / dismiss / restore / setOwner.
///  4. Single-unambiguous owner resolution (the rule the AppState glue applies).
final class DecisionTriageTests: XCTestCase {

    private var db: AppDatabase!
    private var repo: DecisionRepository!
    private let meetingId = "m-dec"

    override func setUpWithError() throws {
        db = try TestDatabase.create()
        repo = DecisionRepository(database: db)
    }

    // MARK: - Fixtures

    private func makeDecision(
        title: String,
        status: Decision.TriageStatus,
        ownerName: String? = nil,
        editedAt: Date? = nil,
        dismissedAt: Date? = nil,
        meetingId: String? = nil
    ) -> Decision {
        Decision(
            id: nil,
            meetingId: meetingId ?? self.meetingId,
            title: title,
            rationale: nil,
            involved: nil,
            quoteText: nil,
            startTime: nil,
            endTime: nil,
            normalizedKey: Decision.normalize(title),
            status: status.rawValue,
            ownerName: ownerName,
            ownerPersonId: nil,
            editedAt: editedAt,
            dismissedAt: dismissedAt,
            extractedAt: SampleData.fixedDate,
            createdAt: SampleData.fixedDate
        )
    }

    @discardableResult
    private func insert(_ decision: Decision) async throws -> Int64 {
        try await db.writer.write { dbc in
            var d = decision
            try d.insert(dbc)
            return d.id!
        }
    }

    private func fetch(_ id: Int64) async throws -> Decision? {
        try await db.writer.read { dbc in try Decision.fetchOne(dbc, key: id) }
    }

    // Mirror of the v73 backfill so the predicate is asserted directly against
    // hand-seeded rows (all migrations already ran on the test DB).
    private func runBackfill() async throws {
        try await db.writer.write { dbc in
            try dbc.execute(sql: """
                UPDATE decision SET status = 'suggested'
                WHERE status = 'active' AND editedAt IS NULL AND dismissedAt IS NULL
                """)
        }
    }

    // MARK: - v73 backfill predicate

    func testBackfillMovesUntouchedActiveToSuggested() async throws {
        let id = try await insert(makeDecision(title: "Ship on Friday", status: .active))
        try await runBackfill()
        let after = try await fetch(id)
        XCTAssertEqual(after?.status, "suggested", "An untouched active row must enter the inbox.")
    }

    func testBackfillSparesEditedActiveRow() async throws {
        let id = try await insert(makeDecision(title: "Adopt the plan", status: .active,
                                               editedAt: SampleData.fixedDate))
        try await runBackfill()
        let after = try await fetch(id)
        XCTAssertEqual(after?.status, "active", "A user-edited row stays confirmed.")
    }

    func testBackfillSparesDismissedRow() async throws {
        let id = try await insert(makeDecision(title: "Reject the idea", status: .dismissed,
                                               dismissedAt: SampleData.fixedDate))
        try await runBackfill()
        let after = try await fetch(id)
        XCTAssertEqual(after?.status, "dismissed", "A dismissed row is unchanged.")
    }

    // MARK: - merge shielding

    func testMergeShieldsConfirmedRowAndBackfillsOwner() async throws {
        // A confirmed row with no owner yet.
        let id = try await insert(makeDecision(title: "Ship on Friday", status: .active))
        // Re-extraction reproduces the same key with a (wrong) new owner.
        let fresh = makeDecision(title: "Ship on Friday", status: .suggested, ownerName: "David")
        try await repo.mergeForMeeting(meetingId, extracted: [fresh])

        let after = try await fetch(id)
        XCTAssertEqual(after?.status, "active", "Confirmed row must not be demoted to suggested.")
        XCTAssertEqual(after?.ownerName, "David", "A confirmed row with no owner gains the fresh suggestion.")
    }

    func testMergeDoesNotDeleteConfirmedRowWhenKeyVanishes() async throws {
        let id = try await insert(makeDecision(title: "Keep this decision", status: .active))
        // Fresh pass reproduces a DIFFERENT decision — the confirmed key is gone.
        let fresh = makeDecision(title: "A totally different decision", status: .suggested)
        try await repo.mergeForMeeting(meetingId, extracted: [fresh])

        XCTAssertNotNil(try await fetch(id), "A confirmed row whose key vanished must not be deleted.")
    }

    func testMergePreservesCorrectedButSuggestedOwner() async throws {
        // A suggestion whose owner was corrected (editedAt stamped) but never
        // confirmed — the headline mis-attribution use case.
        let id = try await insert(makeDecision(title: "Email David", status: .suggested,
                                               ownerName: "Jordan", editedAt: SampleData.fixedDate))
        let fresh = makeDecision(title: "Email David", status: .suggested, ownerName: "Parker")
        try await repo.mergeForMeeting(meetingId, extracted: [fresh])

        let after = try await fetch(id)
        XCTAssertEqual(after?.ownerName, "Jordan", "A corrected owner survives re-extraction even before confirm.")
    }

    func testMergeRefreshesUntouchedSuggestionInPlace() async throws {
        let id = try await insert(makeDecision(title: "Pick vendor", status: .suggested, ownerName: "Old"))
        let fresh = makeDecision(title: "Pick vendor", status: .suggested, ownerName: "New")
        try await repo.mergeForMeeting(meetingId, extracted: [fresh])

        let after = try await fetch(id)
        XCTAssertEqual(after?.ownerName, "New", "An untouched suggestion is refreshed in place.")
    }

    // MARK: - status transitions

    func testConfirmAndDismissAndRestore() async throws {
        let id = try await insert(makeDecision(title: "Move to Q3", status: .suggested))

        try await repo.confirm(id: id)
        var after = try await fetch(id)
        XCTAssertEqual(after?.status, "active")
        XCTAssertNil(after?.dismissedAt)

        try await repo.setDismissed(id: id, true)
        after = try await fetch(id)
        XCTAssertEqual(after?.status, "dismissed")
        XCTAssertNotNil(after?.dismissedAt)

        try await repo.restoreToInbox(id: id)
        after = try await fetch(id)
        XCTAssertEqual(after?.status, "suggested")
        XCTAssertNil(after?.dismissedAt)
    }

    func testUnDismissReturnsToInboxNotActive() async throws {
        let id = try await insert(makeDecision(title: "Reopen", status: .dismissed,
                                               dismissedAt: SampleData.fixedDate))
        try await repo.setDismissed(id: id, false)
        let after = try await fetch(id)
        XCTAssertEqual(after?.status, "suggested",
                       "Un-dismissing returns to the inbox, never silently confirms.")
    }

    func testSetOwnerStampsEditedAt() async throws {
        let id = try await insert(makeDecision(title: "Assign owner", status: .suggested))
        try await repo.setOwner(id: id, name: "Jordan", personId: "person-123")
        let after = try await fetch(id)
        XCTAssertEqual(after?.ownerName, "Jordan")
        XCTAssertEqual(after?.ownerPersonId, "person-123")
        XCTAssertNotNil(after?.editedAt, "An owner correction is an edit — it must shield the row.")
        XCTAssertTrue(after?.isUserTouched ?? false)
    }

    // MARK: - owner resolution (single-unambiguous rule)

    func testSingleMatchResolvesOwnerPersonId() {
        let david = Person.make(canonicalName: "David Smith")
        let bekim = Person.make(canonicalName: "Jordan")
        let people = [david, bekim]

        let hits = people.filter { $0.matches(participant: "Jordan") }
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.id, bekim.id)
    }

    func testAmbiguousMatchLeavesOwnerUnresolved() {
        let davidA = Person.make(canonicalName: "David Smith")
        let davidB = Person.make(canonicalName: "David Jones")
        let people = [davidA, davidB]

        let hits = people.filter { $0.matches(participant: "David") }
        XCTAssertEqual(hits.count, 2, "Two Davids share the canonical key — resolution must stay nil.")
        let resolved = hits.count == 1 ? hits[0].id : nil
        XCTAssertNil(resolved)
    }
}

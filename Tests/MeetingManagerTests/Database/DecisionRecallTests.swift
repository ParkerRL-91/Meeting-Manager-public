import XCTest
import GRDB
@testable import MeetingManager

/// PRJ-020 / TASK-129: decision search + recall surfaces.
///
/// Covers the seams Part B introduces:
///  1. Person-page matching — a decision's owner/involved names resolve to a
///     person via canonical keys (aliases included), not raw name equality.
///  2. KB markdown — confirmed decisions render a `## Decisions` section.
///  3. Prep loop — `buildSeriesOpenLoops` includes suggested rows, not just
///     confirmed (exercised here through the repository query it uses).
final class DecisionRecallTests: XCTestCase {

    private func makeDecision(
        title: String,
        status: Decision.TriageStatus,
        ownerName: String? = nil,
        ownerPersonId: String? = nil,
        involved: [String] = [],
        rationale: String? = nil,
        meetingId: String = "m-recall"
    ) -> Decision {
        var d = Decision(
            id: nil,
            meetingId: meetingId,
            title: title,
            rationale: rationale,
            involved: nil,
            quoteText: nil,
            startTime: nil,
            endTime: nil,
            normalizedKey: Decision.normalize(title),
            status: status.rawValue,
            ownerName: ownerName,
            ownerPersonId: ownerPersonId,
            targetName: nil,
            editedAt: nil,
            dismissedAt: status == .dismissed ? SampleData.fixedDate : nil,
            extractedAt: SampleData.fixedDate,
            createdAt: SampleData.fixedDate
        )
        if !involved.isEmpty { d.setInvolved(involved) }
        return d
    }

    // MARK: - Person-page matching

    func testBelongsToMatchesOwnerByAlias() {
        let person = Person.make(canonicalName: "David Smith", aliases: ["Dave"])
        let decision = makeDecision(title: "Ship v2", status: .active, ownerName: "Dave")
        XCTAssertTrue(decision.belongsTo(person: person),
                      "An owner name that is an alias must match via canonical keys.")
    }

    func testBelongsToMatchesInvolvedName() {
        let person = Person.make(canonicalName: "Jordan")
        let decision = makeDecision(title: "Pick vendor", status: .active,
                                    ownerName: "Parker", involved: ["Jordan"])
        XCTAssertTrue(decision.belongsTo(person: person),
                      "A person named in the involved list belongs to the decision.")
    }

    func testBelongsToMatchesResolvedPersonId() {
        let person = Person.make(canonicalName: "Someone Else")
        let decision = makeDecision(title: "Approve budget", status: .active,
                                    ownerName: "Different Display", ownerPersonId: person.id)
        XCTAssertTrue(decision.belongsTo(person: person),
                      "A resolved ownerPersonId match wins even when the display name differs.")
    }

    func testBelongsToRejectsUnrelatedPerson() {
        let person = Person.make(canonicalName: "Nobody Here")
        let decision = makeDecision(title: "Ship v2", status: .active,
                                    ownerName: "Parker", involved: ["Jordan"])
        XCTAssertFalse(decision.belongsTo(person: person))
    }

    // MARK: - KB markdown

    @MainActor
    func testKBMarkdownContainsConfirmedDecisionsSection() {
        let meeting = SampleData.makeMeeting(id: "m-recall", title: "Quarterly Planning",
                                             startDate: SampleData.fixedDate)
        let decision = makeDecision(title: "Adopt the new pricing model", status: .active,
                                    ownerName: "Jordan", rationale: "Margins were too thin.")
        let md = KBWriteBackService.shared.buildMarkdown(
            meeting: meeting, summary: "Discussed pricing.", cleanedText: "", decisions: [decision])

        XCTAssertTrue(md.contains("## Decisions"), "The section header must appear.")
        XCTAssertTrue(md.contains("Adopt the new pricing model"), "The decision statement must appear.")
        XCTAssertTrue(md.contains("decided by Jordan"), "The owner must appear.")
        XCTAssertTrue(md.contains("Margins were too thin."), "The rationale must appear.")
    }

    @MainActor
    func testKBMarkdownOmitsDecisionsSectionWhenEmpty() {
        let meeting = SampleData.makeMeeting(id: "m-recall")
        let md = KBWriteBackService.shared.buildMarkdown(
            meeting: meeting, summary: "No decisions here.", cleanedText: "", decisions: [])
        XCTAssertFalse(md.contains("## Decisions"),
                       "No section when there are no confirmed decisions.")
    }

    // MARK: - Prep loop includes suggested

    func testPrepQueryIncludesSuggestedAndConfirmedButNotDismissed() async throws {
        let db = try TestDatabase.create()
        var meeting = SampleData.makeMeeting(id: "m-recall")
        try await db.writer.write { dbc in try meeting.save(dbc) }
        let repo = DecisionRepository(database: db)

        try await db.writer.write { dbc in
            var confirmed = self.makeDecision(title: "Confirmed one", status: .active)
            var suggested = self.makeDecision(title: "Suggested one", status: .suggested)
            var dismissed = self.makeDecision(title: "Dismissed one", status: .dismissed)
            try confirmed.insert(dbc); try suggested.insert(dbc); try dismissed.insert(dbc)
        }

        // The exact query buildSeriesOpenLoops uses (confirmedOnly:false).
        let rows = try await repo.decisionsForMeetings(["m-recall"], confirmedOnly: false, limit: 5)
        let titles = Set(rows.map(\.title))
        XCTAssertTrue(titles.contains("Confirmed one"))
        XCTAssertTrue(titles.contains("Suggested one"), "Prep must surface untriaged suggestions.")
        XCTAssertFalse(titles.contains("Dismissed one"), "Dismissed rows never surface in prep.")
    }
}

import XCTest
@testable import MeetingManager

/// Pure-logic tests for the runtime company derivation (TASK-022, ADR-014).
final class CompanyGroupingServiceTests: XCTestCase {

    private func meeting(_ id: String, _ participants: String, day: Double) -> Meeting {
        let date = Date(timeIntervalSinceReferenceDate: 700_000_000 + day * 86_400)
        var m = SampleData.makeMeeting(id: id, startDate: date, scheduledStartDate: date, status: .complete)
        m.participants = participants
        return m
    }

    func testGroupsByDomainWithPersonalBucketAndMeetingDedup() {
        let alice = Person.make(canonicalName: "Alice", aliases: ["alice@acme.com"])
        let bob   = Person.make(canonicalName: "Bob",   aliases: ["bob@acme.com"])
        let carol = Person.make(canonicalName: "Carol", aliases: ["carol@globex.io"])
        let dave  = Person.make(canonicalName: "Dave",  aliases: ["dave@gmail.com"]) // consumer → personal
        let eve   = Person.make(canonicalName: "Eve")                                 // no email → personal

        let meetings = [
            meeting("m1", "Alice, Bob", day: 1), // both at acme — must count once for acme
            meeting("m2", "Alice",      day: 2),
            meeting("m3", "Carol",      day: 3)  // most recent
        ]

        let companies = CompanyGroupingService.companies(
            from: [alice, bob, carol, dave, eve],
            meetings: meetings
        )

        // acme + globex + one personal bucket
        XCTAssertEqual(companies.count, 3)

        // Sorted most-recently-met first: globex (day 3), then acme (day 2)
        XCTAssertEqual(companies[0].id, "globex.io")
        XCTAssertEqual(companies[1].id, "acme.com")

        // Personal bucket always last, holds the gmail + no-email people, zero meetings
        XCTAssertTrue(companies.last?.isPersonalBucket == true)
        XCTAssertEqual(companies.last?.people.count, 2)
        XCTAssertEqual(companies.last?.meetingCount, 0)

        let acme = try! XCTUnwrap(companies.first { $0.id == "acme.com" })
        XCTAssertEqual(acme.people.count, 2)
        // m1 (Alice+Bob) counts once + m2 (Alice) → 2 distinct meetings, not 3
        XCTAssertEqual(acme.meetingCount, 2)
        XCTAssertEqual(acme.displayName, "Acme")

        let globex = try! XCTUnwrap(companies.first { $0.id == "globex.io" })
        XCTAssertEqual(globex.meetingCount, 1)
    }

    func testDisplayNameAndConsumerDomainHelpers() {
        // Mirrors Person.orgHint: first letter uppercased only.
        XCTAssertEqual(CompanyGroupingService.displayName(forDomain: "acme.com"), "Acme")
        XCTAssertEqual(CompanyGroupingService.displayName(forDomain: "acme.com"), "Acme")
        XCTAssertTrue(CompanyGroupingService.isConsumerDomain("gmail.com"))
        XCTAssertTrue(CompanyGroupingService.isConsumerDomain("ICLOUD.COM"))
        XCTAssertFalse(CompanyGroupingService.isConsumerDomain("acme.com"))
    }

    func testEmptyInputProducesNoCompanies() {
        XCTAssertTrue(CompanyGroupingService.companies(from: [], meetings: []).isEmpty)
    }
}

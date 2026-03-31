import XCTest
import GRDB
@testable import MeetingManager

final class RecipeResultRepositoryTests: XCTestCase {

    private var db: AppDatabase!
    private var repo: RecipeResultRepository!
    private let meetingId = "meeting-rr"
    private let recipeId = "builtin-follow-up-email" // Seeded by migration

    override func setUpWithError() throws {
        db = try TestDatabase.create()
        repo = RecipeResultRepository(database: db)

        var meeting = SampleData.makeMeeting(id: meetingId)
        try db.writer.write { dbConn in try meeting.save(dbConn) }
    }

    // MARK: - Save

    func testSave() async throws {
        var result = SampleData.makeRecipeResult(meetingId: meetingId, recipeId: recipeId)
        try await repo.save(&result)

        XCTAssertNotNil(result.id)
    }

    // MARK: - Results For Meeting

    func testResultsForMeeting() async throws {
        let baseDate = SampleData.fixedDate
        var r1 = SampleData.makeRecipeResult(
            meetingId: meetingId, recipeId: recipeId,
            outputText: "Result 1", generatedAt: baseDate
        )
        var r2 = SampleData.makeRecipeResult(
            meetingId: meetingId, recipeId: recipeId,
            outputText: "Result 2", generatedAt: baseDate.addingTimeInterval(60)
        )

        try await repo.save(&r1)
        try await repo.save(&r2)

        let results = try await repo.resultsForMeeting(meetingId)
        XCTAssertEqual(results.count, 2)
        // Ordered by generatedAt descending
        XCTAssertEqual(results.first?.outputText, "Result 2")
    }

    func testResultsForMeetingEmpty() async throws {
        let results = try await repo.resultsForMeeting("nonexistent")
        XCTAssertTrue(results.isEmpty)
    }

    // MARK: - Latest Result

    func testLatestResult() async throws {
        let baseDate = SampleData.fixedDate
        var r1 = SampleData.makeRecipeResult(
            meetingId: meetingId, recipeId: recipeId,
            outputText: "Older", generatedAt: baseDate
        )
        var r2 = SampleData.makeRecipeResult(
            meetingId: meetingId, recipeId: recipeId,
            outputText: "Newest", generatedAt: baseDate.addingTimeInterval(120)
        )

        try await repo.save(&r1)
        try await repo.save(&r2)

        let latest = try await repo.latestResult(meetingId: meetingId, recipeId: recipeId)
        XCTAssertNotNil(latest)
        XCTAssertEqual(latest?.outputText, "Newest")
    }

    func testLatestResultNilWhenNone() async throws {
        let latest = try await repo.latestResult(meetingId: meetingId, recipeId: "nonexistent-recipe")
        XCTAssertNil(latest)
    }

    func testLatestResultFiltersbyRecipeId() async throws {
        let otherRecipeId = "builtin-action-items"
        var r1 = SampleData.makeRecipeResult(
            meetingId: meetingId, recipeId: recipeId,
            outputText: "Email result"
        )
        var r2 = SampleData.makeRecipeResult(
            meetingId: meetingId, recipeId: otherRecipeId,
            outputText: "Action items result"
        )

        try await repo.save(&r1)
        try await repo.save(&r2)

        let latest = try await repo.latestResult(meetingId: meetingId, recipeId: recipeId)
        XCTAssertEqual(latest?.outputText, "Email result")
    }

    // MARK: - Delete

    func testDelete() async throws {
        var result = SampleData.makeRecipeResult(meetingId: meetingId, recipeId: recipeId)
        try await repo.save(&result)

        try await repo.delete(result)

        let results = try await repo.resultsForMeeting(meetingId)
        XCTAssertTrue(results.isEmpty)
    }
}

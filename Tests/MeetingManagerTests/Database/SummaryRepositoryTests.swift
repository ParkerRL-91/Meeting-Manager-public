import XCTest
import GRDB
@testable import MeetingManager

final class SummaryRepositoryTests: XCTestCase {

    private var db: AppDatabase!
    private var repo: SummaryRepository!
    private let meetingId = "meeting-sum"

    override func setUpWithError() throws {
        db = try TestDatabase.create()
        repo = SummaryRepository(database: db)

        var meeting = SampleData.makeMeeting(id: meetingId)
        try db.writer.write { dbConn in try meeting.save(dbConn) }
    }

    // MARK: - Save

    func testSave() async throws {
        var summary = SampleData.makeMeetingSummary(meetingId: meetingId)
        try await repo.save(&summary)

        XCTAssertNotNil(summary.id)
    }

    // MARK: - Latest Summary

    func testLatestSummary() async throws {
        let baseDate = SampleData.fixedDate
        var s1 = SampleData.makeMeetingSummary(
            meetingId: meetingId,
            summaryText: "Old summary",
            generatedAt: baseDate
        )
        var s2 = SampleData.makeMeetingSummary(
            meetingId: meetingId,
            summaryText: "New summary",
            generatedAt: baseDate.addingTimeInterval(300)
        )

        try await repo.save(&s1)
        try await repo.save(&s2)

        let latest = try await repo.latestSummary(meetingId: meetingId)
        XCTAssertNotNil(latest)
        XCTAssertEqual(latest?.summaryText, "New summary")
    }

    func testLatestSummaryNilWhenNone() async throws {
        let latest = try await repo.latestSummary(meetingId: "empty")
        XCTAssertNil(latest)
    }

    // MARK: - All Summaries

    func testAllSummariesOrderedByGeneratedAtDesc() async throws {
        let baseDate = SampleData.fixedDate
        var s1 = SampleData.makeMeetingSummary(
            meetingId: meetingId,
            summaryText: "First",
            generatedAt: baseDate
        )
        var s2 = SampleData.makeMeetingSummary(
            meetingId: meetingId,
            summaryText: "Second",
            generatedAt: baseDate.addingTimeInterval(100)
        )
        var s3 = SampleData.makeMeetingSummary(
            meetingId: meetingId,
            summaryText: "Third",
            generatedAt: baseDate.addingTimeInterval(200)
        )

        try await repo.save(&s1)
        try await repo.save(&s2)
        try await repo.save(&s3)

        let all = try await repo.allSummaries(meetingId: meetingId)
        XCTAssertEqual(all.count, 3)
        // Ordered descending by generatedAt
        XCTAssertEqual(all.map(\.summaryText), ["Third", "Second", "First"])
    }

    func testAllSummariesEmptyForNoData() async throws {
        let all = try await repo.allSummaries(meetingId: "nonexistent")
        XCTAssertTrue(all.isEmpty)
    }

    // MARK: - Update

    func testUpdate() async throws {
        var summary = SampleData.makeMeetingSummary(
            meetingId: meetingId,
            summaryText: "Original"
        )
        try await repo.save(&summary)

        summary.summaryText = "Edited"
        summary.isEdited = true
        try await repo.update(summary)

        let fetched = try await repo.latestSummary(meetingId: meetingId)
        XCTAssertEqual(fetched?.summaryText, "Edited")
        XCTAssertTrue(fetched!.isEdited)
    }

    // MARK: - Delete

    func testDelete() async throws {
        var summary = SampleData.makeMeetingSummary(meetingId: meetingId)
        try await repo.save(&summary)

        try await repo.delete(summary)

        let all = try await repo.allSummaries(meetingId: meetingId)
        XCTAssertTrue(all.isEmpty)
    }
}

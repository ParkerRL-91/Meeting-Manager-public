import XCTest
import GRDB
@testable import MeetingManager

final class ActionItemRepositoryTests: XCTestCase {

    private var db: AppDatabase!
    private var repo: ActionItemRepository!
    private let meetingId = "meeting-ai"

    override func setUpWithError() throws {
        db = try TestDatabase.create()
        repo = ActionItemRepository(database: db)

        var meeting = SampleData.makeMeeting(id: meetingId)
        try db.writer.write { dbConn in try meeting.save(dbConn) }
    }

    // MARK: - Save

    func testSave() async throws {
        var item = SampleData.makeActionItem(meetingId: meetingId, title: "Task 1")
        try await repo.save(&item)

        XCTAssertNotNil(item.id)
    }

    // MARK: - Save Batch

    func testSaveBatch() async throws {
        let items = [
            SampleData.makeActionItem(meetingId: meetingId, title: "Task A"),
            SampleData.makeActionItem(meetingId: meetingId, title: "Task B"),
            SampleData.makeActionItem(meetingId: meetingId, title: "Task C"),
        ]

        try await repo.saveBatch(items)

        let fetched = try await repo.itemsForMeeting(meetingId)
        XCTAssertEqual(fetched.count, 3)
    }

    // MARK: - Items For Meeting

    func testItemsForMeeting() async throws {
        let baseDate = SampleData.fixedDate
        let items = [
            SampleData.makeActionItem(meetingId: meetingId, title: "Second", extractedAt: baseDate.addingTimeInterval(60)),
            SampleData.makeActionItem(meetingId: meetingId, title: "First", extractedAt: baseDate),
        ]
        try await repo.saveBatch(items)

        let fetched = try await repo.itemsForMeeting(meetingId)
        XCTAssertEqual(fetched.count, 2)
        // Ordered by extractedAt ascending
        XCTAssertEqual(fetched.first?.title, "First")
        XCTAssertEqual(fetched.last?.title, "Second")
    }

    func testItemsForMeetingEmpty() async throws {
        let items = try await repo.itemsForMeeting("nonexistent")
        XCTAssertTrue(items.isEmpty)
    }

    // MARK: - All Open Items

    func testAllOpenItemsExcludesCompleted() async throws {
        var open1 = SampleData.makeActionItem(meetingId: meetingId, title: "Open 1", isCompleted: false)
        var open2 = SampleData.makeActionItem(meetingId: meetingId, title: "Open 2", isCompleted: false)
        var done = SampleData.makeActionItem(meetingId: meetingId, title: "Done", isCompleted: true)

        try await repo.save(&open1)
        try await repo.save(&open2)
        try await repo.save(&done)

        let openItems = try await repo.allOpenItems()
        XCTAssertEqual(openItems.count, 2)
        XCTAssertTrue(openItems.allSatisfy { !$0.isCompleted })
    }

    func testAllOpenItemsAcrossMultipleMeetings() async throws {
        var meeting2 = SampleData.makeMeeting(id: "meeting-ai-2")
        try await db.writer.write { dbConn in try meeting2.save(dbConn) }

        var item1 = SampleData.makeActionItem(meetingId: meetingId, title: "Item 1")
        var item2 = SampleData.makeActionItem(meetingId: "meeting-ai-2", title: "Item 2")

        try await repo.save(&item1)
        try await repo.save(&item2)

        let open = try await repo.allOpenItems()
        XCTAssertEqual(open.count, 2)
    }

    // MARK: - Toggle Complete

    func testToggleCompleteFromFalseToTrue() async throws {
        var item = SampleData.makeActionItem(meetingId: meetingId, title: "Toggle me", isCompleted: false)
        try await repo.save(&item)

        try await repo.toggleComplete(id: item.id!)

        let fetched = try await db.writer.read { dbConn in
            try ActionItem.fetchOne(dbConn, key: item.id!)
        }
        XCTAssertTrue(fetched!.isCompleted)
    }

    func testToggleCompleteTwiceReturnsToOriginal() async throws {
        var item = SampleData.makeActionItem(meetingId: meetingId, title: "Toggle twice", isCompleted: false)
        try await repo.save(&item)

        try await repo.toggleComplete(id: item.id!)
        try await repo.toggleComplete(id: item.id!)

        let fetched = try await db.writer.read { dbConn in
            try ActionItem.fetchOne(dbConn, key: item.id!)
        }
        XCTAssertFalse(fetched!.isCompleted)
    }

    // MARK: - Delete

    func testDelete() async throws {
        var item = SampleData.makeActionItem(meetingId: meetingId, title: "To delete")
        try await repo.save(&item)

        try await repo.delete(item)

        let items = try await repo.itemsForMeeting(meetingId)
        XCTAssertTrue(items.isEmpty)
    }
}

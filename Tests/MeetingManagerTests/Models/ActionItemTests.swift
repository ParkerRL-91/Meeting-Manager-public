import XCTest
import GRDB
@testable import MeetingManager

final class ActionItemTests: XCTestCase {

    // MARK: - Table Name

    func testDatabaseTableName() {
        XCTAssertEqual(TaskItem.databaseTableName, "actionItem")
    }

    // MARK: - Default Values

    func testDefaultIsCompletedFalse() {
        let item = TaskItem(meetingId: "m1", title: "Do something")
        XCTAssertFalse(item.isCompleted)
    }

    func testDefaultIdIsNil() {
        let item = TaskItem(meetingId: "m1", title: "Do something")
        XCTAssertNil(item.id)
    }

    func testDefaultAssigneeIsNil() {
        let item = TaskItem(meetingId: "m1", title: "Do something")
        XCTAssertNil(item.assignee)
    }

    func testDefaultDueDateIsNil() {
        let item = TaskItem(meetingId: "m1", title: "Do something")
        XCTAssertNil(item.dueDate)
    }

    // MARK: - Save with Optional Fields

    func testSaveWithAllOptionalFields() throws {
        let db = try TestDatabase.create()

        var meeting = SampleData.makeMeeting()
        try db.writer.write { dbConn in try meeting.save(dbConn) }

        let dueDate = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var item = SampleData.makeActionItem(
            meetingId: meeting.id,
            assignee: "Bob",
            dueDate: dueDate
        )
        try db.writer.write { dbConn in try item.save(dbConn) }

        XCTAssertNotNil(item.id)

        let fetched = try db.writer.read { dbConn in
            try TaskItem.fetchOne(dbConn, key: item.id!)
        }

        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.assignee, "Bob")
        XCTAssertNotNil(fetched?.dueDate)
        XCTAssertFalse(fetched!.isCompleted)
    }

    func testSaveWithoutOptionalFields() throws {
        let db = try TestDatabase.create()

        var meeting = SampleData.makeMeeting()
        try db.writer.write { dbConn in try meeting.save(dbConn) }

        var item = TaskItem(meetingId: meeting.id, title: "No optional fields")
        try db.writer.write { dbConn in try item.save(dbConn) }

        let fetched = try db.writer.read { dbConn in
            try TaskItem.fetchOne(dbConn, key: item.id!)
        }

        XCTAssertNotNil(fetched)
        XCTAssertNil(fetched?.assignee)
        XCTAssertNil(fetched?.dueDate)
    }

    // MARK: - Codable Roundtrip

    func testCodableRoundtrip() throws {
        let original = SampleData.makeActionItem(
            id: 7,
            assignee: "Charlie",
            dueDate: Date(timeIntervalSinceReferenceDate: 800_000_000),
            isCompleted: true
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSinceReferenceDate
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSinceReferenceDate
        let decoded = try decoder.decode(TaskItem.self, from: data)

        XCTAssertEqual(original, decoded)
    }

    // MARK: - didInsert assigns ID

    func testDidInsertAssignsId() throws {
        let db = try TestDatabase.create()
        var meeting = SampleData.makeMeeting()
        try db.writer.write { dbConn in try meeting.save(dbConn) }

        var item = TaskItem(meetingId: meeting.id, title: "Test")
        XCTAssertNil(item.id)

        try db.writer.write { dbConn in try item.save(dbConn) }
        XCTAssertNotNil(item.id)
        XCTAssertTrue(item.id! > 0)
    }
}

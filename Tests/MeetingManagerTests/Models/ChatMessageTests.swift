import XCTest
import GRDB
@testable import MeetingManager

final class ChatMessageTests: XCTestCase {

    // MARK: - Table Name

    func testDatabaseTableName() {
        XCTAssertEqual(ChatMessage.databaseTableName, "chatMessage")
    }

    // MARK: - Computed Properties

    func testIsUserTrue() {
        let msg = SampleData.makeChatMessage(role: "user")
        XCTAssertTrue(msg.isUser)
        XCTAssertFalse(msg.isAssistant)
    }

    func testIsAssistantTrue() {
        let msg = SampleData.makeChatMessage(role: "assistant")
        XCTAssertTrue(msg.isAssistant)
        XCTAssertFalse(msg.isUser)
    }

    func testNeitherUserNorAssistant() {
        let msg = SampleData.makeChatMessage(role: "system")
        XCTAssertFalse(msg.isUser)
        XCTAssertFalse(msg.isAssistant)
    }

    // MARK: - GRDB Roundtrip

    func testSaveAndFetch() throws {
        let db = try TestDatabase.create()

        var meeting = SampleData.makeMeeting()
        try db.writer.write { dbConn in try meeting.save(dbConn) }

        var msg = SampleData.makeChatMessage(meetingId: meeting.id, role: "user", content: "Hello!")
        try db.writer.write { dbConn in try msg.save(dbConn) }

        XCTAssertNotNil(msg.id)

        let fetched = try db.writer.read { dbConn in
            try ChatMessage.fetchOne(dbConn, key: msg.id!)
        }

        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.role, "user")
        XCTAssertEqual(fetched?.content, "Hello!")
        XCTAssertEqual(fetched?.meetingId, meeting.id)
    }

    // MARK: - didInsert assigns ID

    func testDidInsertAssignsId() throws {
        let db = try TestDatabase.create()
        var meeting = SampleData.makeMeeting()
        try db.writer.write { dbConn in try meeting.save(dbConn) }

        var msg = ChatMessage(meetingId: meeting.id, role: "assistant", content: "Hi")
        XCTAssertNil(msg.id)

        try db.writer.write { dbConn in try msg.save(dbConn) }
        XCTAssertNotNil(msg.id)
    }

    // MARK: - Codable Roundtrip

    func testCodableRoundtrip() throws {
        let original = SampleData.makeChatMessage(id: 10, role: "assistant", content: "Here is your summary")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSinceReferenceDate
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSinceReferenceDate
        let decoded = try decoder.decode(ChatMessage.self, from: data)

        XCTAssertEqual(original, decoded)
    }
}

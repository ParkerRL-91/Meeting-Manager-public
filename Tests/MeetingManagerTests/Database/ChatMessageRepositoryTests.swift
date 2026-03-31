import XCTest
import GRDB
@testable import MeetingManager

final class ChatMessageRepositoryTests: XCTestCase {

    private var db: AppDatabase!
    private var repo: ChatMessageRepository!
    private let meetingId = "meeting-chat"

    override func setUpWithError() throws {
        db = try TestDatabase.create()
        repo = ChatMessageRepository(database: db)

        var meeting = SampleData.makeMeeting(id: meetingId)
        try db.writer.write { dbConn in try meeting.save(dbConn) }
    }

    // MARK: - Save

    func testSave() async throws {
        var msg = SampleData.makeChatMessage(meetingId: meetingId, role: "user", content: "Hello")
        try await repo.save(&msg)

        XCTAssertNotNil(msg.id)
    }

    // MARK: - Messages For Meeting

    func testMessagesForMeetingOrderedByCreatedAt() async throws {
        let baseDate = SampleData.fixedDate
        var m1 = SampleData.makeChatMessage(meetingId: meetingId, role: "user", content: "First", createdAt: baseDate)
        var m2 = SampleData.makeChatMessage(meetingId: meetingId, role: "assistant", content: "Second", createdAt: baseDate.addingTimeInterval(10))

        try await repo.save(&m1)
        try await repo.save(&m2)

        let messages = try await repo.messagesForMeeting(meetingId)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages.first?.content, "First")
        XCTAssertEqual(messages.last?.content, "Second")
    }

    func testMessagesForMeetingEmpty() async throws {
        let messages = try await repo.messagesForMeeting("nonexistent")
        XCTAssertTrue(messages.isEmpty)
    }

    func testMessagesAreIsolatedByMeeting() async throws {
        var meeting2 = SampleData.makeMeeting(id: "meeting-chat-2")
        try db.writer.write { dbConn in try meeting2.save(dbConn) }

        var msg1 = SampleData.makeChatMessage(meetingId: meetingId, content: "For meeting 1")
        var msg2 = SampleData.makeChatMessage(meetingId: "meeting-chat-2", content: "For meeting 2")

        try await repo.save(&msg1)
        try await repo.save(&msg2)

        let m1Messages = try await repo.messagesForMeeting(meetingId)
        let m2Messages = try await repo.messagesForMeeting("meeting-chat-2")

        XCTAssertEqual(m1Messages.count, 1)
        XCTAssertEqual(m2Messages.count, 1)
        XCTAssertEqual(m1Messages.first?.content, "For meeting 1")
    }

    // MARK: - Clear For Meeting

    func testClearForMeeting() async throws {
        var msg1 = SampleData.makeChatMessage(meetingId: meetingId, content: "A")
        var msg2 = SampleData.makeChatMessage(meetingId: meetingId, content: "B")
        try await repo.save(&msg1)
        try await repo.save(&msg2)

        try await repo.clearForMeeting(meetingId)

        let remaining = try await repo.messagesForMeeting(meetingId)
        XCTAssertTrue(remaining.isEmpty)
    }

    func testClearForMeetingDoesNotAffectOtherMeetings() async throws {
        var meeting2 = SampleData.makeMeeting(id: "meeting-chat-other")
        try db.writer.write { dbConn in try meeting2.save(dbConn) }

        var msg1 = SampleData.makeChatMessage(meetingId: meetingId, content: "To clear")
        var msg2 = SampleData.makeChatMessage(meetingId: "meeting-chat-other", content: "Keep this")
        try await repo.save(&msg1)
        try await repo.save(&msg2)

        try await repo.clearForMeeting(meetingId)

        let kept = try await repo.messagesForMeeting("meeting-chat-other")
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept.first?.content, "Keep this")
    }
}

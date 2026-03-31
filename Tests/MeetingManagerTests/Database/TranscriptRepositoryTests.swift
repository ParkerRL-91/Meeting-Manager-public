import XCTest
import GRDB
@testable import MeetingManager

final class TranscriptRepositoryTests: XCTestCase {

    private var db: AppDatabase!
    private var repo: TranscriptRepository!
    private let meetingId = "meeting-tr"

    override func setUpWithError() throws {
        db = try TestDatabase.create()
        repo = TranscriptRepository(database: db)

        // Insert parent meeting
        var meeting = SampleData.makeMeeting(id: meetingId)
        try db.writer.write { dbConn in try meeting.save(dbConn) }
    }

    // MARK: - Save

    func testSave() async throws {
        var transcript = SampleData.makeTranscript(meetingId: meetingId, text: "First segment")
        try await repo.save(&transcript)

        XCTAssertNotNil(transcript.id)

        let results = try await repo.transcriptsForMeeting(meetingId)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.text, "First segment")
    }

    // MARK: - Save Batch

    func testSaveBatch() async throws {
        let transcripts = [
            SampleData.makeTranscript(meetingId: meetingId, text: "A", startTime: 0, endTime: 5),
            SampleData.makeTranscript(meetingId: meetingId, text: "B", startTime: 5, endTime: 10),
            SampleData.makeTranscript(meetingId: meetingId, text: "C", startTime: 10, endTime: 15),
        ]

        try await repo.saveBatch(transcripts)

        let results = try await repo.transcriptsForMeeting(meetingId)
        XCTAssertEqual(results.count, 3)
    }

    // MARK: - Transcripts For Meeting

    func testTranscriptsForMeetingOrderedByStartTime() async throws {
        let transcripts = [
            SampleData.makeTranscript(meetingId: meetingId, text: "Second", startTime: 10, endTime: 15),
            SampleData.makeTranscript(meetingId: meetingId, text: "First", startTime: 0, endTime: 5),
            SampleData.makeTranscript(meetingId: meetingId, text: "Third", startTime: 20, endTime: 25),
        ]
        try await repo.saveBatch(transcripts)

        let results = try await repo.transcriptsForMeeting(meetingId)
        XCTAssertEqual(results.map(\.text), ["First", "Second", "Third"])
    }

    func testTranscriptsForMeetingReturnsEmpty() async throws {
        let results = try await repo.transcriptsForMeeting("nonexistent")
        XCTAssertTrue(results.isEmpty)
    }

    // MARK: - Full Text

    func testFullTextConcatenation() async throws {
        let transcripts = [
            SampleData.makeTranscript(meetingId: meetingId, speakerLabel: "mic", text: "Hello", startTime: 0, endTime: 5),
            SampleData.makeTranscript(meetingId: meetingId, speakerLabel: "system", text: "Hi there", startTime: 5, endTime: 10),
        ]
        try await repo.saveBatch(transcripts)

        let fullText = try await repo.fullText(meetingId: meetingId)

        XCTAssertTrue(fullText.contains("[00:00] You: Hello"))
        XCTAssertTrue(fullText.contains("[00:05] Them: Hi there"))
    }

    func testFullTextEmptyForNoTranscripts() async throws {
        let fullText = try await repo.fullText(meetingId: "empty-meeting")
        XCTAssertTrue(fullText.isEmpty)
    }

    // MARK: - Search

    func testSearchByQuery() async throws {
        let transcripts = [
            SampleData.makeTranscript(meetingId: meetingId, text: "We need to discuss the budget", startTime: 0, endTime: 5),
            SampleData.makeTranscript(meetingId: meetingId, text: "The timeline looks good", startTime: 5, endTime: 10),
            SampleData.makeTranscript(meetingId: meetingId, text: "Budget approval is pending", startTime: 10, endTime: 15),
        ]
        try await repo.saveBatch(transcripts)

        let results = try await repo.search(meetingId: meetingId, query: "budget")
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.allSatisfy { $0.text.lowercased().contains("budget") })
    }

    func testSearchReturnsEmptyForNoMatch() async throws {
        var transcript = SampleData.makeTranscript(meetingId: meetingId, text: "Hello world")
        try await repo.save(&transcript)

        let results = try await repo.search(meetingId: meetingId, query: "zzzzz")
        XCTAssertTrue(results.isEmpty)
    }

    // MARK: - Delete For Meeting

    func testDeleteForMeeting() async throws {
        let transcripts = [
            SampleData.makeTranscript(meetingId: meetingId, text: "A", startTime: 0, endTime: 5),
            SampleData.makeTranscript(meetingId: meetingId, text: "B", startTime: 5, endTime: 10),
        ]
        try await repo.saveBatch(transcripts)

        // Also insert a transcript for a different meeting
        var otherMeeting = SampleData.makeMeeting(id: "other-meeting")
        try db.writer.write { dbConn in try otherMeeting.save(dbConn) }
        var otherTranscript = SampleData.makeTranscript(meetingId: "other-meeting", text: "Other")
        try await repo.save(&otherTranscript)

        try await repo.deleteForMeeting(meetingId)

        let remaining = try await repo.transcriptsForMeeting(meetingId)
        XCTAssertTrue(remaining.isEmpty)

        // Other meeting's transcripts should be untouched
        let otherRemaining = try await repo.transcriptsForMeeting("other-meeting")
        XCTAssertEqual(otherRemaining.count, 1)
    }
}

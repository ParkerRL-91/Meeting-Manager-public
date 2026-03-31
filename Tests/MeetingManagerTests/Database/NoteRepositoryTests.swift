import XCTest
import GRDB
@testable import MeetingManager

final class NoteRepositoryTests: XCTestCase {

    private var db: AppDatabase!
    private var repo: NoteRepository!
    private let meetingId = "meeting-notes"

    override func setUpWithError() throws {
        db = try TestDatabase.create()
        repo = NoteRepository(database: db)

        var meeting = SampleData.makeMeeting(id: meetingId)
        try db.writer.write { dbConn in try meeting.save(dbConn) }
    }

    // MARK: - Save

    func testSave() async throws {
        var note = SampleData.makeMeetingNote(meetingId: meetingId, content: "Note 1")
        try await repo.save(&note)

        XCTAssertNotNil(note.id)
    }

    // MARK: - Notes For Meeting

    func testNotesForMeeting() async throws {
        let baseDate = SampleData.fixedDate
        var n1 = SampleData.makeMeetingNote(meetingId: meetingId, content: "First", createdAt: baseDate)
        var n2 = SampleData.makeMeetingNote(meetingId: meetingId, content: "Second", createdAt: baseDate.addingTimeInterval(60))

        try await repo.save(&n1)
        try await repo.save(&n2)

        let notes = try await repo.notesForMeeting(meetingId)
        XCTAssertEqual(notes.count, 2)
        // Should be ordered by createdAt ascending
        XCTAssertEqual(notes.first?.content, "First")
        XCTAssertEqual(notes.last?.content, "Second")
    }

    func testNotesForMeetingEmpty() async throws {
        let notes = try await repo.notesForMeeting("nonexistent")
        XCTAssertTrue(notes.isEmpty)
    }

    // MARK: - Latest Note

    func testLatestNote() async throws {
        let baseDate = SampleData.fixedDate
        var n1 = SampleData.makeMeetingNote(meetingId: meetingId, content: "Old note", createdAt: baseDate)
        var n2 = SampleData.makeMeetingNote(meetingId: meetingId, content: "Latest note", createdAt: baseDate.addingTimeInterval(120))

        try await repo.save(&n1)
        try await repo.save(&n2)

        let latest = try await repo.latestNote(meetingId: meetingId)
        XCTAssertNotNil(latest)
        XCTAssertEqual(latest?.content, "Latest note")
    }

    func testLatestNoteNilWhenNoNotes() async throws {
        let latest = try await repo.latestNote(meetingId: "empty-meeting")
        XCTAssertNil(latest)
    }

    // MARK: - Combined Notes

    func testCombinedNotes() async throws {
        let baseDate = SampleData.fixedDate
        var n1 = SampleData.makeMeetingNote(meetingId: meetingId, content: "Point A", createdAt: baseDate)
        var n2 = SampleData.makeMeetingNote(meetingId: meetingId, content: "Point B", createdAt: baseDate.addingTimeInterval(60))

        try await repo.save(&n1)
        try await repo.save(&n2)

        let combined = try await repo.combinedNotes(meetingId: meetingId)
        XCTAssertEqual(combined, "Point A\n\nPoint B")
    }

    func testCombinedNotesEmptyString() async throws {
        let combined = try await repo.combinedNotes(meetingId: "empty-meeting")
        XCTAssertTrue(combined.isEmpty)
    }

    // MARK: - Delete

    func testDelete() async throws {
        var note = SampleData.makeMeetingNote(meetingId: meetingId, content: "To delete")
        try await repo.save(&note)

        let notesBefore = try await repo.notesForMeeting(meetingId)
        XCTAssertEqual(notesBefore.count, 1)

        try await repo.delete(note)

        let notesAfter = try await repo.notesForMeeting(meetingId)
        XCTAssertTrue(notesAfter.isEmpty)
    }
}

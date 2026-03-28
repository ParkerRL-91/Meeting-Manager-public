import XCTest
import GRDB
@testable import MeetingManager

final class TranscriptTests: XCTestCase {

    // MARK: - Table Name

    func testDatabaseTableName() {
        XCTAssertEqual(Transcript.databaseTableName, "transcript")
    }

    // MARK: - Computed Properties

    func testIsMicrophoneTrue() {
        let transcript = SampleData.makeTranscript(speakerLabel: "mic")
        XCTAssertTrue(transcript.isMicrophone)
    }

    func testIsMicrophoneFalseForSystem() {
        let transcript = SampleData.makeTranscript(speakerLabel: "system")
        XCTAssertFalse(transcript.isMicrophone)
    }

    func testIsMicrophoneFalseForNil() {
        let transcript = SampleData.makeTranscript(speakerLabel: nil)
        XCTAssertFalse(transcript.isMicrophone)
    }

    func testFormattedTimestampMinutesAndSeconds() {
        let transcript = SampleData.makeTranscript(startTime: 125.0) // 2:05
        XCTAssertEqual(transcript.formattedTimestamp, "02:05")
    }

    func testFormattedTimestampZero() {
        let transcript = SampleData.makeTranscript(startTime: 0.0)
        XCTAssertEqual(transcript.formattedTimestamp, "00:00")
    }

    func testFormattedTimestampLargeValue() {
        let transcript = SampleData.makeTranscript(startTime: 3661.0) // 61:01
        XCTAssertEqual(transcript.formattedTimestamp, "61:01")
    }

    func testSpeakerDisplayNameMic() {
        let transcript = SampleData.makeTranscript(speakerLabel: "mic")
        XCTAssertEqual(transcript.speakerDisplayName, "You")
    }

    func testSpeakerDisplayNameSystem() {
        let transcript = SampleData.makeTranscript(speakerLabel: "system")
        XCTAssertEqual(transcript.speakerDisplayName, "Them")
    }

    func testSpeakerDisplayNameCustom() {
        let transcript = SampleData.makeTranscript(speakerLabel: "Alice")
        XCTAssertEqual(transcript.speakerDisplayName, "Alice")
    }

    func testSpeakerDisplayNameNil() {
        let transcript = SampleData.makeTranscript(speakerLabel: nil)
        XCTAssertEqual(transcript.speakerDisplayName, "Unknown")
    }

    // MARK: - GRDB Roundtrip

    func testSaveAndFetch() throws {
        let db = try TestDatabase.create()

        // Insert parent meeting first (FK constraint)
        var meeting = SampleData.makeMeeting()
        try db.writer.write { dbConn in try meeting.save(dbConn) }

        var transcript = SampleData.makeTranscript(meetingId: meeting.id)
        try db.writer.write { dbConn in try transcript.save(dbConn) }

        XCTAssertNotNil(transcript.id, "ID should be assigned after insert")

        let fetched = try db.writer.read { dbConn in
            try Transcript.fetchOne(dbConn, key: transcript.id!)
        }

        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.text, "Hello everyone")
        XCTAssertEqual(fetched?.meetingId, meeting.id)
        XCTAssertEqual(fetched?.speakerLabel, "mic")
    }

    // MARK: - Codable Roundtrip

    func testCodableRoundtrip() throws {
        let original = SampleData.makeTranscript(
            id: 42,
            speakerLabel: "system",
            text: "We need to discuss the budget",
            startTime: 30.5,
            endTime: 35.2,
            confidence: 0.87
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSinceReferenceDate
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSinceReferenceDate
        let decoded = try decoder.decode(Transcript.self, from: data)

        XCTAssertEqual(original, decoded)
    }
}

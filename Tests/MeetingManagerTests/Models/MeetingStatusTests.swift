import XCTest
@testable import MeetingManager

final class MeetingStatusTests: XCTestCase {

    // MARK: - All Cases Exist

    func testAllCasesCount() {
        XCTAssertEqual(MeetingStatus.allCases.count, 8)
    }

    func testAllCasesPresent() {
        let expected: [MeetingStatus] = [
            .scheduled, .notified, .recording, .transcribing,
            .summarizing, .complete, .cancelled, .archived
        ]
        XCTAssertEqual(MeetingStatus.allCases, expected)
    }

    // MARK: - Raw Values

    func testRawValues() {
        XCTAssertEqual(MeetingStatus.scheduled.rawValue, "scheduled")
        XCTAssertEqual(MeetingStatus.notified.rawValue, "notified")
        XCTAssertEqual(MeetingStatus.recording.rawValue, "recording")
        XCTAssertEqual(MeetingStatus.transcribing.rawValue, "transcribing")
        XCTAssertEqual(MeetingStatus.summarizing.rawValue, "summarizing")
        XCTAssertEqual(MeetingStatus.complete.rawValue, "complete")
        XCTAssertEqual(MeetingStatus.cancelled.rawValue, "cancelled")
        XCTAssertEqual(MeetingStatus.archived.rawValue, "archived")
    }

    // MARK: - Display Name

    func testDisplayNames() {
        XCTAssertEqual(MeetingStatus.scheduled.displayName, "Scheduled")
        XCTAssertEqual(MeetingStatus.notified.displayName, "Starting Soon")
        XCTAssertEqual(MeetingStatus.recording.displayName, "Recording")
        XCTAssertEqual(MeetingStatus.transcribing.displayName, "Transcribing")
        XCTAssertEqual(MeetingStatus.summarizing.displayName, "Summarizing")
        XCTAssertEqual(MeetingStatus.complete.displayName, "Complete")
        XCTAssertEqual(MeetingStatus.cancelled.displayName, "Cancelled")
        XCTAssertEqual(MeetingStatus.archived.displayName, "Archived")
    }

    // MARK: - Icon

    func testIcons() {
        XCTAssertEqual(MeetingStatus.scheduled.icon, "calendar")
        XCTAssertEqual(MeetingStatus.notified.icon, "bell.fill")
        XCTAssertEqual(MeetingStatus.recording.icon, "record.circle")
        XCTAssertEqual(MeetingStatus.transcribing.icon, "text.word.spacing")
        XCTAssertEqual(MeetingStatus.summarizing.icon, "sparkles")
        XCTAssertEqual(MeetingStatus.complete.icon, "checkmark.circle.fill")
        XCTAssertEqual(MeetingStatus.cancelled.icon, "xmark.circle")
        XCTAssertEqual(MeetingStatus.archived.icon, "archivebox")
    }

    // MARK: - isActive

    func testIsActiveForActiveStatuses() {
        XCTAssertTrue(MeetingStatus.recording.isActive)
        XCTAssertTrue(MeetingStatus.transcribing.isActive)
        XCTAssertTrue(MeetingStatus.summarizing.isActive)
    }

    func testIsActiveForInactiveStatuses() {
        XCTAssertFalse(MeetingStatus.scheduled.isActive)
        XCTAssertFalse(MeetingStatus.notified.isActive)
        XCTAssertFalse(MeetingStatus.complete.isActive)
        XCTAssertFalse(MeetingStatus.cancelled.isActive)
        XCTAssertFalse(MeetingStatus.archived.isActive)
    }

    // MARK: - Codable Roundtrip

    func testCodableRoundtrip() throws {
        for status in MeetingStatus.allCases {
            let data = try JSONEncoder().encode(status)
            let decoded = try JSONDecoder().decode(MeetingStatus.self, from: data)
            XCTAssertEqual(decoded, status, "Codable roundtrip failed for \(status)")
        }
    }

    func testDecodingFromRawString() throws {
        let json = Data(#""recording""#.utf8)
        let status = try JSONDecoder().decode(MeetingStatus.self, from: json)
        XCTAssertEqual(status, .recording)
    }
}

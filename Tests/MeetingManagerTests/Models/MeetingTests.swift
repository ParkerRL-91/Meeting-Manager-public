import XCTest
import GRDB
@testable import MeetingManager

final class MeetingTests: XCTestCase {

    // MARK: - Table Name

    func testDatabaseTableName() {
        XCTAssertEqual(Meeting.databaseTableName, "meeting")
    }

    // MARK: - Init Defaults

    func testDefaultValues() {
        let meeting = Meeting(title: "Test")
        XCTAssertEqual(meeting.title, "Test")
        XCTAssertEqual(meeting.status, .scheduled)
        XCTAssertNil(meeting.startDate)
        XCTAssertNil(meeting.endDate)
        XCTAssertNil(meeting.scheduledStartDate)
        XCTAssertNil(meeting.scheduledEndDate)
        XCTAssertNil(meeting.calendarEventId)
        XCTAssertNil(meeting.audioFilePath)
        XCTAssertFalse(meeting.id.isEmpty)
    }

    // MARK: - Computed Properties

    func testDurationWhenBothDatesPresent() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let end = start.addingTimeInterval(3600)
        let meeting = SampleData.makeMeeting(startDate: start, endDate: end)

        XCTAssertEqual(meeting.duration, 3600)
    }

    func testDurationNilWhenStartDateMissing() {
        let meeting = SampleData.makeMeeting(endDate: Date())
        XCTAssertNil(meeting.duration)
    }

    func testDurationNilWhenEndDateMissing() {
        let meeting = SampleData.makeMeeting(startDate: Date())
        XCTAssertNil(meeting.duration)
    }

    func testFormattedDurationMinutesOnly() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let end = start.addingTimeInterval(45 * 60) // 45 min
        let meeting = SampleData.makeMeeting(startDate: start, endDate: end)

        XCTAssertEqual(meeting.formattedDuration, "45 min")
    }

    func testFormattedDurationWithHours() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let end = start.addingTimeInterval(90 * 60) // 1h 30m
        let meeting = SampleData.makeMeeting(startDate: start, endDate: end)

        XCTAssertEqual(meeting.formattedDuration, "1h 30m")
    }

    func testFormattedDurationWhenNil() {
        let meeting = SampleData.makeMeeting()
        XCTAssertEqual(meeting.formattedDuration, "--")
    }

    func testEffectiveDatePrefersScheduledStart() {
        let scheduled = Date(timeIntervalSinceReferenceDate: 1000)
        let actual = Date(timeIntervalSinceReferenceDate: 2000)
        let created = Date(timeIntervalSinceReferenceDate: 500)
        let meeting = SampleData.makeMeeting(
            startDate: actual,
            scheduledStartDate: scheduled,
            createdAt: created
        )

        XCTAssertEqual(meeting.effectiveDate, scheduled)
    }

    func testEffectiveDateFallsBackToStartDate() {
        let actual = Date(timeIntervalSinceReferenceDate: 2000)
        let created = Date(timeIntervalSinceReferenceDate: 500)
        let meeting = SampleData.makeMeeting(
            startDate: actual,
            createdAt: created
        )

        XCTAssertEqual(meeting.effectiveDate, actual)
    }

    func testEffectiveDateFallsBackToCreatedAt() {
        let created = Date(timeIntervalSinceReferenceDate: 500)
        let meeting = SampleData.makeMeeting(createdAt: created)

        XCTAssertEqual(meeting.effectiveDate, created)
    }

    // MARK: - GRDB Roundtrip

    func testSaveAndFetch() throws {
        let db = try TestDatabase.create()
        var meeting = SampleData.makeMeeting(
            id: "test-roundtrip",
            title: "Roundtrip Test",
            status: .recording
        )

        try db.writer.write { dbConn in
            try meeting.save(dbConn)
        }

        let fetched = try db.writer.read { dbConn in
            try Meeting.fetchOne(dbConn, key: "test-roundtrip")
        }

        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.title, "Roundtrip Test")
        XCTAssertEqual(fetched?.status, .recording)
    }

    // MARK: - Codable Roundtrip

    func testCodableRoundtrip() throws {
        let original = SampleData.makeMeeting(
            startDate: Date(timeIntervalSinceReferenceDate: 1000),
            endDate: Date(timeIntervalSinceReferenceDate: 2000),
            scheduledStartDate: Date(timeIntervalSinceReferenceDate: 900),
            status: .complete,
            calendarEventId: "cal-123"
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSinceReferenceDate
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSinceReferenceDate
        let decoded = try decoder.decode(Meeting.self, from: data)

        XCTAssertEqual(original, decoded)
    }

    // MARK: - Equatable

    func testValueEquality() {
        // Dates are pinned via SampleData.fixedDate so field-by-field equality
        // is deterministic and not affected by the wall-clock time of the run.
        let a = SampleData.makeMeeting(id: "same-id", title: "A")
        let b = SampleData.makeMeeting(id: "same-id", title: "A")
        let c = SampleData.makeMeeting(id: "different-id", title: "A")

        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}

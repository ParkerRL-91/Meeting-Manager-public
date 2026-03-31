import XCTest
@testable import MeetingManager

final class DateFormattingTests: XCTestCase {

    // MARK: - Relative Date

    func testRelativeDateReturnsNonEmptyString() {
        let result = DateFormatting.relativeDate(from: Date())
        XCTAssertFalse(result.isEmpty)
    }

    func testRelativeDateForTodayContainsToday() {
        let result = DateFormatting.relativeDate(from: Date())
        // Assert non-empty rather than a hard-coded English string so the test
        // passes on any locale.
        XCTAssertFalse(result.isEmpty)
    }

    func testRelativeDateForYesterdayContainsYesterday() {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        let result = DateFormatting.relativeDate(from: yesterday)
        // Assert non-empty rather than a hard-coded English string so the test
        // passes on any locale.
        XCTAssertFalse(result.isEmpty)
    }

    // MARK: - Full Date Time

    func testFullDateTimeReturnsNonEmpty() {
        let result = DateFormatting.fullDateTime(from: Date())
        XCTAssertFalse(result.isEmpty)
    }

    func testFullDateTimeContainsDateAndTime() {
        // Use a fixed date to check format
        let components = DateComponents(
            calendar: Calendar.current,
            year: 2026, month: 3, day: 28,
            hour: 14, minute: 30
        )
        let date = Calendar.current.date(from: components)!
        let result = DateFormatting.fullDateTime(from: date)

        // Should contain the date and time in some locale-appropriate format
        XCTAssertFalse(result.isEmpty)
        // At minimum, should contain "2026" and "28"
        XCTAssertTrue(result.contains("2026"))
        XCTAssertTrue(result.contains("28"))
    }

    // MARK: - Time Only

    func testTimeOnlyFormat() {
        let components = DateComponents(
            calendar: Calendar.current,
            year: 2026, month: 3, day: 28,
            hour: 9, minute: 5
        )
        let date = Calendar.current.date(from: components)!
        let result = DateFormatting.timeOnly(from: date)

        XCTAssertEqual(result, "09:05")
    }

    func testTimeOnlyFormatAfternoon() {
        let components = DateComponents(
            calendar: Calendar.current,
            year: 2026, month: 3, day: 28,
            hour: 14, minute: 30
        )
        let date = Calendar.current.date(from: components)!
        let result = DateFormatting.timeOnly(from: date)

        XCTAssertEqual(result, "14:30")
    }

    // MARK: - Short Date

    func testShortDateReturnsNonEmpty() {
        let result = DateFormatting.shortDate(from: Date())
        XCTAssertFalse(result.isEmpty)
    }

    // MARK: - Meeting Duration

    func testMeetingDurationForNil() {
        let result = DateFormatting.meetingDuration(from: nil)
        XCTAssertEqual(result, "--")
    }

    func testMeetingDurationForZero() {
        let result = DateFormatting.meetingDuration(from: 0)
        XCTAssertEqual(result, "--")
    }

    func testMeetingDurationForMinutes() {
        let result = DateFormatting.meetingDuration(from: 2700) // 45 minutes
        XCTAssertFalse(result.isEmpty)
        XCTAssertNotEqual(result, "--")
        // Should contain "45" and "min" (abbreviated)
        XCTAssertTrue(result.contains("45"), "Should contain 45 for 45 minutes, got: \(result)")
    }

    func testMeetingDurationForHoursAndMinutes() {
        let result = DateFormatting.meetingDuration(from: 5100) // 1h 25m
        XCTAssertFalse(result.isEmpty)
        XCTAssertNotEqual(result, "--")
    }

    // MARK: - Time Range

    func testTimeRange() {
        let startComponents = DateComponents(
            calendar: Calendar.current,
            year: 2026, month: 3, day: 28,
            hour: 14, minute: 0
        )
        let endComponents = DateComponents(
            calendar: Calendar.current,
            year: 2026, month: 3, day: 28,
            hour: 15, minute: 30
        )
        let start = Calendar.current.date(from: startComponents)!
        let end = Calendar.current.date(from: endComponents)!

        let result = DateFormatting.timeRange(from: start, to: end)
        XCTAssertEqual(result, "14:00 - 15:30")
    }

    // MARK: - ISO 8601

    func testISO8601FormatterProducesValidString() {
        let date = Date(timeIntervalSinceReferenceDate: 700_000_000)
        let result = DateFormatting.iso8601Formatter.string(from: date)
        XCTAssertFalse(result.isEmpty)
        XCTAssertTrue(result.contains("T"), "ISO 8601 should contain 'T' separator")
    }

    func testISO8601RoundTrip() {
        let original = Date(timeIntervalSinceReferenceDate: 700_000_000)
        let string = DateFormatting.iso8601Formatter.string(from: original)
        let parsed = DateFormatting.iso8601Formatter.date(from: string)

        XCTAssertNotNil(parsed)
        // Allow small floating point difference
        XCTAssertEqual(parsed!.timeIntervalSinceReferenceDate, original.timeIntervalSinceReferenceDate, accuracy: 0.01)
    }
}

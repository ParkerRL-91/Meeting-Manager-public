import XCTest
@testable import MeetingManager

/// Tests for NaturalLanguageDateParser (defined in QuickCapturePopoverView.swift).
///
/// QA Round 2, P6 — "next week" was resolving to today+7 instead of the Monday
/// of the following week. Fix: use Calendar.nextDate(after:matching: weekday 2).
final class NaturalLanguageDateParserTests: XCTestCase {

    private let cal = Calendar.current

    // MARK: - Helpers

    private func startOfToday() -> Date {
        cal.startOfDay(for: Date())
    }

    private func daysFromToday(_ date: Date) -> Int {
        cal.dateComponents([.day], from: startOfToday(), to: date).day ?? -999
    }

    private func weekday(of date: Date) -> Int {
        cal.component(.weekday, from: date) // 1=Sun, 2=Mon, ..., 7=Sat
    }

    // MARK: - Basic keywords

    func testTodayReturnsStartOfToday() {
        let result = NaturalLanguageDateParser.parse("today")
        XCTAssertNotNil(result)
        XCTAssertEqual(result, startOfToday())
    }

    func testTodayCaseInsensitive() {
        XCTAssertEqual(NaturalLanguageDateParser.parse("Today"), startOfToday())
        XCTAssertEqual(NaturalLanguageDateParser.parse("TODAY"), startOfToday())
    }

    func testTomorrowIsOneDayAhead() {
        let result = NaturalLanguageDateParser.parse("tomorrow")
        XCTAssertNotNil(result)
        XCTAssertEqual(daysFromToday(result!), 1)
    }

    // MARK: - "next week" regression (QA Round 2, P6)

    func testNextWeekResolvesToMonday() {
        let result = NaturalLanguageDateParser.parse("next week")
        XCTAssertNotNil(result, "next week should return a non-nil date")
        XCTAssertEqual(weekday(of: result!), 2,
            "next week must land on Monday (weekday=2), got weekday=\(weekday(of: result!))")
    }

    func testNextWeekIsNotTodayPlusSeven() {
        // today+7 lands on the same weekday as today, which is only Monday when
        // today is already Monday. On any other day this regression is visible.
        let todayWeekday = weekday(of: Date())
        guard todayWeekday != 2 else { return } // skip: both behaviors coincide on Monday

        let result = NaturalLanguageDateParser.parse("next week")!
        let naivePlusSeven = cal.date(byAdding: .day, value: 7, to: startOfToday())!
        XCTAssertNotEqual(result, naivePlusSeven,
            "next week must not equal today+7 when today is not Monday")
    }

    func testNextWeekFromSundayIsNextDay() {
        // When today is Sunday (weekday=1), next Monday is only 1 day away.
        guard weekday(of: Date()) == 1 else {
            // Still verify it's a Monday regardless of what day it is.
            XCTAssertEqual(weekday(of: NaturalLanguageDateParser.parse("next week")!), 2)
            return
        }
        let result = NaturalLanguageDateParser.parse("next week")!
        XCTAssertEqual(weekday(of: result), 2)
        XCTAssertEqual(daysFromToday(result), 1, "From Sunday, next Monday is 1 day away")
    }

    func testNextWeekFromMondayIsSevenDaysAway() {
        guard weekday(of: Date()) == 2 else {
            XCTAssertEqual(weekday(of: NaturalLanguageDateParser.parse("next week")!), 2)
            return
        }
        let result = NaturalLanguageDateParser.parse("next week")!
        XCTAssertEqual(weekday(of: result), 2)
        XCTAssertEqual(daysFromToday(result), 7, "From Monday, next Monday is 7 days away")
    }

    func testNextWeekFromFridayIsThreeDaysAway() {
        guard weekday(of: Date()) == 6 else {
            XCTAssertEqual(weekday(of: NaturalLanguageDateParser.parse("next week")!), 2)
            return
        }
        let result = NaturalLanguageDateParser.parse("next week")!
        XCTAssertEqual(weekday(of: result), 2)
        XCTAssertEqual(daysFromToday(result), 3, "From Friday, next Monday is 3 days away")
    }

    // MARK: - Weekday names

    func testFridayReturnsUpcomingFriday() {
        let result = NaturalLanguageDateParser.parse("friday")
        XCTAssertNotNil(result)
        XCTAssertEqual(weekday(of: result!), 6)
        XCTAssertGreaterThan(result!, startOfToday().addingTimeInterval(-1))
    }

    func testMondayReturnsUpcomingMonday() {
        let result = NaturalLanguageDateParser.parse("monday")
        XCTAssertNotNil(result)
        XCTAssertEqual(weekday(of: result!), 2)
    }

    func testWeekdayNameCaseInsensitive() {
        let lower = NaturalLanguageDateParser.parse("wednesday")
        let upper = NaturalLanguageDateParser.parse("Wednesday")
        XCTAssertEqual(lower, upper)
    }

    // MARK: - ISO / formatted dates

    func testISODateFormat() {
        let result = NaturalLanguageDateParser.parse("2026-12-25")
        XCTAssertNotNil(result)
        let comps = cal.dateComponents([.year, .month, .day], from: result!)
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 12)
        XCTAssertEqual(comps.day, 25)
    }

    func testAbbreviatedMonthDayFormat() {
        let result = NaturalLanguageDateParser.parse("Apr 20")
        XCTAssertNotNil(result)
        let comps = cal.dateComponents([.month, .day], from: result!)
        XCTAssertEqual(comps.month, 4)
        XCTAssertEqual(comps.day, 20)
    }

    // MARK: - Edge cases / invalid input

    func testEmptyStringReturnsNil() {
        XCTAssertNil(NaturalLanguageDateParser.parse(""))
    }

    func testWhitespaceOnlyReturnsNil() {
        XCTAssertNil(NaturalLanguageDateParser.parse("   "))
    }

    func testNonsenseReturnsNil() {
        XCTAssertNil(NaturalLanguageDateParser.parse("bananas"))
    }
}

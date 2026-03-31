import XCTest
import GRDB
@testable import MeetingManager

final class MeetingRepositoryTests: XCTestCase {

    private var db: AppDatabase!
    private var repo: MeetingRepository!

    override func setUpWithError() throws {
        db = try TestDatabase.create()
        repo = MeetingRepository(database: db)
    }

    // MARK: - Save

    func testSaveAndFind() async throws {
        var meeting = SampleData.makeMeeting(id: "m1", title: "Save Test")
        try await repo.save(&meeting)

        let found = try await repo.find(id: "m1")
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.title, "Save Test")
    }

    // MARK: - Delete

    func testDelete() async throws {
        var meeting = SampleData.makeMeeting(id: "m-del")
        try await repo.save(&meeting)

        try await repo.delete(meeting)

        let found = try await repo.find(id: "m-del")
        XCTAssertNil(found)
    }

    // MARK: - Find

    func testFindNonExistent() async throws {
        let found = try await repo.find(id: "does-not-exist")
        XCTAssertNil(found)
    }

    func testFindByCalendarEventId() async throws {
        var meeting = SampleData.makeMeeting(id: "m-cal", calendarEventId: "cal-abc")
        try await repo.save(&meeting)

        let found = try await repo.findByCalendarEventId("cal-abc")
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.id, "m-cal")
    }

    func testFindByCalendarEventIdNotFound() async throws {
        let found = try await repo.findByCalendarEventId("nonexistent")
        XCTAssertNil(found)
    }

    // MARK: - Upcoming Meetings

    func testUpcomingMeetingsReturnsScheduledNotifiedRecording() async throws {
        let future = Date().addingTimeInterval(3600)

        var m1 = SampleData.makeMeeting(id: "m1", status: .scheduled, scheduledStartDate: future)
        var m2 = SampleData.makeMeeting(id: "m2", status: .notified, scheduledStartDate: future)
        var m3 = SampleData.makeMeeting(id: "m3", status: .recording, scheduledStartDate: future)
        var m4 = SampleData.makeMeeting(id: "m4", status: .complete)
        var m5 = SampleData.makeMeeting(id: "m5", status: .cancelled)
        var m6 = SampleData.makeMeeting(id: "m6", status: .archived)

        try await repo.save(&m1)
        try await repo.save(&m2)
        try await repo.save(&m3)
        try await repo.save(&m4)
        try await repo.save(&m5)
        try await repo.save(&m6)

        let upcoming = try await repo.upcomingMeetings()
        let ids = upcoming.map(\.id)

        XCTAssertEqual(ids.count, 3)
        XCTAssertTrue(ids.contains("m1"))
        XCTAssertTrue(ids.contains("m2"))
        XCTAssertTrue(ids.contains("m3"))
    }

    func testUpcomingMeetingsOrderedByScheduledStartDate() async throws {
        let earlier = Date().addingTimeInterval(1800)
        let later = Date().addingTimeInterval(7200)

        var m1 = SampleData.makeMeeting(id: "later", status: .scheduled, scheduledStartDate: later)
        var m2 = SampleData.makeMeeting(id: "earlier", status: .scheduled, scheduledStartDate: earlier)

        try await repo.save(&m1)
        try await repo.save(&m2)

        let upcoming = try await repo.upcomingMeetings()
        XCTAssertEqual(upcoming.first?.id, "earlier")
        XCTAssertEqual(upcoming.last?.id, "later")
    }

    // MARK: - Past Meetings

    func testPastMeetingsReturnsCompleteAndCancelled() async throws {
        let past = Date().addingTimeInterval(-3600)

        var m1 = SampleData.makeMeeting(id: "m1", status: .complete, endDate: past)
        var m2 = SampleData.makeMeeting(id: "m2", status: .cancelled, endDate: past)
        var m3 = SampleData.makeMeeting(id: "m3", status: .scheduled)

        try await repo.save(&m1)
        try await repo.save(&m2)
        try await repo.save(&m3)

        let pastMeetings = try await repo.pastMeetings()
        let ids = pastMeetings.map(\.id)

        XCTAssertEqual(ids.count, 2)
        XCTAssertTrue(ids.contains("m1"))
        XCTAssertTrue(ids.contains("m2"))
        XCTAssertFalse(ids.contains("m3"))
    }

    func testPastMeetingsRespectsLimit() async throws {
        let past = Date().addingTimeInterval(-3600)

        for i in 0..<5 {
            var m = SampleData.makeMeeting(id: "m\(i)", status: .complete, endDate: past)
            try await repo.save(&m)
        }

        let limited = try await repo.pastMeetings(limit: 3)
        XCTAssertEqual(limited.count, 3)
    }

    // MARK: - Archive / Unarchive

    func testArchive() async throws {
        var meeting = SampleData.makeMeeting(id: "m-arch", status: .complete)
        try await repo.save(&meeting)

        try await repo.archive(id: "m-arch")

        let found = try await repo.find(id: "m-arch")
        XCTAssertEqual(found?.status, .archived)
    }

    func testUnarchive() async throws {
        var meeting = SampleData.makeMeeting(id: "m-unarch", status: .archived)
        try await repo.save(&meeting)

        try await repo.unarchive(id: "m-unarch")

        let found = try await repo.find(id: "m-unarch")
        XCTAssertEqual(found?.status, .complete)
    }

    // MARK: - Meetings Near Date

    func testMeetingsNearDateReturnsMatchingMeeting() async throws {
        let anchor = Date()
        let within = anchor.addingTimeInterval(5 * 60)   // 5 min ahead — inside default 10-min window
        let outside = anchor.addingTimeInterval(20 * 60) // 20 min ahead — outside window

        var m1 = SampleData.makeMeeting(id: "near-in", status: .scheduled, scheduledStartDate: within)
        var m2 = SampleData.makeMeeting(id: "near-out", status: .scheduled, scheduledStartDate: outside)
        try await repo.save(&m1)
        try await repo.save(&m2)

        let results = try await repo.meetingsNearDate(anchor)
        let ids = results.map(\.id)

        XCTAssertTrue(ids.contains("near-in"), "Meeting within the window should be returned")
        XCTAssertFalse(ids.contains("near-out"), "Meeting outside the window should not be returned")
    }

    func testMeetingsNearDateIgnoresNonScheduled() async throws {
        let anchor = Date()
        let within = anchor.addingTimeInterval(3 * 60)

        var m = SampleData.makeMeeting(id: "near-complete", status: .complete, scheduledStartDate: within)
        try await repo.save(&m)

        let results = try await repo.meetingsNearDate(anchor)
        XCTAssertFalse(results.map(\.id).contains("near-complete"),
                       "Only .scheduled meetings should be returned by meetingsNearDate")
    }

    // MARK: - All Meetings For Date

    func testAllMeetingsForDateReturnsMeetingsOnThatDay() async throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let todayNoon = calendar.date(byAdding: .hour, value: 12, to: today)!
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        let tomorrowNoon = calendar.date(byAdding: .hour, value: 12, to: tomorrow)!

        var m1 = SampleData.makeMeeting(id: "day-today", scheduledStartDate: todayNoon)
        var m2 = SampleData.makeMeeting(id: "day-tomorrow", scheduledStartDate: tomorrowNoon)
        try await repo.save(&m1)
        try await repo.save(&m2)

        let results = try await repo.allMeetingsForDate(today)
        let ids = results.map(\.id)

        XCTAssertTrue(ids.contains("day-today"), "Meeting scheduled today should be included")
        XCTAssertFalse(ids.contains("day-tomorrow"), "Meeting scheduled tomorrow should not be included")
    }

    func testAllMeetingsForDateMatchesByActualStartDate() async throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let todayNoon = calendar.date(byAdding: .hour, value: 12, to: today)!

        // No scheduledStartDate — falls back to startDate
        var m = SampleData.makeMeeting(id: "day-actual", startDate: todayNoon)
        try await repo.save(&m)

        let results = try await repo.allMeetingsForDate(today)
        XCTAssertTrue(results.map(\.id).contains("day-actual"),
                      "Meeting with a matching startDate (no scheduledStartDate) should be included")
    }

    // MARK: - Update

    func testUpdate() async throws {
        var meeting = SampleData.makeMeeting(id: "m-upd", title: "Original")
        try await repo.save(&meeting)

        meeting.title = "Updated"
        try await repo.update(meeting)

        let found = try await repo.find(id: "m-upd")
        XCTAssertEqual(found?.title, "Updated")
    }
}

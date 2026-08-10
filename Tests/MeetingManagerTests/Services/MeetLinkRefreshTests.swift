import XCTest
@testable import MeetingManager

/// Covers the meetLink refresh invariant used by both CalendarSyncManager
/// upsert paths (Google `upsertMeeting` and Apple `upsertAppleMeeting`) for
/// scheduled/notified rows. (TASK-127)
final class MeetLinkRefreshTests: XCTestCase {

    func testNewNonNilLinkReplacesExisting() {
        // A rotated Zoom URL / Meet→Zoom swap must overwrite the stored link.
        let resolved = CalendarSyncManager.refreshedMeetLink(
            existing: "https://meet.google.com/old-abc",
            derived: "https://us02web.zoom.us/j/999"
        )
        XCTAssertEqual(resolved, "https://us02web.zoom.us/j/999")
    }

    func testNilDerivationPreservesExisting() {
        // A sync that derives no link must never null out an existing one.
        let resolved = CalendarSyncManager.refreshedMeetLink(
            existing: "https://zoom.us/j/existing",
            derived: nil
        )
        XCTAssertEqual(resolved, "https://zoom.us/j/existing")
    }

    func testDerivedLinkFillsEmpty() {
        let resolved = CalendarSyncManager.refreshedMeetLink(
            existing: nil,
            derived: "https://zoom.us/j/new"
        )
        XCTAssertEqual(resolved, "https://zoom.us/j/new")
    }

    func testBothNilStaysNil() {
        XCTAssertNil(CalendarSyncManager.refreshedMeetLink(existing: nil, derived: nil))
    }
}

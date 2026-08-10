import XCTest
@testable import MeetingManager

/// Table-driven tests for `MeetingTitleNormalizer` (TASK-117).
///
/// The normalizer must collapse cosmetic-only differences (unread count,
/// leading status glyph, platform suffix) to the same key, treat a Google Meet
/// room code as the identity token, and map generic platform chrome to nil.
final class MeetingTitleNormalizerTests: XCTestCase {

    private let normalizer = MeetingTitleNormalizer()

    // MARK: - normalize → value

    func testStripsUnreadCountPrefix() {
        XCTAssertEqual(normalizer.normalize("(3) Design Review - Google Meet"), "design review")
        XCTAssertEqual(normalizer.normalize("(12) Design Review - Google Meet"), "design review")
    }

    func testStripsLeadingStatusGlyphs() {
        XCTAssertEqual(normalizer.normalize("🔴 Design Review | Microsoft Teams"), "design review")
        XCTAssertEqual(normalizer.normalize("• Design Review - Zoom"), "design review")
    }

    func testStripsPlatformSuffixes() {
        XCTAssertEqual(normalizer.normalize("Design Review - Google Meet"), "design review")
        XCTAssertEqual(normalizer.normalize("Design Review | Microsoft Teams"), "design review")
        XCTAssertEqual(normalizer.normalize("Design Review — Zoom Meeting"), "design review")
        XCTAssertEqual(normalizer.normalize("Design Review - Zoom"), "design review")
    }

    func testMeetPrefixes() {
        // "Meet with Parker" → the participant name.
        XCTAssertEqual(normalizer.normalize("Meet with Parker"), "parker")
    }

    func testCaseFoldedAndWhitespaceCollapsed() {
        XCTAssertEqual(normalizer.normalize("  Weekly   1:1   - Google Meet "), "weekly 1:1")
        XCTAssertEqual(normalizer.normalize("WEEKLY SYNC"), "weekly sync")
    }

    // MARK: - Meet code as identity token

    func testMeetCodeIsIdentityToken() {
        XCTAssertEqual(normalizer.normalize("Meet - abc-defg-hij"), "abc-defg-hij")
        // A code embedded anywhere wins over the rest of the title.
        XCTAssertEqual(normalizer.normalize("abc-defg-hij - Google Meet"), "abc-defg-hij")
    }

    func testDifferentMeetCodesAreDifferentKeys() {
        XCTAssertNotEqual(
            normalizer.normalize("Meet - abc-defg-hij"),
            normalizer.normalize("Meet - xyz-wxyz-klm")
        )
    }

    // MARK: - Cosmetic changes compare equal

    func testCosmeticChangesCompareEqual() {
        // Unread-count flip + mute glyph — same underlying meeting.
        XCTAssertEqual(
            normalizer.normalize("(1) Design Review - Google Meet"),
            normalizer.normalize("🔴 Design Review - Google Meet")
        )
    }

    // MARK: - Generic titles → nil (no signal)

    func testGenericTitlesNormalizeToNil() {
        XCTAssertNil(normalizer.normalize("Zoom Meeting"))
        XCTAssertNil(normalizer.normalize("Meet"))
        XCTAssertNil(normalizer.normalize("Google Meet"))
        XCTAssertNil(normalizer.normalize("Microsoft Teams"))
        XCTAssertNil(normalizer.normalize(""))
        XCTAssertNil(normalizer.normalize("   "))
    }

    func testRealTitlesAreNotNil() {
        XCTAssertNotNil(normalizer.normalize("Q3 Planning - Google Meet"))
        XCTAssertNotNil(normalizer.normalize("Standup | Microsoft Teams"))
    }
}

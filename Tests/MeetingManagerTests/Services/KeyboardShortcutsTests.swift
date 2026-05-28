import XCTest
import SwiftUI
@testable import MeetingManager

final class KeyboardShortcutsTests: XCTestCase {

    // Verify that all keyboard shortcut definitions exist and are accessible.
    // We compare them against freshly-constructed KeyboardShortcut values to
    // ensure keys and modifiers match expectations.

    // MARK: - Primary Shortcuts

    func testNewMeetingShortcut() {
        let expected = KeyboardShortcut("n", modifiers: .command)
        // Verify the static property is the same type and accessible
        let actual = KeyboardShortcuts.newMeeting
        // Compare by reconstructing -- both should be command+n
        XCTAssertEqual(String(describing: actual), String(describing: expected))
    }

    func testToggleRecordingShortcut() {
        let expected = KeyboardShortcut("r", modifiers: .command)
        let actual = KeyboardShortcuts.toggleRecording
        XCTAssertEqual(String(describing: actual), String(describing: expected))
    }

    func testExportMeetingShortcut() {
        let expected = KeyboardShortcut("e", modifiers: .command)
        let actual = KeyboardShortcuts.exportMeeting
        XCTAssertEqual(String(describing: actual), String(describing: expected))
    }

    func testCopySummaryShortcut() {
        let expected = KeyboardShortcut("c", modifiers: [.command, .shift])
        let actual = KeyboardShortcuts.copySummary
        XCTAssertEqual(String(describing: actual), String(describing: expected))
    }

    func testSearchShortcut() {
        let expected = KeyboardShortcut("f", modifiers: .command)
        let actual = KeyboardShortcuts.search
        XCTAssertEqual(String(describing: actual), String(describing: expected))
    }

    // MARK: - Tab Shortcuts

    func testTabSummaryShortcut() {
        let expected = KeyboardShortcut("1", modifiers: .command)
        let actual = KeyboardShortcuts.tabSummary
        XCTAssertEqual(String(describing: actual), String(describing: expected))
    }

    func testTabTranscriptShortcut() {
        let expected = KeyboardShortcut("3", modifiers: .command)
        let actual = KeyboardShortcuts.tabTranscript
        XCTAssertEqual(String(describing: actual), String(describing: expected))
    }

    func testTabNotesShortcut() {
        let expected = KeyboardShortcut("2", modifiers: .command)
        let actual = KeyboardShortcuts.tabNotes
        XCTAssertEqual(String(describing: actual), String(describing: expected))
    }

    // ⌘4 / .actionItems tab was removed in P1-T02 (action items render inline
    // under the summary); ⌘4 is intentionally unbound, so there's no shortcut to test.

    // MARK: - All Shortcuts Are Distinct

    func testAllShortcutsAreDistinct() {
        let allShortcuts = [
            KeyboardShortcuts.newMeeting,
            KeyboardShortcuts.toggleRecording,
            KeyboardShortcuts.exportMeeting,
            KeyboardShortcuts.copySummary,
            KeyboardShortcuts.search,
            KeyboardShortcuts.tabSummary,
            KeyboardShortcuts.tabTranscript,
            KeyboardShortcuts.tabNotes,
        ]
        let descriptions = allShortcuts.map { String(describing: $0) }
        let unique = Set(descriptions)
        XCTAssertEqual(unique.count, allShortcuts.count, "All shortcuts should be unique")
    }
}

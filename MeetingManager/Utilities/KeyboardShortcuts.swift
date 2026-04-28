import SwiftUI

/// Centralized keyboard shortcut definitions for the app
enum KeyboardShortcuts {
    static let newMeeting = KeyboardShortcut("n", modifiers: .command)
    static let toggleRecording = KeyboardShortcut("r", modifiers: .command)
    static let exportMeeting = KeyboardShortcut("e", modifiers: .command)
    static let copySummary = KeyboardShortcut("c", modifiers: [.command, .shift])
    static let search = KeyboardShortcut("f", modifiers: .command)

    // Tab switching — order matches the v3.0.0 detail view: Summary | Notes | Transcript.
    // Action items are now rendered inline beneath the summary; the .actionItems
    // tab was removed in P1-T02. ⌘4 is intentionally unbound.
    static let tabSummary = KeyboardShortcut("1", modifiers: .command)
    static let tabNotes = KeyboardShortcut("2", modifiers: .command)
    static let tabTranscript = KeyboardShortcut("3", modifiers: .command)

    // Meeting navigation in detail pane
    static let prevMeeting = KeyboardShortcut("[", modifiers: .command)
    static let nextMeeting = KeyboardShortcut("]", modifiers: .command)
}

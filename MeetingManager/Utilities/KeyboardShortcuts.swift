import SwiftUI

/// Centralized keyboard shortcut definitions for the app
enum KeyboardShortcuts {
    static let newMeeting = KeyboardShortcut("n", modifiers: .command)
    static let toggleRecording = KeyboardShortcut("r", modifiers: .command)
    static let exportMeeting = KeyboardShortcut("e", modifiers: .command)
    static let copySummary = KeyboardShortcut("c", modifiers: [.command, .shift])
    static let search = KeyboardShortcut("f", modifiers: .command)

    // Tab switching
    static let tabSummary = KeyboardShortcut("1", modifiers: .command)
    static let tabTranscript = KeyboardShortcut("2", modifiers: .command)
    static let tabNotes = KeyboardShortcut("3", modifiers: .command)
    static let tabActionItems = KeyboardShortcut("4", modifiers: .command)
}

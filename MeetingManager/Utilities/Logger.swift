import os

/// Centralized logging categories built on top of `os.Logger`.
/// Each category maps to a functional area of the app for easy filtering in Console.app.
extension Logger {

    /// The subsystem used for all loggers, derived from the app bundle identifier.
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.meetingmanager"

    /// Audio capture and processing events.
    static let audio = Logger(subsystem: subsystem, category: "audio")

    /// Database reads, writes, and migrations.
    static let database = Logger(subsystem: subsystem, category: "database")

    /// Calendar integration and event sync.
    static let calendar = Logger(subsystem: subsystem, category: "calendar")

    /// AI and LLM interactions (summarisation, action items).
    static let ai = Logger(subsystem: subsystem, category: "ai")

    /// User interface lifecycle and interactions.
    static let ui = Logger(subsystem: subsystem, category: "ui")

    /// Speech-to-text transcription pipeline.
    static let transcription = Logger(subsystem: subsystem, category: "transcription")

    /// General app lifecycle events.
    static let general = Logger(subsystem: subsystem, category: "general")
}

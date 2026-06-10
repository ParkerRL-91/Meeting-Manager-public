import Foundation

/// App-wide constants organised by domain.
enum Constants {

    // MARK: - Call Application Bundle IDs

    /// Call app bundle IDs are defined in `CallAppRegistry` (single source of truth).
    /// Access via `CallAppRegistry.knownApps`, `CallAppRegistry.isCallApp(bundleIdentifier:)`.

    // MARK: - Audio Configuration

    /// Default audio capture settings optimised for speech-to-text.
    enum AudioConfig {
        /// Sample rate in Hz, matching Whisper's expected input.
        static let sampleRate: Double = 16_000

        /// Duration of each audio chunk sent for transcription, in seconds.
        static let chunkDuration: TimeInterval = 5.0

        /// Overlap between consecutive chunks to avoid cutting words, in seconds.
        static let overlap: TimeInterval = 1.0

        /// Number of audio channels (mono for speech).
        static let channels: Int = 1

        /// Bits per sample.
        static let bitsPerSample: Int = 16
    }

    // MARK: - Default Values

    /// Sensible defaults used when no user preference is set.
    enum Defaults {
        /// Maximum recording duration before auto-stop, in seconds (4 hours).
        static let maxRecordingDuration: TimeInterval = 4 * 60 * 60

        /// Number of recent meetings shown on the dashboard.
        static let recentMeetingsLimit = 20

        /// Default AI model used for summarisation.
        static let aiModel = "claude-sonnet-4-6"

        /// Maximum transcript tokens sent per summarisation request.
        static let maxTranscriptTokens = 100_000

        /// Whether the app should auto-record detected meetings.
        static let autoRecordEnabled = false

        /// Whether to show the menu bar icon.
        static let showMenuBarIcon = true
    }

    // MARK: - Storage

    /// Paths and identifiers for on-disk storage.
    enum Storage {
        /// The application group container identifier.
        static let appGroup = "group.com.meetingmanager"

        /// The SQLite database file name.
        static let databaseFileName = "meeting_manager.sqlite"

        /// The directory name for audio recordings within Application Support.
        static let audioDirectoryName = "Recordings"
    }
}

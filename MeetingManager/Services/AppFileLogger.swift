import Foundation

/// Thread-safe file logger that serializes all writes through a single dispatch queue.
/// Replaces ad-hoc FileHandle logging throughout the app to prevent interleaved or
/// corrupted log lines when multiple subsystems write concurrently.
final class AppFileLogger {
    static let shared = AppFileLogger()

    private let queue = DispatchQueue(label: "com.meetingmanager.filelog", qos: .utility)
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        return f
    }()

    private lazy var logURL: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MeetingManager/app.log")
    }()

    private init() {
        // Ensure the log directory exists
        let dir = logURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Create the log file if it doesn't exist, then restrict to owner-only
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logURL.path)
    }

    /// Append a timestamped message to the log file. Safe to call from any thread.
    func log(_ message: String) {
        let timestamp = formatter.string(from: Date())
        let line = "[\(timestamp)] \(message)\n"

        queue.async { [logURL] in
            guard let data = line.data(using: .utf8),
                  let handle = try? FileHandle(forWritingTo: logURL) else { return }
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        }
    }
}

import Foundation

/// Thread-safe file logger. All writes go through a single serial queue.
/// Rotates daily: the previous day's log is renamed app-YYYY-MM-DD.log.
/// Files older than 30 days are pruned automatically.
final class AppFileLogger {
    static let shared = AppFileLogger()

    private let queue = DispatchQueue(label: "com.meetingmanager.filelog", qos: .utility)

    private let timestampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        return f
    }()

    private let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// URL of the current (active) log file.
    let logURL: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MeetingManager/app.log")
    }()

    private init() {
        let dir = logURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logURL.path)
    }

    /// Append a timestamped message to the log file. Safe to call from any thread.
    func log(_ message: String) {
        let timestamp = timestampFormatter.string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        queue.async {
            self.rotateIfNeeded()
            guard let data = line.data(using: .utf8),
                  let handle = try? FileHandle(forWritingTo: self.logURL) else { return }
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        }
    }

    // MARK: - Daily rotation (called on the serial queue)

    private func rotateIfNeeded() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: logURL.path),
              let attrs = try? fm.attributesOfItem(atPath: logURL.path),
              let modDate = attrs[.modificationDate] as? Date else { return }

        let today = dayFormatter.string(from: Date())
        let fileDay = dayFormatter.string(from: modDate)
        guard today != fileDay else { return }

        // Move the old log to a dated archive
        let rotatedURL = logURL.deletingLastPathComponent()
            .appendingPathComponent("app-\(fileDay).log")
        try? fm.moveItem(at: logURL, to: rotatedURL)

        // Start a fresh log file
        fm.createFile(atPath: logURL.path, contents: nil)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logURL.path)

        pruneOldLogs(keepDays: 30)
    }

    private func pruneOldLogs(keepDays: Int) {
        let dir = logURL.deletingLastPathComponent()
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.creationDateKey]
        ) else { return }
        let cutoff = Calendar.current.date(byAdding: .day, value: -keepDays, to: Date()) ?? Date()
        for url in contents
        where url.lastPathComponent.hasPrefix("app-") && url.pathExtension == "log" {
            if let vals = try? url.resourceValues(forKeys: [.creationDateKey]),
               let created = vals.creationDate, created < cutoff {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}

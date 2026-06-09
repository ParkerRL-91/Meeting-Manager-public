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

    /// Open handle to the active log file, kept for the process lifetime and
    /// reopened on rotation. The previous open-stat-seek-write-close cycle
    /// per LINE cost thousands of needless syscalls a day from the 30 s
    /// proximity poll and the audio-level diagnostics alone.
    /// Only touched on `queue`.
    private var handle: FileHandle?

    /// Day stamp ("yyyy-MM-dd") of the active log file. Only touched on `queue`.
    private var activeDay: String

    private init() {
        let dir = logURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logURL.path)

        let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path)
        let modDate = (attrs?[.modificationDate] as? Date) ?? Date()
        activeDay = dayFormatter.string(from: modDate)
    }

    /// Append a timestamped message to the log file. Safe to call from any thread.
    func log(_ message: String) {
        let timestamp = timestampFormatter.string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        queue.async {
            self.rotateIfNeeded()
            guard let data = line.data(using: .utf8) else { return }
            if self.handle == nil {
                self.handle = try? FileHandle(forWritingTo: self.logURL)
                self.handle?.seekToEndOfFile()
            }
            self.handle?.write(data)
        }
    }

    // MARK: - Daily rotation (called on the serial queue)

    private func rotateIfNeeded() {
        // Compare against the cached day stamp — no per-line stat() needed.
        let today = dayFormatter.string(from: Date())
        guard today != activeDay else { return }

        let fm = FileManager.default
        handle?.closeFile()
        handle = nil

        // Move the old log to a dated archive. If that exact archive name
        // already exists, suffix it — a failed move followed by createFile
        // would truncate the live log and destroy the un-archived day.
        var rotatedURL = logURL.deletingLastPathComponent()
            .appendingPathComponent("app-\(activeDay).log")
        if fm.fileExists(atPath: rotatedURL.path) {
            rotatedURL = logURL.deletingLastPathComponent()
                .appendingPathComponent("app-\(activeDay)-\(Int(Date().timeIntervalSince1970)).log")
        }
        let moved = (try? fm.moveItem(at: logURL, to: rotatedURL)) != nil

        // Start a fresh log file — but ONLY when the move succeeded (or the
        // live file is genuinely gone). createFile over an existing file
        // truncates; if the move failed for any reason (e.g. disk full),
        // keep appending past the rotation boundary rather than destroy the
        // un-archived day.
        if moved || !fm.fileExists(atPath: logURL.path) {
            fm.createFile(atPath: logURL.path, contents: nil)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logURL.path)
        }
        activeDay = today

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

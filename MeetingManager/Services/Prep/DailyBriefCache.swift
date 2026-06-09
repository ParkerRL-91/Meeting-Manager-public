import Foundation
import CryptoKit
import os

/// File-backed cache for the AI-generated daily brief. One JSON file per day
/// under `~/Library/Application Support/MeetingManager/daily-briefs/`.
///
/// The `signature` captures the inputs that should invalidate a brief: today's
/// meeting set (IDs + scheduled times + last-updated stamps) and the count of
/// open action items. When the signature changes, the brief is stale and is
/// re-generated in the background. The View itself never blocks on
/// generation — it reads whatever is cached and shows a freshness hint.
enum DailyBriefCache {

    // MARK: - Model

    struct Entry: Codable, Sendable {
        let date: String          // YYYY-MM-DD (local calendar day)
        let signature: String     // SHA-256 of input fingerprint
        let text: String          // Markdown body
        let model: String         // "claude-…", "qwen3:8b", etc.
        let generatedAt: Date
    }

    // MARK: - Paths

    private static let fm = FileManager.default
    private static let isoDay: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static func cacheDir() -> URL {
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MeetingManager", isDirectory: true)
            .appendingPathComponent("daily-briefs", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func cacheURL(date: Date) -> URL {
        cacheDir().appendingPathComponent("\(isoDay.string(from: date)).json")
    }

    // MARK: - Read / Write

    static func load(date: Date) -> Entry? {
        let url = cacheURL(date: date)
        guard let data = try? Data(contentsOf: url),
              let entry = try? JSONDecoder.iso8601.decode(Entry.self, from: data) else {
            return nil
        }
        return entry
    }

    static func save(_ entry: Entry) {
        let url = cacheURL(date: dayFromString(entry.date) ?? Date())
        guard let data = try? JSONEncoder.iso8601.encode(entry) else { return }
        try? data.write(to: url, options: .atomic)
        Logger.ai.info("DailyBriefCache: saved \(entry.date, privacy: .public) (\(entry.text.count) chars, model=\(entry.model, privacy: .public))")
        pruneOldEntries(keepDays: 14)
    }

    /// A brief is only ever read for "today"; older entries are dead weight
    /// that previously accumulated one file per active day, forever.
    private static func pruneOldEntries(keepDays: Int) {
        guard let contents = try? fm.contentsOfDirectory(at: cacheDir(), includingPropertiesForKeys: nil) else { return }
        let cutoff = Calendar.current.date(byAdding: .day, value: -keepDays, to: Date()) ?? Date()
        for url in contents where url.pathExtension == "json" {
            let day = url.deletingPathExtension().lastPathComponent
            if let date = dayFromString(day), date < cutoff {
                try? fm.removeItem(at: url)
            }
        }
    }

    static func clear(date: Date) {
        try? fm.removeItem(at: cacheURL(date: date))
    }

    static func dayString(for date: Date) -> String { isoDay.string(from: date) }

    private static func dayFromString(_ s: String) -> Date? { isoDay.date(from: s) }

    // MARK: - Signature

    /// Stable fingerprint of the inputs the brief depends on. Two briefs with
    /// the same signature describe the same day in the same way and don't
    /// need to be regenerated. Order-independent w.r.t. meetings.
    static func signature(for brief: DailyBrief) -> String {
        var parts: [String] = []
        for entry in brief.meetings.sorted(by: { $0.meeting.id < $1.meeting.id }) {
            let m = entry.meeting
            let startStamp = (m.scheduledStartDate ?? m.startDate)?.timeIntervalSince1970 ?? 0
            let title = m.title
            let p = entry.prepBrief.participants.sorted().joined(separator: ",")
            // Include previousSession.meetingId so a newly-summarized prior
            // meeting invalidates the brief.
            let prev = entry.prepBrief.previousSession?.meetingId ?? "-"
            let prevDate = entry.prepBrief.previousSession?.date.timeIntervalSince1970 ?? 0
            // Fold the meeting's KB background so editing/adding/removing a cited
            // note regenerates the brief. Content-hashed (not just counted) so a
            // same-length edit still invalidates.
            let kb = entry.kbChunks
                .sorted { ($0.relativePath, $0.chunkIndex) < ($1.relativePath, $1.chunkIndex) }
                .map { "\($0.relativePath)#\($0.chunkIndex):\($0.body)" }
                .joined(separator: "\u{00A7}")
            parts.append("\(m.id)|\(title)|\(Int(startStamp))|\(p)|\(prev)|\(Int(prevDate))|\(entry.prepBrief.openActionItems.count)|kb:\(shortHash(kb))")
        }
        let joined = parts.joined(separator: "\n")
        let hash = SHA256.hash(data: Data(joined.utf8))
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    /// Deterministic 8-byte hex digest, used to fold variable-length KB bodies
    /// into the signature without bloating it. Stable across launches (unlike
    /// `String.hashValue`, which is per-process salted).
    private static func shortHash(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - JSON helpers

private extension JSONDecoder {
    static let iso8601: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

private extension JSONEncoder {
    static let iso8601: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
}

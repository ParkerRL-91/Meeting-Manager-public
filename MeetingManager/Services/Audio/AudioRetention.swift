import Foundation
import GRDB
import os

/// Pure retention math + the destructive sweep for meeting audio (PRJ-016).
///
/// Mirrors the video-retention pattern (`VideoRetention` / `sweepRetention`)
/// but adds a strict safety floor: a meeting's WAV(s) are removed only when the
/// meeting is `.complete`/`.archived`, transcription was attempted AND produced
/// at least one transcript row, and the meeting is older than the window. The
/// transcript, summary, notes, and action items are always kept; only the raw
/// audio (the mixed WAV and its `_system.wav` sibling) is deleted.
///
/// Opt-in: `retentionDays == 0` (Forever, the default) is always a no-op, so
/// nothing is ever deleted until the user chooses a window.
enum AudioRetention {

    private static let logger = Logger(subsystem: "com.meetingmanager.app", category: "AudioRetention")

    /// Pure: the meeting ids past the window AND safe to prune. The caller has
    /// already filtered candidates to complete/archived meetings with a recorded
    /// transcription attempt; here we additionally require a transcript row to
    /// exist (so a failed/empty transcription keeps its audio for a retry) and
    /// the meeting to be older than the cutoff. `retentionDays == 0` → none.
    static func expired(
        _ candidates: [(meetingId: String, age: Date, hasTranscript: Bool)],
        retentionDays: Int,
        now: Date
    ) -> [String] {
        guard retentionDays > 0 else { return [] }
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400)
        return candidates
            .filter { $0.hasTranscript && $0.age < cutoff }
            .map(\.meetingId)
    }

    /// All on-disk audio URLs for a meeting: each recorded WAV plus its hidden
    /// `_system.wav` sibling (the remote-audio half, ~half the footprint, not
    /// tracked in `audioFilePaths`).
    static func audioURLs(for meeting: Meeting) -> [URL] {
        meeting.audioFilePaths.flatMap { path -> [URL] in
            let main = URL(fileURLWithPath: path)
            return [main, AudioBufferManager.systemAudioURL(for: main)]
        }
    }

    /// Meetings eligible for pruning under the safety floor + window. Shared by
    /// the sweep and the Settings reclaimable-size preview so the previewed
    /// figure matches exactly what the sweep frees.
    static func eligibleMeetings(database: AppDatabase, retentionDays: Int, now: Date = Date()) async -> [Meeting] {
        guard retentionDays > 0 else { return [] }
        let fetched: (candidates: [Meeting], withTranscripts: Set<String>)? = try? await database.writer.read { db in
            let candidates = try Meeting
                .filter([MeetingStatus.complete.rawValue, MeetingStatus.archived.rawValue].contains(Meeting.Columns.status))
                .filter(Meeting.Columns.transcriptionAttemptedAt != nil)
                .filter(Meeting.Columns.audioFilePaths != "[]")
                .fetchAll(db)
            let withTranscripts = try String.fetchSet(db, sql: "SELECT DISTINCT meetingId FROM transcript")
            return (candidates, withTranscripts)
        }
        guard let (candidates, withTranscripts) = fetched else { return [] }
        let expiredIds = Set(expired(
            candidates.map { ($0.id, $0.endDate ?? $0.startDate ?? $0.createdAt, withTranscripts.contains($0.id)) },
            retentionDays: retentionDays, now: now))
        return candidates.filter { expiredIds.contains($0.id) }
    }

    /// Total bytes the sweep would free right now (WAV + `_system.wav` across the
    /// eligible meetings). Off-main — stats potentially hundreds of files.
    static func reclaimableBytes(database: AppDatabase, retentionDays: Int, now: Date = Date()) async -> Int64 {
        let meetings = await eligibleMeetings(database: database, retentionDays: retentionDays, now: now)
        let fm = FileManager.default
        var total: Int64 = 0
        for meeting in meetings {
            for url in audioURLs(for: meeting) {
                total += ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
            }
        }
        return total
    }

    /// Total bytes currently used by recorded audio (the whole Audio directory,
    /// including `_system.wav` siblings). Off-main — walks the directory.
    static func currentAudioUsageBytes() -> Int64 {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        guard let dir = base?.appendingPathComponent("MeetingManager/Audio", isDirectory: true),
              let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }

    /// Delete expired audio, clear the path columns, and stamp `audioPrunedAt`.
    /// Returns what was freed and which meetings were pruned (so the on-confirm
    /// caller can drop a stale player). The column clear uses raw SQL because the
    /// legacy `audioFilePath` column is NOT in the GRDB `Meeting` model (it's a
    /// computed property), so a model update would leave it populated.
    @discardableResult
    static func sweep(database: AppDatabase, retentionDays: Int, now: Date = Date()) async -> (files: Int, bytes: Int64, prunedMeetingIds: [String]) {
        let meetings = await eligibleMeetings(database: database, retentionDays: retentionDays, now: now)
        guard !meetings.isEmpty else { return (0, 0, []) }
        let fm = FileManager.default
        var filesRemoved = 0
        var bytesFreed: Int64 = 0
        var prunedIds: [String] = []
        for meeting in meetings {
            for url in audioURLs(for: meeting) {
                guard fm.fileExists(atPath: url.path) else { continue }
                let size = ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
                do {
                    try fm.removeItem(at: url)
                    filesRemoved += 1
                    bytesFreed += size
                } catch {
                    logger.warning("Audio prune failed for \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
            // Clear path state + stamp the marker even when files were already
            // gone, so the row stops claiming audio and the UI can explain the
            // absence. Raw SQL clears the legacy column the model can't reach.
            try? await database.writer.write { db in
                try db.execute(
                    sql: "UPDATE meeting SET audioFilePath = NULL, audioFilePaths = '[]', audioPrunedAt = ? WHERE id = ?",
                    arguments: [now, meeting.id])
            }
            prunedIds.append(meeting.id)
        }
        if !prunedIds.isEmpty {
            logger.info("Audio retention: removed \(filesRemoved) file(s), freed \(bytesFreed) bytes across \(prunedIds.count) meeting(s)")
        }
        return (filesRemoved, bytesFreed, prunedIds)
    }
}

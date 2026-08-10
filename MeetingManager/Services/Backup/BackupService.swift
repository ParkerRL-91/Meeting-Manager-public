import Foundation
import GRDB
import os

/// Backup & Restore (PRJ-017 F5). A backup is a stable `MeetingManagerBackup/`
/// folder at a user-chosen destination containing a consistent DB snapshot
/// (`VACUUM INTO`, a single self-contained file — no WAL siblings), the small
/// sidecar dirs, an optional human-readable `transcripts/` markdown export, and
/// (optionally) the Audio/video recordings copied incrementally. Restore is
/// staged into Application Support and applied at the next launch, before the
/// database pool opens (`consumePendingRestore`), so the live DB is never
/// swapped underneath a running connection.
@MainActor
@Observable
final class BackupService {
    static let shared = BackupService()

    enum Phase: Equatable {
        case idle, snapshotting, copyingFiles, exportingMarkdown, copyingMedia, verifying, done
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var progress: Double = 0

    var isRunning: Bool {
        switch phase {
        case .idle, .done, .failed: return false
        default: return true
        }
    }

    private static let log = Logger(subsystem: "com.meetingmanager.app", category: "backup")

    // Sidecar directories (relative to Application Support/MeetingManager) copied
    // in the "files" step — small, full-copy each run.
    private static let sidecarDirs = ["note-drafts", "TaskAttachments", "daily-briefs",
                                      "speaker-summaries", "speaker-guesses"]
    private static let restorePendingDB = "db.restore-pending.sqlite"
    private static let restoreMarker = "restore-pending.json"

    // MARK: - Paths

    static func supportDirectory() throws -> URL {
        try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("MeetingManager", isDirectory: true)
    }

    // MARK: - Backup

    func runBackup(destination: URL, includeMedia: Bool, includeMarkdown: Bool,
                   database: AppDatabase = .shared) async {
        guard !isRunning else { return }
        guard AppDatabase.initializationError == nil else {
            phase = .failed("The database isn't available (running on an in-memory fallback). Backup is disabled until the app restarts cleanly.")
            return
        }
        phase = .snapshotting
        progress = 0
        // Resolve the (main-actor-isolated) recordings directory here, then hand
        // it to the nonisolated engine.
        let recordingsDir = RecordingStorage.shared.preferredDirectory()
        do {
            try await Self.performBackup(
                destination: destination,
                includeMedia: includeMedia,
                includeMarkdown: includeMarkdown,
                database: database,
                recordingsDir: recordingsDir
            ) { [weak self] newPhase, prog in
                Task { @MainActor in
                    guard let self else { return }
                    self.phase = newPhase
                    self.progress = prog
                }
            }
            phase = .done
            progress = 1
        } catch {
            Self.log.error("Backup failed: \(error.localizedDescription)")
            phase = .failed(error.localizedDescription)
        }
    }

    private static func performBackup(
        destination: URL,
        includeMedia: Bool,
        includeMarkdown: Bool,
        database: AppDatabase,
        recordingsDir: URL,
        report: @escaping @Sendable (Phase, Double) -> Void
    ) async throws {
        let fm = FileManager.default
        let root = destination.appendingPathComponent(BackupManifest.backupFolderName, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        // Fail early if the destination isn't writable (unplugged drive, full disk).
        if let probeError = probeWritable(root) { throw probeError }

        // 1. DB snapshot via VACUUM INTO → a single consistent file. Target must
        // not exist, so write to .inprogress then rename into a dated name.
        report(.snapshotting, 0.02)
        let dbDir = root.appendingPathComponent("db", isDirectory: true)
        try fm.createDirectory(at: dbDir, withIntermediateDirectories: true)
        let inprogressDB = dbDir.appendingPathComponent(".inprogress-db.sqlite")
        try? fm.removeItem(at: inprogressDB)
        try await database.writer.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM INTO ?", arguments: [inprogressDB.path])
        }
        try verifyIntegrity(of: inprogressDB)   // throws if the snapshot is corrupt
        let stampName = "db-\(fileStamp()).sqlite"
        let finalDB = dbDir.appendingPathComponent(stampName)
        try? fm.removeItem(at: finalDB)
        try fm.moveItem(at: inprogressDB, to: finalDB)
        pruneOldSnapshots(in: dbDir, keeping: 7)
        report(.copyingFiles, 0.12)

        // 2. Small sidecar dirs — full copy each run (atomic per-dir).
        let support = try supportDirectory()
        let filesRoot = root.appendingPathComponent("files", isDirectory: true)
        try fm.createDirectory(at: filesRoot, withIntermediateDirectories: true)
        for name in sidecarDirs {
            let src = support.appendingPathComponent(name, isDirectory: true)
            guard fm.fileExists(atPath: src.path) else { continue }
            let dest = filesRoot.appendingPathComponent(name, isDirectory: true)
            try replaceDirectory(from: src, to: dest)
        }
        report(.exportingMarkdown, 0.2)

        // 3. Readable markdown export (one file per meeting), incremental.
        var counts = Counts()
        if includeMarkdown {
            counts = try await exportMarkdown(root: root, database: database)
        } else {
            counts = try await gatherCounts(database: database)
        }
        report(.copyingMedia, 0.4)

        // 4. Media — incremental (skip files already present with same size).
        if includeMedia {
            try copyMediaIncremental(support: support, recordingsDir: recordingsDir, root: root) { frac in
                report(.copyingMedia, 0.4 + 0.55 * frac)
            }
        }
        report(.verifying, 0.97)

        // 5. Manifest.
        let migrationIds = try await appliedMigrationIds(database: database)
        let now = Date().timeIntervalSince1970
        let manifest = BackupManifest(
            appVersion: appVersionString(),
            migrationIds: migrationIds,
            includesMedia: includeMedia,
            includesMarkdown: includeMarkdown,
            meetingCount: counts.meetings,
            transcriptCount: counts.transcripts,
            decisionCount: counts.decisions,
            taskCount: counts.tasks,
            createdAt: now,
            lastRunAt: now
        )
        let data = try JSONEncoder.pretty.encode(manifest)
        try data.write(to: root.appendingPathComponent(BackupManifest.fileName), options: .atomic)
    }

    // MARK: - Validate + stage restore

    func validateBackup(at folder: URL) async throws -> BackupManifest {
        let root = Self.resolveRoot(folder)
        let manifestURL = root.appendingPathComponent(BackupManifest.fileName)
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(BackupManifest.self, from: data)

        guard let snapshot = Self.latestSnapshot(in: root) else {
            throw BackupError.noSnapshot
        }
        try Self.verifyIntegrity(of: snapshot)

        // Refuse a backup from a newer app: any migration id it has that the
        // running binary doesn't know would fail to open / silently lose data.
        let known = Set(try await Self.appliedMigrationIds(database: .shared))
        let unknown = manifest.migrationIds.filter { !known.contains($0) }
        if !unknown.isEmpty {
            throw BackupError.newerSchema(unknown)
        }
        return manifest
    }

    /// Copy the snapshot + marker into Application Support so the next launch
    /// applies it before the pool opens. Does NOT touch the live db.sqlite.
    func stageRestore(from folder: URL) async throws {
        let root = Self.resolveRoot(folder)
        guard let snapshot = Self.latestSnapshot(in: root) else { throw BackupError.noSnapshot }
        try Self.verifyIntegrity(of: snapshot)

        let support = try Self.supportDirectory()
        let fm = FileManager.default
        let pendingDB = support.appendingPathComponent(Self.restorePendingDB)
        try? fm.removeItem(at: pendingDB)
        try fm.copyItem(at: snapshot, to: pendingDB)

        // Marker records the backup root so the launch step can also restore the
        // sidecar file dirs.
        let marker = RestoreMarker(backupRootPath: root.path, stagedAt: Date().timeIntervalSince1970)
        let data = try JSONEncoder().encode(marker)
        try data.write(to: support.appendingPathComponent(Self.restoreMarker), options: .atomic)
    }

    // MARK: - Launch-time restore (nonisolated — runs before the pool opens)

    private struct RestoreMarker: Codable { let backupRootPath: String; let stagedAt: Double }

    /// Consumed at the very top of `AppDatabase._makeShared`, before the
    /// `DatabasePool` is created. If a staged restore is present, the current
    /// db.sqlite (and WAL siblings) are renamed aside (never deleted) and the
    /// pending snapshot is moved into place, then the sidecar dirs are restored.
    /// Defensive throughout: any inconsistency deletes the marker and boots the
    /// existing DB rather than bricking launch. Sets a UserDefaults flag so
    /// AppState can show the post-restore checklist.
    nonisolated static func consumePendingRestore(in support: URL) {
        let fm = FileManager.default
        let markerURL = support.appendingPathComponent(restoreMarker)
        let pendingURL = support.appendingPathComponent(restorePendingDB)
        guard fm.fileExists(atPath: markerURL.path) else { return }

        // Crash between marker write and pending copy → nothing to apply.
        guard fm.fileExists(atPath: pendingURL.path) else {
            try? fm.removeItem(at: markerURL)
            return
        }

        do {
            let dbURL = support.appendingPathComponent("db.sqlite")
            let stamp = fileStamp()
            // Rename the current DB + WAL/SHM aside (kept for recovery).
            for suffix in ["", "-wal", "-shm"] {
                let live = support.appendingPathComponent("db.sqlite\(suffix)")
                if fm.fileExists(atPath: live.path) {
                    let aside = support.appendingPathComponent("db.pre-restore-\(stamp).sqlite\(suffix)")
                    try? fm.removeItem(at: aside)
                    try fm.moveItem(at: live, to: aside)
                }
            }
            // Move the snapshot into place (it's WAL-free, a clean single file).
            try fm.moveItem(at: pendingURL, to: dbURL)

            // Restore sidecar dirs from the backup root, if still reachable.
            if let data = try? Data(contentsOf: markerURL),
               let marker = try? JSONDecoder().decode(RestoreMarker.self, from: data) {
                let backupFiles = URL(fileURLWithPath: marker.backupRootPath)
                    .appendingPathComponent("files", isDirectory: true)
                for name in sidecarDirs {
                    let src = backupFiles.appendingPathComponent(name, isDirectory: true)
                    guard fm.fileExists(atPath: src.path) else { continue }
                    let dest = support.appendingPathComponent(name, isDirectory: true)
                    try? fm.removeItem(at: dest)
                    try? fm.copyItem(at: src, to: dest)
                }
            }
            try? fm.removeItem(at: markerURL)
            UserDefaults.standard.set(true, forKey: "backup.restoreCompleted")
            log.info("Restore applied from staged snapshot")
        } catch {
            // Leave the live DB untouched; drop the marker so we don't loop.
            log.error("Restore consume failed, booting existing DB: \(error.localizedDescription)")
            try? fm.removeItem(at: markerURL)
        }
    }

    // MARK: - Engine helpers (nonisolated)

    private struct Counts { var meetings = 0; var transcripts = 0; var decisions = 0; var tasks = 0 }

    private nonisolated static func gatherCounts(database: AppDatabase) async throws -> Counts {
        try await database.writer.read { db in
            var c = Counts()
            c.meetings = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM meeting") ?? 0
            c.transcripts = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcript") ?? 0
            c.decisions = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM decision") ?? 0
            c.tasks = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM actionItem WHERE deletedAt IS NULL") ?? 0
            return c
        }
    }

    /// One markdown file per meeting (title, date, summary, transcript), written
    /// under `transcripts/<yyyy-MM>/`. Incremental: skips a meeting whose file
    /// exists and is newer than the meeting's `updatedAt`.
    private nonisolated static func exportMarkdown(root: URL, database: AppDatabase) async throws -> Counts {
        let fm = FileManager.default
        let outRoot = root.appendingPathComponent("transcripts", isDirectory: true)
        try fm.createDirectory(at: outRoot, withIntermediateDirectories: true)
        let export = ExportService()

        let meetings = try await MeetingRepository(database: database).allActiveMeetings()
        var counts = try await gatherCounts(database: database)

        let monthFmt = DateFormatter()
        monthFmt.dateFormat = "yyyy-MM"
        monthFmt.locale = Locale(identifier: "en_US_POSIX")
        let dayFmt = DateFormatter()
        dayFmt.dateFormat = "yyyy-MM-dd"
        dayFmt.locale = Locale(identifier: "en_US_POSIX")

        for meeting in meetings {
            let monthDir = outRoot.appendingPathComponent(monthFmt.string(from: meeting.effectiveDate), isDirectory: true)
            try? fm.createDirectory(at: monthDir, withIntermediateDirectories: true)
            let safeTitle = meeting.title.replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
            let fileURL = monthDir.appendingPathComponent("\(dayFmt.string(from: meeting.effectiveDate)) - \(safeTitle).md")

            // Incremental: skip if the file is newer than the meeting's last change.
            if let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
               let mtime = attrs[.modificationDate] as? Date, mtime >= meeting.updatedAt {
                continue
            }

            var body = "# \(meeting.title)\n\n_\(DateFormatting.fullDateTime(from: meeting.effectiveDate))_\n\n"
            if let summary = try? await SummaryRepository(database: database).latestSummary(meetingId: meeting.id),
               !summary.summaryText.isEmpty {
                body += export.exportSummaryMarkdown(meeting: meeting, summary: summary) + "\n\n"
            }
            let transcripts = (try? await TranscriptRepository(database: database).transcriptsForMeeting(meeting.id)) ?? []
            if !transcripts.isEmpty {
                body += "## Transcript\n\n" + export.exportTranscriptText(meeting: meeting, transcripts: transcripts) + "\n"
            }
            try? body.data(using: .utf8)?.write(to: fileURL, options: .atomic)
        }
        return counts
    }

    /// Incrementally mirror the recordings dir + the video dir into the backup's
    /// `media/` folder. Skips files already present with the same byte size.
    private nonisolated static func copyMediaIncremental(support: URL, recordingsDir: URL, root: URL,
                                                         progress: (Double) -> Void) throws {
        let fm = FileManager.default
        let sources: [(URL, String)] = [
            (recordingsDir, "Audio"),
            (support.appendingPathComponent("video", isDirectory: true), "video")
        ]
        // Collect the work-list first so progress is meaningful.
        var jobs: [(src: URL, dest: URL)] = []
        for (srcDir, destName) in sources {
            guard fm.fileExists(atPath: srcDir.path) else { continue }
            let destDir = root.appendingPathComponent("media", isDirectory: true).appendingPathComponent(destName, isDirectory: true)
            let items = (try? fm.contentsOfDirectory(at: srcDir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            for item in items where item.hasDirectoryPath == false {
                jobs.append((item, destDir.appendingPathComponent(item.lastPathComponent)))
            }
        }
        guard !jobs.isEmpty else { progress(1); return }
        for (i, job) in jobs.enumerated() {
            try fm.createDirectory(at: job.dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            let srcSize = (try? job.src.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
            let destSize = (try? job.dest.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -2
            if srcSize != destSize {
                try? fm.removeItem(at: job.dest)
                try fm.copyItem(at: job.src, to: job.dest)
            }
            progress(Double(i + 1) / Double(jobs.count))
        }
    }

    private nonisolated static func replaceDirectory(from src: URL, to dest: URL) throws {
        let fm = FileManager.default
        let tmp = dest.deletingLastPathComponent()
            .appendingPathComponent(".inprogress-\(dest.lastPathComponent)")
        try? fm.removeItem(at: tmp)
        try fm.copyItem(at: src, to: tmp)
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: tmp, to: dest)
    }

    private nonisolated static func verifyIntegrity(of dbURL: URL) throws {
        var config = Configuration()
        config.readonly = true
        let queue = try DatabaseQueue(path: dbURL.path, configuration: config)
        let result = try queue.read { db in try String.fetchOne(db, sql: "PRAGMA integrity_check") }
        guard result == "ok" else { throw BackupError.integrityFailed(result ?? "unknown") }
    }

    private nonisolated static func appliedMigrationIds(database: AppDatabase) async throws -> [String] {
        try await database.writer.read { db in
            (try? String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")) ?? []
        }
    }

    private nonisolated static func latestSnapshot(in root: URL) -> URL? {
        let dbDir = root.appendingPathComponent("db", isDirectory: true)
        let items = (try? FileManager.default.contentsOfDirectory(at: dbDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return items
            .filter { $0.pathExtension == "sqlite" && $0.lastPathComponent.hasPrefix("db-") }
            .max { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let dbb = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da < dbb
            }
    }

    private nonisolated static func pruneOldSnapshots(in dbDir: URL, keeping: Int) {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: dbDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let snapshots = items
            .filter { $0.pathExtension == "sqlite" && $0.lastPathComponent.hasPrefix("db-") }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let dbb = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da > dbb
            }
        for old in snapshots.dropFirst(keeping) { try? fm.removeItem(at: old) }
    }

    private nonisolated static func resolveRoot(_ folder: URL) -> URL {
        // Accept either the destination folder or the MeetingManagerBackup folder itself.
        if folder.lastPathComponent == BackupManifest.backupFolderName { return folder }
        let nested = folder.appendingPathComponent(BackupManifest.backupFolderName, isDirectory: true)
        if FileManager.default.fileExists(atPath: nested.appendingPathComponent(BackupManifest.fileName).path) {
            return nested
        }
        return folder
    }

    private nonisolated static func probeWritable(_ dir: URL) -> Error? {
        let probe = dir.appendingPathComponent(".mm-write-probe")
        do {
            try "ok".data(using: .utf8)?.write(to: probe)
            try? FileManager.default.removeItem(at: probe)
            return nil
        } catch { return error }
    }

    private nonisolated static func appVersionString() -> String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "unknown"
    }

    /// Filesystem-safe timestamp. Avoids `:` (illegal on some filesystems).
    private nonisolated static func fileStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }
}

enum BackupError: LocalizedError {
    case noSnapshot
    case integrityFailed(String)
    case newerSchema([String])

    var errorDescription: String? {
        switch self {
        case .noSnapshot:
            return "This folder doesn't contain a Meeting Manager database snapshot."
        case .integrityFailed(let detail):
            return "The database snapshot failed its integrity check (\(detail))."
        case .newerSchema(let ids):
            return "This backup was made by a newer version of Meeting Manager (unknown changes: \(ids.joined(separator: ", "))). Update the app before restoring."
        }
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}

import Foundation
import GRDB
import os

/// Writes meeting summaries and transcripts back to the user's Knowledge Base
/// folder so they're searchable alongside other personal docs.
///
/// Output path: <KB root>/Meeting Notes/YYYY/MM-Month/DD/Meeting Title.md
/// The file is idempotent — calling it twice for the same meeting overwrites
/// the existing file, so re-running a summary regeneration stays in sync.
@MainActor
final class KBWriteBackService {

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.meetingmanager.app",
                                category: "KBWriteBack")

    static let shared = KBWriteBackService()
    private init() {}

    /// Tail of the in-flight write chain per meeting id (TASK-133). `writeMeeting`
    /// is `@MainActor` but suspends four times (cleaned transcript, decisions,
    /// prior export record, reindex), so two exports for the same meeting used to
    /// interleave: the pass that read the *older* confirmed-decision set could
    /// finish last, leaving the canonical note missing the newest decision — with
    /// a stored hash matching that stale content, so no later pass self-corrected
    /// it. The adjacent interleaving (one pass reading the hash the other had not
    /// yet written) minted a spurious "Title (update <date>).md" fork instead.
    ///
    /// Per-meeting rather than global so an unrelated meeting's export is never
    /// held up, and chained inside the service rather than debounced at the
    /// notification sink because the racing writes come from three different call
    /// sites (post-summary export, KB backfill, decision re-export) that no single
    /// debounce can cover.
    private var writeChain: [String: Task<Void, Never>] = [:]

    // MARK: - Write

    /// Write a meeting's summary + cleaned transcript to the KB folder.
    /// Silently no-ops if no KB root is configured.
    ///
    /// Serialized per meeting id — see `writeChain`. Concurrent callers for the
    /// same meeting complete in call order; callers for different meetings still
    /// run concurrently.
    func writeMeeting(
        _ meeting: Meeting,
        summary: String,
        transcript: [Transcript]
    ) async {
        let predecessor = writeChain[meeting.id]
        let write = Task {
            await predecessor?.value
            await self.performWrite(meeting, summary: summary, transcript: transcript)
        }
        writeChain[meeting.id] = write
        await write.value
        // Only the tail clears the slot — a caller that enqueued behind us must
        // keep its predecessor handle reachable.
        if writeChain[meeting.id] == write { writeChain[meeting.id] = nil }
    }

    /// The actual export. Prefers the cleaned transcript blob when available —
    /// that's what users see in the app, and what they expect to find in their
    /// KB. Falls back to a stitched-on-the-fly version of the raw segments when
    /// no cleaned blob exists yet (e.g. cleanup task hasn't run).
    private func performWrite(
        _ meeting: Meeting,
        summary: String,
        transcript: [Transcript]
    ) async {
        guard let root = KnowledgeBaseService.shared.rootURL else {
            logger.debug("KBWriteBack: no KB root configured — skipping")
            return
        }

        let fileURL = outputURL(for: meeting, root: root)

        // Resolve the cleaned transcript text. Three sources, in order:
        //   1. The persisted CleanedTranscript blob (preferred — matches UI)
        //   2. An on-the-fly stitch of the raw segments (no AI, no DB read)
        //   3. Empty (no transcript at all)
        let cleanedText = await resolveCleanedText(meetingId: meeting.id, fallback: transcript)

        // Confirmed decisions only — suggestions stay in the inbox until the
        // user blesses them, so the KB note (and KB-grounded chat) only sees
        // decisions the user vouched for (TASK-129).
        let decisions = (try? await DecisionRepository(database: AppDatabase.shared)
            .decisionsForMeetings([meeting.id], confirmedOnly: true)) ?? []

        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let content = buildMarkdown(meeting: meeting, summary: summary,
                                        cleanedText: cleanedText, decisions: decisions)

            // No-op short-circuit: a user mutation that didn't change the
            // confirmed set (dismissing a suggestion, owner fix on an
            // unconfirmed row) rebuilds identical content — skip the rewrite
            // AND the addendum path entirely.
            let priorRecord = try? await KBExportRepository(database: AppDatabase.shared)
                .record(meetingId: meeting.id)
            if let priorRecord, priorRecord.contentHash == EmbeddingService.hash(content) {
                logger.info("KBWriteBack: content unchanged for \(meeting.id, privacy: .public) — skipping rewrite")
                return
            }

            // Never clobber a user-edited note (TASK-050): if the file on
            // disk no longer matches what WE last wrote (content hash from
            // kbExport), the user touched it — write a dated addendum file
            // instead and leave their edits alone.
            var targetURL = fileURL
            let repo = KBExportRepository(database: AppDatabase.shared)
            if let prior = priorRecord,
               FileManager.default.fileExists(atPath: prior.filePath),
               let onDisk = try? String(contentsOfFile: prior.filePath, encoding: .utf8),
               EmbeddingService.hash(onDisk) != prior.contentHash {
                let stamp = Date().formatted(.iso8601.year().month().day())
                let base = fileURL.deletingPathExtension().lastPathComponent
                targetURL = fileURL.deletingLastPathComponent()
                    .appendingPathComponent("\(base) (update \(stamp)).md")
                logger.info("KBWriteBack: \(prior.filePath, privacy: .public) was edited externally — writing addendum instead")
            }

            try content.write(to: targetURL, atomically: true, encoding: .utf8)
            try? await repo.upsert(KBExportRecord(
                meetingId: meeting.id, filePath: targetURL.path,
                exportedAt: Date(), contentHash: EmbeddingService.hash(content)
            ))
            logger.info("KBWriteBack: wrote \(targetURL.path, privacy: .public)")

            await KnowledgeBaseService.shared.reindexFile(url: targetURL)
        } catch {
            logger.error("KBWriteBack: failed to write \(fileURL.path, privacy: .public): \(error.localizedDescription)")
        }
    }

    /// Look up the cleaned blob; if absent, synthesize one from raw segments
    /// so the KB always gets a readable transcript even when cleanup hasn't
    /// run yet (e.g. user pushes mid-recording, or AI cleanup is queued).
    private func resolveCleanedText(meetingId: String, fallback: [Transcript]) async -> String {
        if let cleaned = try? await CleanedTranscriptRepository().cleanedTranscript(meetingId: meetingId),
           !cleaned.text.isEmpty {
            return cleaned.text
        }
        guard !fallback.isEmpty else { return "" }
        let stitched = TranscriptCleanupService.stitch(fallback)
        return TranscriptCleanupService.renderMarkdown(stitched)
    }

    // MARK: - Path

    func outputURL(for meeting: Meeting, root: URL) -> URL {
        // Memos (TASK-052) live in their own folder, not under Meeting Notes.
        if meeting.isMemo {
            let dir = root.appendingPathComponent("Memos", isDirectory: true)
            let safe = meeting.title.replacingOccurrences(of: "/", with: "-")
            return dir.appendingPathComponent("\(safe).md")
        }
        let date = meeting.startDate ?? meeting.scheduledStartDate ?? Date()

        let cal = Calendar.current
        let year  = cal.component(.year,  from: date)
        let month = cal.component(.month, from: date)
        let day   = cal.component(.day,   from: date)

        let monthFormatter = DateFormatter()
        monthFormatter.dateFormat = "MM-MMMM"   // "04-April"
        let monthDir = monthFormatter.string(from: date)

        let dayDir = String(format: "%02d", day)
        let safeTitle = sanitizeFilename(meeting.title)

        return root
            .appendingPathComponent("Meeting Notes")
            .appendingPathComponent(String(year))
            .appendingPathComponent(monthDir)
            .appendingPathComponent(dayDir)
            .appendingPathComponent("\(safeTitle).md")
    }

    // MARK: - Markdown builder

    func buildMarkdown(
        meeting: Meeting,
        summary: String,
        cleanedText: String,
        decisions: [Decision] = []
    ) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .long
        dateFormatter.timeStyle = .short

        let dateStr: String
        if let start = meeting.startDate ?? meeting.scheduledStartDate {
            dateStr = dateFormatter.string(from: start)
        } else {
            dateStr = "Unknown date"
        }

        let participants = meeting.participantList.isEmpty
            ? "Not recorded"
            : meeting.participantList.joined(separator: ", ")

        // YAML front-matter (TASK-050): stable identifiers so Obsidian-style
        // tooling can link notes back to meetings, and the indexer/exporter
        // can recognize our own files. Stripped from FTS/embedding chunks.
        let iso = ISO8601DateFormatter()
        let frontMatter = [
            "---",
            "meetingId: \(meeting.id)",
            "date: \((meeting.startDate ?? meeting.scheduledStartDate).map { iso.string(from: $0) } ?? "")",
            "attendees: \(meeting.participantList.joined(separator: ", "))",
            "seriesKey: \(MeetingFolder.normaliseTitle(meeting.title))",
            "source: Meeting Manager",
            "---",
            "",
        ].joined(separator: "\n")

        var lines: [String] = [
            frontMatter + "# \(meeting.title)",
            "",
            "**Date:** \(dateStr)  ",
            "**Duration:** \(meeting.formattedDuration)  ",
            "**Participants:** \(participants)  ",
            "",
        ]

        if !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines += [
                "## Summary",
                "",
                summary.trimmingCharacters(in: .whitespacesAndNewlines),
                "",
            ]
        }

        // Confirmed decisions (TASK-129). Each line: the statement, who owns it,
        // the meeting date, and an indented rationale. Makes decisions visible
        // to KB-grounded chat without a separate index.
        if !decisions.isEmpty {
            lines += ["## Decisions", ""]
            let dayFormatter = DateFormatter()
            dayFormatter.dateStyle = .long
            let decisionDate = (meeting.startDate ?? meeting.scheduledStartDate).map { dayFormatter.string(from: $0) }
            for decision in decisions {
                var meta: [String] = []
                if let owner = decision.ownerName?.trimmingCharacters(in: .whitespacesAndNewlines), !owner.isEmpty {
                    meta.append("decided by \(owner)")
                }
                if let decisionDate { meta.append(decisionDate) }
                var head = "- **\(decision.title)**"
                if !meta.isEmpty { head += " (\(meta.joined(separator: ", ")))" }
                lines.append(head)
                if let rationale = decision.rationale?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !rationale.isEmpty {
                    lines.append("  \(rationale)")
                }
            }
            lines.append("")
        }

        let trimmedTranscript = cleanedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTranscript.isEmpty {
            lines += [
                "## Transcript",
                "",
                trimmedTranscript,
                "",
            ]
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    private func sanitizeFilename(_ title: String) -> String {
        // Replace characters not safe in filenames
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let safe = title
            .components(separatedBy: forbidden)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return safe.isEmpty ? "Meeting" : String(safe.prefix(80))
    }
}

// MARK: - Export state (TASK-050, migration v49)

/// What we last wrote for a meeting — the content hash is the conflict
/// detector (mtime is unreliable across atomic renames; review B1).
struct KBExportRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "kbExport"
    var meetingId: String
    var filePath: String
    var exportedAt: Date
    var contentHash: String
}

final class KBExportRepository {
    private let database: AppDatabase
    init(database: AppDatabase) { self.database = database }

    func record(meetingId: String) async throws -> KBExportRecord? {
        try await database.writer.read { db in
            try KBExportRecord.fetchOne(db, key: meetingId)
        }
    }

    func upsert(_ record: KBExportRecord) async throws {
        try await database.writer.write { db in
            try record.save(db)
        }
    }
}

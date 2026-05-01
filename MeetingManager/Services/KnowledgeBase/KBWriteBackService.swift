import Foundation
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

    // MARK: - Write

    /// Write a meeting's summary (and optional transcript) to the KB folder.
    /// Silently no-ops if no KB root is configured.
    func writeMeeting(
        _ meeting: Meeting,
        summary: String,
        transcript: [Transcript]
    ) async {
        guard let root = KnowledgeBaseService.shared.rootURL else {
            logger.debug("KBWriteBack: no KB root configured — skipping")
            return
        }

        let fileURL = outputURL(for: meeting, root: root)

        do {
            // Create parent directories
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let content = buildMarkdown(meeting: meeting, summary: summary, transcript: transcript)
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            logger.info("KBWriteBack: wrote \(fileURL.path, privacy: .public)")

            // Re-index just this file so it's immediately searchable.
            await KnowledgeBaseService.shared.reindexFile(url: fileURL)
        } catch {
            logger.error("KBWriteBack: failed to write \(fileURL.path, privacy: .public): \(error.localizedDescription)")
        }
    }

    // MARK: - Path

    func outputURL(for meeting: Meeting, root: URL) -> URL {
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

    private func buildMarkdown(
        meeting: Meeting,
        summary: String,
        transcript: [Transcript]
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

        var lines: [String] = [
            "# \(meeting.title)",
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

        if !transcript.isEmpty {
            lines += [
                "## Transcript",
                "",
            ]
            for seg in transcript {
                let ts = seg.formattedTimestamp
                let speaker = seg.speakerLabel ?? "Speaker"
                lines.append("**[\(ts)] \(speaker):** \(seg.text)")
            }
            lines.append("")
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

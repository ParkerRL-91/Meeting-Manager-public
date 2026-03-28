import Foundation
#if canImport(AppKit)
import AppKit
#endif
import UniformTypeIdentifiers
import os

/// Formats meeting data for export as Markdown or plain text.
final class ExportService {

    // MARK: - Export Methods

    /// Export summary as formatted Markdown.
    func exportSummaryMarkdown(meeting: Meeting, summary: MeetingSummary) -> String {
        var lines: [String] = []

        lines.append("# \(meeting.title)")
        lines.append("")
        lines.append("**Date:** \(DateFormatting.fullDateTime(from: meeting.effectiveDate))")
        if let duration = meeting.duration {
            lines.append("**Duration:** \(DateFormatting.meetingDuration(from: duration))")
        }
        lines.append("")
        lines.append("---")
        lines.append("")
        lines.append("## Summary")
        lines.append("")
        lines.append(summary.summaryText)

        return lines.joined(separator: "\n")
    }

    /// Export transcript as plain text with timestamps and speakers.
    func exportTranscriptText(meeting: Meeting, transcripts: [Transcript]) -> String {
        var lines: [String] = []

        lines.append("\(meeting.title) - Transcript")
        lines.append("Date: \(DateFormatting.fullDateTime(from: meeting.effectiveDate))")
        if let duration = meeting.duration {
            lines.append("Duration: \(DateFormatting.meetingDuration(from: duration))")
        }
        lines.append("")
        lines.append("---")
        lines.append("")

        for transcript in transcripts {
            lines.append("[\(transcript.formattedTimestamp)] \(transcript.speakerDisplayName): \(transcript.text)")
        }

        return lines.joined(separator: "\n")
    }

    /// Export full report combining summary, transcript, and notes.
    func exportFullReport(
        meeting: Meeting,
        summary: MeetingSummary?,
        transcripts: [Transcript],
        notes: [MeetingNote]
    ) -> String {
        var lines: [String] = []

        lines.append("# \(meeting.title)")
        lines.append("")
        lines.append("**Date:** \(DateFormatting.fullDateTime(from: meeting.effectiveDate))")
        if let duration = meeting.duration {
            lines.append("**Duration:** \(DateFormatting.meetingDuration(from: duration))")
        }
        lines.append("")
        lines.append("---")

        // Summary section
        if let summary {
            lines.append("")
            lines.append("## Summary")
            lines.append("")
            lines.append(summary.summaryText)
            lines.append("")
            lines.append("---")
        }

        // Transcript section
        if !transcripts.isEmpty {
            lines.append("")
            lines.append("## Transcript")
            lines.append("")
            for transcript in transcripts {
                lines.append("[\(transcript.formattedTimestamp)] \(transcript.speakerDisplayName): \(transcript.text)")
            }
            lines.append("")
            lines.append("---")
        }

        // Notes section
        if !notes.isEmpty {
            lines.append("")
            lines.append("## Notes")
            lines.append("")
            for note in notes {
                lines.append(note.content)
                lines.append("")
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - File Export

    /// Save string content to file via NSSavePanel.
    @MainActor
    func saveToFile(content: String, suggestedName: String, fileType: String) async -> Bool {
        #if canImport(AppKit)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [fileType == "md" ? UTType.text : UTType.plainText]

        let result = await panel.begin()
        guard result == .OK, let url = panel.url else { return false }

        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            Logger.general.error("Failed to export file: \(error.localizedDescription)")
            return false
        }
        #else
        return false
        #endif
    }

    // MARK: - Helpers

    /// Sanitize a meeting title for use as a filename.
    static func sanitizedFilename(from title: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        let sanitized = title.unicodeScalars.filter { allowed.contains($0) }
        let result = String(String.UnicodeScalarView(sanitized))
            .replacingOccurrences(of: " ", with: "-")
            .lowercased()
        return result.isEmpty ? "meeting-export" : result
    }
}

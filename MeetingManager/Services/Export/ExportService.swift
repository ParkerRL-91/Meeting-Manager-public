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

        let userName = NSFullUserName()
        for transcript in transcripts {
            let speaker = transcript.displayedSpeakerName(meeting: meeting, userDisplayName: userName)
            lines.append("[\(transcript.formattedTimestamp)] \(speaker): \(transcript.text)")
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
            let userName = NSFullUserName()
            for transcript in transcripts {
                let speaker = transcript.displayedSpeakerName(meeting: meeting, userDisplayName: userName)
                lines.append("[\(transcript.formattedTimestamp)] \(speaker): \(transcript.text)")
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

    // MARK: - HTML Export

    /// Generate a self-contained HTML page representing the meeting.
    /// Inline CSS uses the app's dark colour palette so it's readable when
    /// opened directly in a browser.
    func generateHTML(
        meeting: Meeting,
        summary: MeetingSummary?,
        transcripts: [Transcript],
        notes: [MeetingNote],
        actionItems: [TaskItem]
    ) -> String {
        let title = htmlEscape(meeting.title)
        let dateLine = htmlEscape(DateFormatting.fullDateTime(from: meeting.effectiveDate))
        let durationLine: String = {
            if let duration = meeting.duration {
                return "<span class=\"meta-pill\">\(htmlEscape(DateFormatting.meetingDuration(from: duration)))</span>"
            }
            return ""
        }()

        let participantsHTML: String = {
            let list = meeting.participantList
            guard !list.isEmpty else { return "" }
            let chips = list.map { "<span class=\"participant\">\(htmlEscape($0))</span>" }
                .joined(separator: " ")
            return "<div class=\"participants\">\(chips)</div>"
        }()

        let summaryHTML: String = {
            guard let summary else { return "" }
            let body = htmlEscape(summary.summaryText)
                .replacingOccurrences(of: "\n", with: "<br>")
            return """
            <section>
              <h2>Summary</h2>
              <div class="summary-body">\(body)</div>
            </section>
            """
        }()

        let actionItemsHTML: String = {
            guard !actionItems.isEmpty else { return "" }
            let rows = actionItems.map { item -> String in
                var meta: [String] = []
                if let assignee = item.assignee, !assignee.isEmpty {
                    meta.append(htmlEscape(assignee))
                }
                if let due = item.dueDate {
                    meta.append("due " + htmlEscape(DateFormatting.relativeDate(from: due)))
                }
                let metaSpan = meta.isEmpty ? "" : "<span class=\"ai-meta\"> — \(meta.joined(separator: " · "))</span>"
                let checked = item.isCompleted ? "checked" : ""
                let lineClass = item.isCompleted ? " ai-done" : ""
                return """
                <li class="ai-row\(lineClass)">
                  <input type="checkbox" disabled \(checked)>
                  <span class="ai-title">\(htmlEscape(item.title))</span>\(metaSpan)
                </li>
                """
            }.joined(separator: "\n")
            return """
            <section>
              <h2>Action Items</h2>
              <ul class="action-items">\(rows)</ul>
            </section>
            """
        }()

        let notesHTML: String = {
            guard !notes.isEmpty else { return "" }
            let blocks = notes.map { note in
                "<div class=\"note\">\(htmlEscape(note.content).replacingOccurrences(of: "\n", with: "<br>"))</div>"
            }.joined(separator: "\n")
            return """
            <section>
              <h2>Notes</h2>
              \(blocks)
            </section>
            """
        }()

        let transcriptHTML: String = {
            guard !transcripts.isEmpty else { return "" }
            let userName = NSFullUserName()
            let rows = transcripts.map { t in
                let speaker = t.displayedSpeakerName(meeting: meeting, userDisplayName: userName)
                return """
                <div class="t-row">
                  <span class="t-time">[\(htmlEscape(t.formattedTimestamp))]</span>
                  <span class="t-speaker">\(htmlEscape(speaker))</span>
                  <span class="t-text">\(htmlEscape(t.text))</span>
                </div>
                """
            }.joined(separator: "\n")
            return """
            <section>
              <details>
                <summary><h2 style="display:inline">Transcript</h2></summary>
                <div class="transcript">\(rows)</div>
              </details>
            </section>
            """
        }()

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="UTF-8">
          <title>\(title)</title>
          <style>
            :root {
              --bg: #0f1115;
              --surface: #1a1d24;
              --surface-2: #232730;
              --text: #e6e8ec;
              --text-secondary: #a0a4ad;
              --text-tertiary: #6b6f78;
              --accent: #5b8def;
              --separator: #2a2e38;
              --success: #3ea36b;
            }
            * { box-sizing: border-box; }
            body {
              margin: 0;
              padding: 32px 0;
              background: var(--bg);
              color: var(--text);
              font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;
              font-size: 15px;
              line-height: 1.55;
            }
            .container { max-width: 760px; margin: 0 auto; padding: 0 24px; }
            h1 {
              font-size: 28px;
              font-weight: 600;
              margin: 0 0 8px;
              color: var(--text);
            }
            h2 {
              font-size: 16px;
              font-weight: 600;
              margin: 0 0 12px;
              color: var(--text);
              text-transform: uppercase;
              letter-spacing: 0.04em;
            }
            .meta {
              color: var(--text-secondary);
              font-size: 13px;
              display: flex;
              align-items: center;
              gap: 12px;
              flex-wrap: wrap;
              margin-bottom: 20px;
            }
            .meta-pill {
              background: var(--surface-2);
              padding: 2px 8px;
              border-radius: 999px;
              font-size: 12px;
            }
            .participants { margin-bottom: 24px; }
            .participant {
              display: inline-block;
              background: var(--surface);
              border: 1px solid var(--separator);
              padding: 4px 10px;
              border-radius: 999px;
              font-size: 12px;
              margin-right: 6px;
              margin-bottom: 4px;
              color: var(--text-secondary);
            }
            section {
              background: var(--surface);
              border-radius: 10px;
              padding: 20px 22px;
              margin-bottom: 16px;
            }
            .summary-body { color: var(--text); }
            ul.action-items { list-style: none; padding: 0; margin: 0; }
            ul.action-items li {
              display: flex;
              align-items: flex-start;
              gap: 10px;
              padding: 6px 0;
              border-bottom: 1px solid var(--separator);
            }
            ul.action-items li:last-child { border-bottom: none; }
            ul.action-items input[type="checkbox"] {
              margin-top: 4px;
              accent-color: var(--accent);
            }
            .ai-meta { color: var(--text-secondary); font-size: 13px; }
            .ai-done .ai-title { text-decoration: line-through; color: var(--text-tertiary); }
            .note {
              background: var(--surface-2);
              padding: 10px 12px;
              border-radius: 6px;
              margin-bottom: 8px;
              white-space: pre-wrap;
            }
            details > summary { cursor: pointer; list-style: none; }
            details > summary::-webkit-details-marker { display: none; }
            details > summary::before {
              content: "▸";
              color: var(--text-tertiary);
              margin-right: 8px;
              transition: transform 0.15s;
              display: inline-block;
            }
            details[open] > summary::before { transform: rotate(90deg); }
            .transcript { margin-top: 12px; }
            .t-row {
              display: grid;
              grid-template-columns: 80px 140px 1fr;
              gap: 12px;
              padding: 4px 0;
              font-size: 13px;
            }
            .t-time { color: var(--text-tertiary); font-variant-numeric: tabular-nums; }
            .t-speaker { color: var(--accent); font-weight: 500; }
            .t-text { color: var(--text); }
            footer {
              text-align: center;
              color: var(--text-tertiary);
              font-size: 12px;
              margin-top: 24px;
            }
          </style>
        </head>
        <body>
          <div class="container">
            <h1>\(title)</h1>
            <div class="meta">
              <span>\(dateLine)</span>
              \(durationLine)
            </div>
            \(participantsHTML)
            \(summaryHTML)
            \(actionItemsHTML)
            \(notesHTML)
            \(transcriptHTML)
            <footer>Generated by Meeting Manager</footer>
          </div>
        </body>
        </html>
        """
    }

    /// Write the HTML to a sandbox-friendly cache directory and open it in the
    /// user's default browser. Returns the file URL that was opened.
    @discardableResult
    func writeHTMLAndOpen(
        meeting: Meeting,
        summary: MeetingSummary?,
        transcripts: [Transcript],
        notes: [MeetingNote],
        actionItems: [TaskItem]
    ) throws -> URL {
        let html = generateHTML(
            meeting: meeting,
            summary: summary,
            transcripts: transcripts,
            notes: notes,
            actionItems: actionItems
        )

        let fm = FileManager.default
        let cacheRoot = try fm.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let previewDir = cacheRoot
            .appendingPathComponent("com.meetingmanager.app", isDirectory: true)
            .appendingPathComponent("previews", isDirectory: true)
        try fm.createDirectory(at: previewDir, withIntermediateDirectories: true)

        let filename = ExportService.sanitizedFilename(from: meeting.title) + ".html"
        let url = previewDir.appendingPathComponent(filename)
        try html.write(to: url, atomically: true, encoding: .utf8)

        #if canImport(AppKit)
        NSWorkspace.shared.open(url)
        #endif

        return url
    }

    // MARK: - Helpers

    /// Escape characters reserved in HTML text.
    private func htmlEscape(_ s: String) -> String {
        var out = s
        out = out.replacingOccurrences(of: "&", with: "&amp;")
        out = out.replacingOccurrences(of: "<", with: "&lt;")
        out = out.replacingOccurrences(of: ">", with: "&gt;")
        out = out.replacingOccurrences(of: "\"", with: "&quot;")
        out = out.replacingOccurrences(of: "'", with: "&#39;")
        return out
    }

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

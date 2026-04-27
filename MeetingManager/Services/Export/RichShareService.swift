import Foundation
#if canImport(AppKit)
import AppKit
#endif
import os

/// Builds an `NSAttributedString` from a meeting's summary + action items
/// and copies it to the pasteboard with both plain-text (`.string`) and
/// rich-text (`.rtf`) types so it pastes well into Mail / Slack / Notion /
/// Google Docs / etc.
@MainActor
final class RichShareService {

    /// Copy the meeting summary + action items as rich text.
    /// Returns `true` on success, `false` if AppKit is unavailable or the
    /// pasteboard write fails.
    @discardableResult
    func copyAsRichText(
        meeting: Meeting,
        summary: MeetingSummary,
        actionItems: [ActionItem]
    ) -> Bool {
        #if canImport(AppKit)
        let attributed = buildAttributedString(
            meeting: meeting,
            summary: summary,
            actionItems: actionItems
        )
        let plain = buildPlainText(
            meeting: meeting,
            summary: summary,
            actionItems: actionItems
        )

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        // Declare both types so consumers can pick what they handle best.
        pasteboard.declareTypes([.rtf, .string], owner: nil)

        var success = pasteboard.setString(plain, forType: .string)

        if let rtfData = try? attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        ) {
            success = pasteboard.setData(rtfData, forType: .rtf) && success
        } else {
            Logger.general.error("RichShareService: failed to encode RTF data")
            success = false
        }

        return success
        #else
        return false
        #endif
    }

    // MARK: - Builders

    #if canImport(AppKit)
    private func buildAttributedString(
        meeting: Meeting,
        summary: MeetingSummary,
        actionItems: [ActionItem]
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()

        // Title (heading)
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 20, weight: .bold),
            .foregroundColor: NSColor.labelColor
        ]
        result.append(NSAttributedString(string: meeting.title + "\n", attributes: titleAttrs))

        // Date subtitle
        let subtitleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        result.append(NSAttributedString(
            string: DateFormatting.fullDateTime(from: meeting.effectiveDate) + "\n\n",
            attributes: subtitleAttrs
        ))

        // Summary heading
        let h2Attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ]
        result.append(NSAttributedString(string: "Summary\n", attributes: h2Attrs))

        // Body text
        let bodyAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.labelColor
        ]
        result.append(NSAttributedString(
            string: summary.summaryText + "\n\n",
            attributes: bodyAttrs
        ))

        // Action Items heading + bulleted list
        if !actionItems.isEmpty {
            result.append(NSAttributedString(string: "Action Items\n", attributes: h2Attrs))

            let bulletParagraph = NSMutableParagraphStyle()
            bulletParagraph.headIndent = 18
            bulletParagraph.firstLineHeadIndent = 0
            bulletParagraph.paragraphSpacing = 2

            var bulletAttrs = bodyAttrs
            bulletAttrs[.paragraphStyle] = bulletParagraph

            for item in actionItems {
                var line = "•  \(item.title)"
                if let assignee = item.assignee, !assignee.isEmpty {
                    line += " — \(assignee)"
                }
                if let due = item.dueDate {
                    line += " (due \(DateFormatting.relativeDate(from: due)))"
                }
                line += "\n"
                result.append(NSAttributedString(string: line, attributes: bulletAttrs))
            }
        }

        return result
    }
    #endif

    private func buildPlainText(
        meeting: Meeting,
        summary: MeetingSummary,
        actionItems: [ActionItem]
    ) -> String {
        var lines: [String] = []
        lines.append(meeting.title)
        lines.append(DateFormatting.fullDateTime(from: meeting.effectiveDate))
        lines.append("")
        lines.append("Summary")
        lines.append(summary.summaryText)
        if !actionItems.isEmpty {
            lines.append("")
            lines.append("Action Items")
            for item in actionItems {
                var line = "• \(item.title)"
                if let assignee = item.assignee, !assignee.isEmpty {
                    line += " — \(assignee)"
                }
                if let due = item.dueDate {
                    line += " (due \(DateFormatting.relativeDate(from: due)))"
                }
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n")
    }
}

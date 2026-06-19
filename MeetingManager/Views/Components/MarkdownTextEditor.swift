import SwiftUI
import AppKit

/// Formatting actions a toolbar can ask `MarkdownTextEditor` to apply to the
/// current selection / cursor. Inline commands wrap the selection in markers;
/// block commands prefix the current line(s).
enum MarkdownFormatCommand: Equatable {
    case bold          // **…**
    case italic        // *…*
    case code          // `…`
    case heading       // toggle "## " on the line
    case bulletList    // "- " line prefix
    case quote         // "> " line prefix
    case link          // [selection](url)
}

/// `NSTextView`-backed editor that styles Markdown inline as the user types
/// (source mode — syntax characters stay visible, formatted content gets
/// styled). Designed for meeting notes: serif by default, with looser line
/// height than UI text.
///
/// Supports: `# heading` (1–6 levels), `**bold**`, `*italic*`, `` `code` ``,
/// `> quote`, `- bullet`, `1. numbered`, `[text](url)`, `~~strike~~`,
/// `- [ ]` / `- [x]` checkboxes, and `---` horizontal rules.
///
/// Cursor and selection are preserved across re-style passes because we only
/// mutate `textStorage` attributes, never the underlying string.
struct MarkdownTextEditor: NSViewRepresentable {
    @Binding var text: String
    var isEditable: Bool = true
    var baseFontSize: CGFloat = 15
    var textColor: NSColor = .labelColor
    var insets: NSSize = NSSize(width: 4, height: 8)
    /// Optional callback fired after the text changes (in addition to the binding).
    /// Useful for side-effects like /action parsing that the parent owns.
    var onTextChange: ((String) -> Void)? = nil
    /// A formatting command set by an external toolbar. The editor applies it to
    /// the current selection on the next `updateNSView` and resets it to nil.
    var command: Binding<MarkdownFormatCommand?>? = nil

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }

        textView.delegate = context.coordinator
        textView.allowsUndo = true
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.usesFindBar = true
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textContainerInset = insets
        textView.font = context.coordinator.baseFont
        textView.textColor = textColor

        // Seed initial content via attributed string so we can style immediately
        // without an extra layout pass.
        let initial = NSMutableAttributedString(
            string: text,
            attributes: context.coordinator.baseAttributes()
        )
        textView.textStorage?.setAttributedString(initial)
        context.coordinator.applyMarkdownStyling(to: textView)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        textView.isEditable = isEditable

        // Apply a pending toolbar command, then clear it. Done before the text
        // sync so the command's mutation is what the binding picks up.
        if let cmdBinding = command, let cmd = cmdBinding.wrappedValue {
            context.coordinator.apply(cmd, to: textView)
            DispatchQueue.main.async { cmdBinding.wrappedValue = nil }
        }

        // Only replace the text when the binding changed externally — never when
        // the text view is the source of truth (would clobber undo + selection).
        if textView.string != text {
            let selection = textView.selectedRanges
            let attributed = NSMutableAttributedString(
                string: text,
                attributes: context.coordinator.baseAttributes()
            )
            textView.textStorage?.setAttributedString(attributed)
            // Restore selection if still in range
            let length = (textView.string as NSString).length
            let safe: [NSValue] = selection.compactMap { value in
                let r = value.rangeValue
                guard r.location <= length else { return nil }
                let clamped = NSRange(location: r.location, length: min(r.length, length - r.location))
                return NSValue(range: clamped)
            }
            if !safe.isEmpty { textView.selectedRanges = safe }
            context.coordinator.applyMarkdownStyling(to: textView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownTextEditor

        init(parent: MarkdownTextEditor) {
            self.parent = parent
        }

        var baseFont: NSFont {
            // Serif (New York) at the configured size — matches the rest of the
            // notes UI.
            let descriptor = NSFontDescriptor(fontAttributes: [
                .family: "New York",
            ])
            return NSFont(descriptor: descriptor, size: parent.baseFontSize)
                ?? .systemFont(ofSize: parent.baseFontSize)
        }

        func baseAttributes() -> [NSAttributedString.Key: Any] {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 4
            return [
                .font: baseFont,
                .foregroundColor: parent.textColor,
                .paragraphStyle: paragraph,
            ]
        }

        // MARK: NSTextViewDelegate

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            // Forward to the binding *first* so any onChange observers see the
            // new text before we restyle. Restyling only mutates attributes, so
            // this is safe (no risk of clobbering an in-flight edit).
            let newString = textView.string
            if parent.text != newString {
                parent.text = newString
            }
            parent.onTextChange?(newString)
            applyMarkdownStyling(to: textView)
        }

        // MARK: - Toolbar commands

        /// Apply a formatting command to the text view's current selection,
        /// routing through `insertText`/`shouldChangeText` so undo and the
        /// binding stay correct. Inline commands wrap the selection (or insert
        /// empty markers at the cursor); block commands toggle a line prefix.
        func apply(_ command: MarkdownFormatCommand, to textView: NSTextView) {
            let ns = textView.string as NSString
            let selection = textView.selectedRange()

            switch command {
            case .bold:    wrapSelection(textView, ns: ns, range: selection, marker: "**")
            case .italic:  wrapSelection(textView, ns: ns, range: selection, marker: "*")
            case .code:    wrapSelection(textView, ns: ns, range: selection, marker: "`")
            case .heading: toggleLinePrefix(textView, ns: ns, range: selection, prefix: "## ")
            case .bulletList: toggleLinePrefix(textView, ns: ns, range: selection, prefix: "- ")
            case .quote:   toggleLinePrefix(textView, ns: ns, range: selection, prefix: "> ")
            case .link:    insertLink(textView, ns: ns, range: selection)
            }

            // Push the mutated string through the binding + restyle.
            let newString = textView.string
            if parent.text != newString { parent.text = newString }
            parent.onTextChange?(newString)
            applyMarkdownStyling(to: textView)
        }

        private func wrapSelection(_ textView: NSTextView, ns: NSString, range: NSRange, marker: String) {
            let selected = ns.substring(with: range)
            let replacement = marker + selected + marker
            guard textView.shouldChangeText(in: range, replacementString: replacement) else { return }
            textView.replaceCharacters(in: range, with: replacement)
            textView.didChangeText()
            // Put the cursor between the markers when nothing was selected,
            // otherwise leave the whole wrapped run selected.
            if selected.isEmpty {
                textView.setSelectedRange(NSRange(location: range.location + (marker as NSString).length, length: 0))
            } else {
                textView.setSelectedRange(NSRange(location: range.location, length: (replacement as NSString).length))
            }
        }

        private func toggleLinePrefix(_ textView: NSTextView, ns: NSString, range: NSRange, prefix: String) {
            let lineRange = ns.lineRange(for: range)
            let line = ns.substring(with: lineRange)
            let stripped = line.hasSuffix("\n") ? String(line.dropLast()) : line
            let newLine: String
            if stripped.hasPrefix(prefix) {
                newLine = String(stripped.dropFirst(prefix.count)) + (line.hasSuffix("\n") ? "\n" : "")
            } else {
                newLine = prefix + line
            }
            guard textView.shouldChangeText(in: lineRange, replacementString: newLine) else { return }
            textView.replaceCharacters(in: lineRange, with: newLine)
            textView.didChangeText()
            let delta = (newLine as NSString).length - lineRange.length
            textView.setSelectedRange(NSRange(location: max(lineRange.location, range.location + delta), length: 0))
        }

        private func insertLink(_ textView: NSTextView, ns: NSString, range: NSRange) {
            let selected = ns.substring(with: range)
            let text = selected.isEmpty ? "link text" : selected
            let replacement = "[\(text)](url)"
            guard textView.shouldChangeText(in: range, replacementString: replacement) else { return }
            textView.replaceCharacters(in: range, with: replacement)
            textView.didChangeText()
            // Select the "url" placeholder so the user can type the destination.
            let urlOffset = ("[\(text)](" as NSString).length
            textView.setSelectedRange(NSRange(location: range.location + urlOffset, length: 3))
        }

        // MARK: - Markdown styling

        /// Re-style the entire text storage. Only attributes change — characters
        /// and the cursor are untouched.
        func applyMarkdownStyling(to textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            let nsString = storage.string as NSString
            let fullRange = NSRange(location: 0, length: nsString.length)
            guard fullRange.length > 0 else { return }

            storage.beginEditing()
            storage.setAttributes(baseAttributes(), range: fullRange)

            // Block-level passes (operate on full lines) — order matters where
            // patterns could overlap.
            styleHeadings(storage)
            styleBlockQuotes(storage)
            styleCheckboxes(storage)
            styleBulletPrefixes(storage)
            styleNumberedPrefixes(storage)
            styleHorizontalRule(storage)

            // Inline passes (apply over already-block-styled ranges).
            styleInlineCode(storage)
            styleBoldRuns(storage)
            styleItalicRuns(storage)
            styleStrikethrough(storage)
            styleLinks(storage)

            storage.endEditing()
        }

        // MARK: Block patterns

        private func styleHeadings(_ storage: NSMutableAttributedString) {
            // Up to six `#` followed by space, then heading content to end of line.
            let pattern = #"^(#{1,6})\s+(.+)$"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return }
            let range = NSRange(location: 0, length: storage.length)
            regex.enumerateMatches(in: storage.string, options: [], range: range) { match, _, _ in
                guard let match, match.numberOfRanges >= 3 else { return }
                let hashRange = match.range(at: 1)
                let level = hashRange.length
                let lineRange = match.range

                let bumped: CGFloat
                switch level {
                case 1: bumped = parent.baseFontSize + 9
                case 2: bumped = parent.baseFontSize + 6
                case 3: bumped = parent.baseFontSize + 3
                case 4: bumped = parent.baseFontSize + 2
                case 5: bumped = parent.baseFontSize + 1
                default: bumped = parent.baseFontSize
                }

                let bold = NSFontManager.shared.convert(
                    NSFont(descriptor: baseFont.fontDescriptor, size: bumped) ?? .boldSystemFont(ofSize: bumped),
                    toHaveTrait: .boldFontMask
                )
                storage.addAttribute(.font, value: bold, range: lineRange)
                // Dim the leading `#` characters so they read as scaffolding.
                storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: hashRange)
            }
        }

        private func styleBlockQuotes(_ storage: NSMutableAttributedString) {
            let pattern = #"^>\s+(.+)$"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return }
            let range = NSRange(location: 0, length: storage.length)
            regex.enumerateMatches(in: storage.string, options: [], range: range) { match, _, _ in
                guard let match else { return }
                let lineRange = match.range
                let italic = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
                storage.addAttribute(.font, value: italic, range: lineRange)
                storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: lineRange)

                // Indent the quote line with a left margin
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineSpacing = 4
                paragraph.headIndent = 16
                paragraph.firstLineHeadIndent = 16
                storage.addAttribute(.paragraphStyle, value: paragraph, range: lineRange)
            }
        }

        private func styleBulletPrefixes(_ storage: NSMutableAttributedString) {
            // `- `, `* `, or `+ ` at the start of a line (not part of a checkbox)
            let pattern = #"^([\-\*\+])\s"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return }
            let range = NSRange(location: 0, length: storage.length)
            regex.enumerateMatches(in: storage.string, options: [], range: range) { match, _, _ in
                guard let match else { return }
                let bulletRange = match.range(at: 1)
                storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: bulletRange)
            }
        }

        private func styleNumberedPrefixes(_ storage: NSMutableAttributedString) {
            let pattern = #"^(\d+\.)\s"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return }
            let range = NSRange(location: 0, length: storage.length)
            regex.enumerateMatches(in: storage.string, options: [], range: range) { match, _, _ in
                guard let match else { return }
                let numRange = match.range(at: 1)
                storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: numRange)
            }
        }

        private func styleCheckboxes(_ storage: NSMutableAttributedString) {
            // `- [ ] ` open and `- [x] ` / `- [X] ` checked
            let openPattern = #"^-\s\[\s\]\s"#
            let donePattern = #"^-\s\[[xX]\]\s"#
            let range = NSRange(location: 0, length: storage.length)
            if let regex = try? NSRegularExpression(pattern: openPattern, options: [.anchorsMatchLines]) {
                regex.enumerateMatches(in: storage.string, options: [], range: range) { match, _, _ in
                    guard let match else { return }
                    storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: match.range)
                }
            }
            if let regex = try? NSRegularExpression(pattern: donePattern, options: [.anchorsMatchLines]) {
                regex.enumerateMatches(in: storage.string, options: [], range: range) { match, _, _ in
                    guard let match else { return }
                    storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: match.range)
                    // Strike through the entire line content past the marker
                    let lineEnd = (storage.string as NSString).range(
                        of: "\n",
                        options: [],
                        range: NSRange(location: match.range.upperBound,
                                       length: storage.length - match.range.upperBound)
                    )
                    let endLoc = lineEnd.location == NSNotFound ? storage.length : lineEnd.location
                    let bodyRange = NSRange(location: match.range.upperBound, length: endLoc - match.range.upperBound)
                    if bodyRange.length > 0 {
                        storage.addAttributes([
                            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                            .foregroundColor: NSColor.tertiaryLabelColor,
                        ], range: bodyRange)
                    }
                }
            }
        }

        private func styleHorizontalRule(_ storage: NSMutableAttributedString) {
            let pattern = #"^---+$"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return }
            let range = NSRange(location: 0, length: storage.length)
            regex.enumerateMatches(in: storage.string, options: [], range: range) { match, _, _ in
                guard let match else { return }
                storage.addAttributes([
                    .foregroundColor: NSColor.tertiaryLabelColor,
                    .kern: 2,
                ], range: match.range)
            }
        }

        // MARK: Inline patterns

        private func styleInlineCode(_ storage: NSMutableAttributedString) {
            // `code` — single backticks, no newlines inside
            let pattern = #"`([^`\n]+)`"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return }
            let range = NSRange(location: 0, length: storage.length)
            let monoFont = NSFont.monospacedSystemFont(ofSize: parent.baseFontSize - 0.5, weight: .regular)
            regex.enumerateMatches(in: storage.string, options: [], range: range) { match, _, _ in
                guard let match else { return }
                let backtickRange1 = NSRange(location: match.range.location, length: 1)
                let backtickRange2 = NSRange(location: match.range.upperBound - 1, length: 1)
                let inner = match.range(at: 1)
                storage.addAttribute(.font, value: monoFont, range: match.range)
                storage.addAttribute(.foregroundColor, value: NSColor.systemPink, range: inner)
                storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: backtickRange1)
                storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: backtickRange2)
            }
        }

        private func styleBoldRuns(_ storage: NSMutableAttributedString) {
            // **bold** — pair of double asterisks, no newlines, must contain
            // visible content. Matches non-greedily so nested asterisks don't bleed.
            let pattern = #"\*\*([^*\n]+?)\*\*"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return }
            let range = NSRange(location: 0, length: storage.length)
            regex.enumerateMatches(in: storage.string, options: [], range: range) { match, _, _ in
                guard let match else { return }
                // Don't override heading-level fonts already present on this run —
                // get the existing font first and bold *that*.
                if let existing = storage.attribute(.font, at: match.range.location, effectiveRange: nil) as? NSFont {
                    let bold = NSFontManager.shared.convert(existing, toHaveTrait: .boldFontMask)
                    storage.addAttribute(.font, value: bold, range: match.range)
                }
                let leading = NSRange(location: match.range.location, length: 2)
                let trailing = NSRange(location: match.range.upperBound - 2, length: 2)
                storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: leading)
                storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: trailing)
            }
        }

        private func styleItalicRuns(_ storage: NSMutableAttributedString) {
            // *italic* or _italic_ — single delimiters. The bold pass runs first
            // and leaves ** intact, so a single * here can't double-match.
            // Use a pattern that excludes `*` inside the delimited content.
            let patterns = [
                #"(?<![\*\w])\*([^*\n]+?)\*(?![\*\w])"#,
                #"(?<![_\w])_([^_\n]+?)_(?![_\w])"#,
            ]
            let range = NSRange(location: 0, length: storage.length)
            for pat in patterns {
                guard let regex = try? NSRegularExpression(pattern: pat, options: []) else { continue }
                regex.enumerateMatches(in: storage.string, options: [], range: range) { match, _, _ in
                    guard let match else { return }
                    if let existing = storage.attribute(.font, at: match.range.location, effectiveRange: nil) as? NSFont {
                        let italic = NSFontManager.shared.convert(existing, toHaveTrait: .italicFontMask)
                        storage.addAttribute(.font, value: italic, range: match.range)
                    }
                    let leading = NSRange(location: match.range.location, length: 1)
                    let trailing = NSRange(location: match.range.upperBound - 1, length: 1)
                    storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: leading)
                    storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: trailing)
                }
            }
        }

        private func styleStrikethrough(_ storage: NSMutableAttributedString) {
            let pattern = #"~~([^~\n]+?)~~"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return }
            let range = NSRange(location: 0, length: storage.length)
            regex.enumerateMatches(in: storage.string, options: [], range: range) { match, _, _ in
                guard let match else { return }
                storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: match.range)
                let leading = NSRange(location: match.range.location, length: 2)
                let trailing = NSRange(location: match.range.upperBound - 2, length: 2)
                storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: leading)
                storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: trailing)
            }
        }

        private func styleLinks(_ storage: NSMutableAttributedString) {
            let pattern = #"\[([^\]\n]+)\]\(([^)\n]+)\)"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return }
            let range = NSRange(location: 0, length: storage.length)
            regex.enumerateMatches(in: storage.string, options: [], range: range) { match, _, _ in
                guard let match, match.numberOfRanges >= 3 else { return }
                let textRange = match.range(at: 1)
                let urlRange = match.range(at: 2)
                let urlString = (storage.string as NSString).substring(with: urlRange)

                storage.addAttribute(.foregroundColor, value: NSColor.linkColor, range: textRange)
                storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: textRange)
                if let url = URL(string: urlString) {
                    storage.addAttribute(.link, value: url, range: textRange)
                }
                // Dim the surrounding markup chars
                let bracketLeading = NSRange(location: match.range.location, length: 1)
                let bracketTrailing = NSRange(location: textRange.upperBound, length: 1)
                let parenLeading = NSRange(location: bracketTrailing.upperBound, length: 1)
                let parenTrailing = NSRange(location: match.range.upperBound - 1, length: 1)
                let urlChrome = NSRange(location: urlRange.location, length: urlRange.length)
                for r in [bracketLeading, bracketTrailing, parenLeading, parenTrailing] {
                    storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: r)
                }
                storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: urlChrome)
            }
        }
    }
}

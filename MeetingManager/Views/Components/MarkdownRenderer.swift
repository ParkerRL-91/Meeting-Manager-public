import SwiftUI

/// Read-only SwiftUI renderer for the same Markdown subset that
/// `MarkdownTextEditor` produces in the live notepad. Used in note-review
/// surfaces where there's no cursor to worry about, so syntax characters can
/// be hidden entirely.
///
/// Supports block-level: `# heading` (1–6), `> quote`, `- bullet`, `1. numbered`,
/// `- [ ] / - [x]` checkboxes, `---` rules, paragraphs.
/// Inline (via `AttributedString(markdown:)`): bold, italic, code, links,
/// strikethrough.
struct MarkdownRenderer: View {
    let text: String
    var baseFontSize: CGFloat = 15

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(parseBlocks().enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: Block) -> some View {
        switch block {
        case .heading(let level, let content):
            Text(inline(content))
                .font(.system(size: headingSize(level), weight: .bold, design: .serif))
                .padding(.top, level <= 2 ? 4 : 2)
        case .paragraph(let content):
            Text(inline(content))
                .font(.system(size: baseFontSize, design: .serif))
                .lineSpacing(5)
        case .quote(let content):
            HStack(alignment: .top, spacing: 8) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 3)
                Text(inline(content))
                    .font(.system(size: baseFontSize, design: .serif).italic())
                    .foregroundStyle(Color.secondary)
                    .lineSpacing(5)
            }
        case .bullet(let content):
            HStack(alignment: .top, spacing: 8) {
                Text("•")
                    .font(.system(size: baseFontSize, design: .serif))
                    .foregroundStyle(Color.secondary)
                Text(inline(content))
                    .font(.system(size: baseFontSize, design: .serif))
                    .lineSpacing(5)
            }
        case .numbered(let n, let content):
            HStack(alignment: .top, spacing: 8) {
                Text("\(n).")
                    .font(.system(size: baseFontSize, design: .serif))
                    .foregroundStyle(Color.secondary)
                    .monospacedDigit()
                Text(inline(content))
                    .font(.system(size: baseFontSize, design: .serif))
                    .lineSpacing(5)
            }
        case .checkbox(let done, let content):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: done ? "checkmark.square.fill" : "square")
                    .foregroundStyle(done ? Color.appAccent : Color.secondary)
                Text(inline(content))
                    .font(.system(size: baseFontSize, design: .serif))
                    .strikethrough(done, color: .secondary)
                    .foregroundStyle(done ? Color.secondary : Color.primary)
                    .lineSpacing(5)
            }
        case .horizontalRule:
            Divider().padding(.vertical, 4)
        }
    }

    // MARK: - Block Parsing

    private enum Block {
        case heading(level: Int, content: String)
        case paragraph(String)
        case quote(String)
        case bullet(String)
        case numbered(Int, String)
        case checkbox(done: Bool, content: String)
        case horizontalRule
    }

    /// Walk the source line-by-line and emit one `Block` per visual unit.
    /// Adjacent paragraph lines are concatenated with a space (soft-wrap style)
    /// so users can hard-wrap their notes without producing extra paragraphs.
    private func parseBlocks() -> [Block] {
        var blocks: [Block] = []
        var paragraphBuffer: [String] = []

        func flushParagraph() {
            guard !paragraphBuffer.isEmpty else { return }
            let joined = paragraphBuffer.joined(separator: " ")
            paragraphBuffer.removeAll()
            if !joined.trimmingCharacters(in: .whitespaces).isEmpty {
                blocks.append(.paragraph(joined))
            }
        }

        for raw in text.components(separatedBy: "\n") {
            let line = raw

            // Empty line — paragraph break
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flushParagraph()
                continue
            }

            // Horizontal rule
            if line.range(of: #"^---+\s*$"#, options: .regularExpression) != nil {
                flushParagraph()
                blocks.append(.horizontalRule)
                continue
            }

            // Heading
            if let match = line.range(of: #"^(#{1,6})\s+"#, options: .regularExpression) {
                flushParagraph()
                let prefix = line[match]
                let level = prefix.filter { $0 == "#" }.count
                let content = String(line[match.upperBound...])
                blocks.append(.heading(level: level, content: content))
                continue
            }

            // Checkbox (must come before generic bullet)
            if let openMatch = line.range(of: #"^-\s\[\s\]\s"#, options: .regularExpression) {
                flushParagraph()
                let content = String(line[openMatch.upperBound...])
                blocks.append(.checkbox(done: false, content: content))
                continue
            }
            if let doneMatch = line.range(of: #"^-\s\[[xX]\]\s"#, options: .regularExpression) {
                flushParagraph()
                let content = String(line[doneMatch.upperBound...])
                blocks.append(.checkbox(done: true, content: content))
                continue
            }

            // Block quote
            if let match = line.range(of: #"^>\s+"#, options: .regularExpression) {
                flushParagraph()
                let content = String(line[match.upperBound...])
                blocks.append(.quote(content))
                continue
            }

            // Bullet
            if let match = line.range(of: #"^[\-\*\+]\s+"#, options: .regularExpression) {
                flushParagraph()
                let content = String(line[match.upperBound...])
                blocks.append(.bullet(content))
                continue
            }

            // Numbered
            if let match = line.range(of: #"^(\d+)\.\s+"#, options: .regularExpression) {
                flushParagraph()
                let prefix = String(line[match])
                let n = Int(prefix.split(separator: ".").first.map(String.init) ?? "0") ?? 0
                let content = String(line[match.upperBound...])
                blocks.append(.numbered(n, content))
                continue
            }

            // Default — paragraph (potentially soft-wrapped)
            paragraphBuffer.append(line)
        }
        flushParagraph()
        return blocks
    }

    // MARK: - Inline Parsing

    /// Use Foundation's built-in markdown parser for inline syntax (bold, italic,
    /// code, link, strike). Falls back to plain text if parsing fails.
    private func inline(_ raw: String) -> AttributedString {
        do {
            return try AttributedString(
                markdown: raw,
                options: AttributedString.MarkdownParsingOptions(
                    interpretedSyntax: .inlineOnlyPreservingWhitespace
                )
            )
        } catch {
            return AttributedString(raw)
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return baseFontSize + 9
        case 2: return baseFontSize + 6
        case 3: return baseFontSize + 3
        case 4: return baseFontSize + 2
        case 5: return baseFontSize + 1
        default: return baseFontSize
        }
    }
}

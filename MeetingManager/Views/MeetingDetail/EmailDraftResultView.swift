import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// Displays a generated follow-up email and offers two actions:
/// - Open in Mail (via `mailto:` URL)
/// - Copy to clipboard
///
/// Parses the recipe response to extract a "Subject:" line, falling back to
/// using the meeting title if the model didn't include one.
struct EmailDraftResultView: View {
    let rawText: String
    let meetingTitle: String

    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    private var parsed: ParsedEmail {
        Self.parse(rawText: rawText, fallbackSubject: "Follow-up: \(meetingTitle)")
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()
                .foregroundStyle(Color.appSeparator)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Subject")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.appTextTertiary)
                        Text(parsed.subject)
                            .font(.body)
                            .foregroundStyle(Color.appTextPrimary)
                            .textSelection(.enabled)
                    }

                    Divider()
                        .foregroundStyle(Color.appSeparator)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Body")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.appTextTertiary)
                        Text(parsed.body)
                            .font(.body)
                            .foregroundStyle(Color.appTextPrimary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding()
            }
        }
        .frame(minWidth: 480, idealWidth: 580, minHeight: 420, idealHeight: 560)
        .background(Color.appBackground)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Follow-Up Email")
                    .font(.title2.bold())
                    .foregroundStyle(Color.appTextPrimary)
                Text(meetingTitle)
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)
            }

            Spacer()

            Button {
                openInMail()
            } label: {
                Label("Open in Mail", systemImage: "envelope")
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.appAccent)

            Button {
                copy()
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.bordered)

            Button("Done") { dismiss() }
                .buttonStyle(.bordered)
        }
        .padding()
    }

    // MARK: - Actions

    private func openInMail() {
        guard let subjectEnc = parsed.subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let bodyEnc = parsed.body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return
        }
        let urlString = "mailto:?subject=\(subjectEnc)&body=\(bodyEnc)"
        guard let url = URL(string: urlString) else { return }
        #if canImport(AppKit)
        NSWorkspace.shared.open(url)
        #endif
    }

    private func copy() {
        let combined = "Subject: \(parsed.subject)\n\n\(parsed.body)"
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(combined, forType: .string)
        #endif
        withAnimation { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(2))
            await MainActor.run { withAnimation { copied = false } }
        }
    }

    // MARK: - Parsing

    struct ParsedEmail: Equatable {
        var subject: String
        var body: String
    }

    static func parse(rawText: String, fallbackSubject: String) -> ParsedEmail {
        // Look for the first non-blank line beginning with "Subject:"
        // (case-insensitive). The remainder of the text — minus that line —
        // is the body. If no Subject line is found, treat the whole input
        // as the body and use the fallback subject.
        let lines = rawText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var subject: String?
        var bodyStart = 0

        for (idx, raw) in lines.enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.lowercased().hasPrefix("subject:") {
                let rest = String(trimmed.dropFirst("subject:".count))
                    .trimmingCharacters(in: .whitespaces)
                subject = rest
                bodyStart = idx + 1
            }
            break
        }

        let bodyLines = Array(lines.dropFirst(bodyStart))
        let body = bodyLines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return ParsedEmail(
            subject: (subject?.isEmpty == false ? subject! : fallbackSubject),
            body: body.isEmpty ? rawText.trimmingCharacters(in: .whitespacesAndNewlines) : body
        )
    }
}

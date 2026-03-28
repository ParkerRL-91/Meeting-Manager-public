import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

struct SummaryView: View {
    let meetingId: String

    @Environment(AppState.self) private var appState
    @State private var summary: MeetingSummary?
    @State private var meeting: Meeting?
    @State private var isLoading = true
    @State private var copiedToClipboard = false
    @State private var copiedMarkdownToClipboard = false

    private let exportService = ExportService()

    var body: some View {
        Group {
            if isLoading {
                Spacer()
                ProgressView()
                Spacer()
            } else if let summary {
                summaryContent(summary)
            } else {
                Spacer()
                EmptyStateView(
                    icon: "doc.text.magnifyingglass",
                    title: "No Summary Generated",
                    subtitle: "A summary will appear here once the meeting is processed."
                )
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            meeting = try? await appState.meetingRepository.find(id: meetingId)
            await loadSummary()
        }
    }

    // MARK: - Summary Content

    @ViewBuilder
    private func summaryContent(_ summary: MeetingSummary) -> some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 12) {
                if let model = summary.modelUsed {
                    Label(model, systemImage: "cpu")
                        .font(.caption)
                        .foregroundStyle(Color.appTextTertiary)
                }

                Text("Generated \(DateFormatting.fullDateTime(from: summary.generatedAt))")
                    .font(.caption)
                    .foregroundStyle(Color.appTextTertiary)

                Spacer()

                Button {
                    copyToClipboard(summary.summaryText)
                } label: {
                    Label(
                        copiedToClipboard ? "Copied" : "Copy",
                        systemImage: copiedToClipboard ? "checkmark" : "doc.on.doc"
                    )
                    .font(.caption)
                    .fontWeight(.medium)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    copyAsMarkdown(summary)
                } label: {
                    Label(
                        copiedMarkdownToClipboard ? "Copied" : "Copy as Markdown",
                        systemImage: copiedMarkdownToClipboard ? "checkmark" : "text.document"
                    )
                    .font(.caption)
                    .fontWeight(.medium)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    // Placeholder for regenerate functionality
                } label: {
                    Label("Regenerate", systemImage: "arrow.clockwise")
                        .font(.caption)
                        .fontWeight(.medium)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()
                .foregroundStyle(Color.appSeparator)

            // Summary text
            ScrollView {
                Text(summary.summaryText)
                    .font(.body)
                    .foregroundStyle(Color.appTextPrimary)
                    .textSelection(.enabled)
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        }
    }

    // MARK: - Actions

    private func loadSummary() async {
        isLoading = true
        defer { isLoading = false }
        summary = try? await appState.summaryRepository.latestSummary(meetingId: meetingId)
    }

    private func copyAsMarkdown(_ summary: MeetingSummary) {
        guard let meeting else { return }
        let markdown = exportService.exportSummaryMarkdown(meeting: meeting, summary: summary)

        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown, forType: .string)
        #endif

        withAnimation {
            copiedMarkdownToClipboard = true
        }

        Task {
            try? await Task.sleep(for: .seconds(2))
            await MainActor.run {
                withAnimation {
                    copiedMarkdownToClipboard = false
                }
            }
        }
    }

    private func copyToClipboard(_ text: String) {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif

        withAnimation {
            copiedToClipboard = true
        }

        Task {
            try? await Task.sleep(for: .seconds(2))
            await MainActor.run {
                withAnimation {
                    copiedToClipboard = false
                }
            }
        }
    }
}

// MARK: - Preview

#Preview("With Summary") {
    SummaryView(meetingId: "preview-1")
        .environment(AppState())
        .frame(width: 600, height: 500)
        .background(Color.appBackground)
}

#Preview("Empty") {
    SummaryView(meetingId: "no-summary")
        .environment(AppState())
        .frame(width: 600, height: 500)
        .background(Color.appBackground)
}

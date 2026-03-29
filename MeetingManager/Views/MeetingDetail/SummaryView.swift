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

    // Editing state
    @State private var isEditing = false
    @State private var editedText = ""
    @State private var errorMessage: String?

    // Regeneration state
    @State private var isRegenerating = false
    @State private var regenerateError: String?

    // History
    @State private var showHistory = false

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
        .errorAlert($errorMessage)
        .task {
            meeting = try? await appState.meetingRepository.find(id: meetingId)
            await loadSummary()
        }
        .sheet(isPresented: $showHistory) {
            SummaryHistoryView(meetingId: meetingId)
                .environment(appState)
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

                if summary.isEdited {
                    Text("Edited")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.appWarning)
                        .clipShape(Capsule())
                }

                Spacer()

                if isEditing {
                    editingToolbar
                } else {
                    standardToolbar(summary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()
                .foregroundStyle(Color.appSeparator)

            // Regeneration overlay or content
            if isRegenerating {
                Spacer()
                VStack(spacing: 12) {
                    ProgressView("Regenerating...")
                        .foregroundStyle(Color.appTextPrimary)
                }
                Spacer()
            } else if let error = regenerateError {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title)
                        .foregroundStyle(Color.appWarning)

                    Text("Regeneration Failed")
                        .font(.headline)
                        .foregroundStyle(Color.appTextPrimary)

                    Text(error)
                        .font(.caption)
                        .foregroundStyle(Color.appTextTertiary)
                        .multilineTextAlignment(.center)

                    Button {
                        regenerateSummary()
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Dismiss") {
                        regenerateError = nil
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(Color.appTextTertiary)
                }
                Spacer()
            } else if isEditing {
                // Editable text
                TextEditor(text: $editedText)
                    .font(.body)
                    .foregroundStyle(Color.appTextPrimary)
                    .scrollContentBackground(.hidden)
                    .lineSpacing(4)
                    .padding(12)
                    .background(Color.appSurface)
            } else {
                // Summary text (read-only)
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
    }

    // MARK: - Toolbars

    @ViewBuilder
    private var editingToolbar: some View {
        Button {
            saveEdit()
        } label: {
            Label("Save", systemImage: "checkmark")
                .font(.caption)
                .fontWeight(.medium)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .tint(Color.appAccent)

        Button {
            isEditing = false
            editedText = ""
        } label: {
            Label("Cancel", systemImage: "xmark")
                .font(.caption)
                .fontWeight(.medium)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    @ViewBuilder
    private func standardToolbar(_ summary: MeetingSummary) -> some View {
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
            isEditing = true
            editedText = summary.summaryText
        } label: {
            Label("Edit", systemImage: "pencil")
                .font(.caption)
                .fontWeight(.medium)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)

        Button {
            regenerateSummary()
        } label: {
            Label("Regenerate", systemImage: "arrow.clockwise")
                .font(.caption)
                .fontWeight(.medium)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)

        Button {
            showHistory = true
        } label: {
            Label("History", systemImage: "clock.arrow.circlepath")
                .font(.caption)
                .fontWeight(.medium)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    // MARK: - Actions

    private func loadSummary() async {
        isLoading = true
        defer { isLoading = false }
        summary = try? await appState.summaryRepository.latestSummary(meetingId: meetingId)
    }

    private func saveEdit() {
        guard var updatedSummary = summary else { return }
        updatedSummary.summaryText = editedText
        updatedSummary.isEdited = true

        Task {
            do {
                try await appState.summaryRepository.update(updatedSummary)
                summary = updatedSummary
                isEditing = false
                editedText = ""
            } catch {
                // Keep editing state on failure so user doesn't lose changes
                errorMessage = "Failed to save edited summary: \(error.localizedDescription)"
            }
        }
    }

    private func regenerateSummary() {
        guard let meeting else { return }

        isRegenerating = true
        regenerateError = nil

        Task {
            do {
                let settings = appState.settings
                let textGenerator: (String, String) async throws -> String
                let modelUsed: String

                if settings.useLocalLLM {
                    // On-device: route through Ollama
                    let ollamaService = appState.ollamaService
                    let ollamaModel = settings.ollamaModel
                    textGenerator = { sys, usr in
                        try await ollamaService.generate(systemPrompt: sys, userPrompt: usr, model: ollamaModel)
                    }
                    modelUsed = "ollama/\(ollamaModel)"
                } else {
                    // Cloud: route through Claude API
                    let claude = ClaudeService()
                    let claudeModel = settings.claudeModel
                    textGenerator = { sys, usr in
                        try await claude.sendMessage(systemPrompt: sys, userPrompt: usr, model: claudeModel)
                    }
                    modelUsed = settings.claudeModel
                }

                let generator = SummaryGenerator()
                let newSummary = try await generator.generateSummary(
                    for: meeting,
                    transcriptRepo: appState.transcriptRepository,
                    noteRepo: appState.noteRepository,
                    summaryRepo: appState.summaryRepository,
                    textGenerator: textGenerator,
                    modelUsed: modelUsed,
                    settings: settings
                )
                summary = newSummary
                isRegenerating = false
            } catch {
                isRegenerating = false
                regenerateError = error.localizedDescription
            }
        }
    }

    private func copyAsMarkdown(_ summary: MeetingSummary) {
        guard let meeting else { return }
        let markdown = exportService.exportSummaryMarkdown(meeting: meeting, summary: summary)
        ShareService.copyToClipboard(markdown)

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
        ShareService.copyToClipboard(text)

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

// #Preview("With Summary") {
//     SummaryView(meetingId: "preview-1")
//         .environment(AppState())
//         .frame(width: 600, height: 500)
//         .background(Color.appBackground)
// }

// #Preview("Empty") {
//     SummaryView(meetingId: "no-summary")
//         .environment(AppState())
//         .frame(width: 600, height: 500)
//         .background(Color.appBackground)
// }

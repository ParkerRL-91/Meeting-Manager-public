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
    @State private var activeTask: Task<Void, Never>?

    // History
    @State private var showHistory = false

    // Empty state
    @State private var transcriptCount = 0
    @State private var recipes: [Recipe] = []
    @State private var selectedRecipe: Recipe? = nil

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
                noSummaryEmptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .errorAlert($errorMessage)
        .onDisappear { activeTask?.cancel() }
        .task {
            meeting = try? await appState.meetingRepository.find(id: meetingId)
            async let summaryLoad: () = loadSummary()
            async let metaLoad: () = loadEmptyStateMeta()
            await summaryLoad
            await metaLoad
        }
        .sheet(isPresented: $showHistory) {
            SummaryHistoryView(meetingId: meetingId)
                .environment(appState)
        }
    }

    // MARK: - No Summary Empty State

    @ViewBuilder
    private var noSummaryEmptyState: some View {
        VStack(spacing: 0) {
            Spacer()
            if transcriptCount == 0 {
                // No transcript — explain why generation isn't possible
                VStack(spacing: 12) {
                    Image(systemName: "waveform.slash")
                        .font(.system(size: 44))
                        .foregroundStyle(.tertiary)
                    Text("No Transcript Available")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("A summary can only be generated from a transcript.\nRecord this meeting to capture audio, then Meeting Manager\nwill transcribe it automatically.")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                }
                .padding(.horizontal, 40)
            } else {
                // Has transcript — show generate button with recipe picker
                VStack(spacing: 20) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 44))
                        .foregroundStyle(.secondary)

                    VStack(spacing: 6) {
                        Text("Ready to Summarize")
                            .font(.title3.weight(.semibold))
                        Text("This meeting has a transcript. Choose a template and generate your summary.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    if isRegenerating {
                        VStack(spacing: 8) {
                            ProgressView()
                            Text("Generating summary…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        // Generate button + recipe dropdown
                        HStack(spacing: 0) {
                            Button {
                                regenerateSummary(recipe: selectedRecipe)
                            } label: {
                                Label(
                                    selectedRecipe == nil ? "Generate Summary" : "Generate: \(selectedRecipe!.name)",
                                    systemImage: "sparkles"
                                )
                                .padding(.horizontal, 4)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.appAccent)
                            .controlSize(.large)

                            Divider()
                                .frame(height: 20)
                                .padding(.horizontal, 2)

                            Menu {
                                Button {
                                    selectedRecipe = nil
                                } label: {
                                    HStack {
                                        Label("Standard Summary", systemImage: "doc.text")
                                        if selectedRecipe == nil {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }

                                if !recipes.isEmpty {
                                    Divider()
                                    ForEach(recipes) { recipe in
                                        Button {
                                            selectedRecipe = recipe
                                        } label: {
                                            HStack {
                                                Label(recipe.name, systemImage: recipe.category.icon)
                                                if selectedRecipe?.id == recipe.id {
                                                    Image(systemName: "checkmark")
                                                }
                                            }
                                        }
                                    }
                                }
                            } label: {
                                Image(systemName: "chevron.down")
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                            }
                            .menuStyle(.borderlessButton)
                            .buttonStyle(.borderedProminent)
                            .tint(Color.appAccent)
                            .controlSize(.large)
                        }

                        if let recipe = selectedRecipe {
                            Text(recipe.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }

                    if let error = regenerateError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }
                }
                .padding(.horizontal, 60)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            regenerateSummary(recipe: selectedRecipe)
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

    private func loadEmptyStateMeta() async {
        let segments = (try? await appState.transcriptRepository.transcriptsForMeeting(meetingId)) ?? []
        transcriptCount = segments.count
        let repo = RecipeRepository(database: appState.database)
        recipes = (try? await repo.allRecipes()) ?? []
    }

    private func loadSummary() async {
        isLoading = true
        defer { isLoading = false }
        summary = try? await appState.summaryRepository.latestSummary(meetingId: meetingId)
    }

    private func saveEdit() {
        guard var updatedSummary = summary else { return }
        updatedSummary.summaryText = editedText
        updatedSummary.isEdited = true

        activeTask = Task {
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

    private func regenerateSummary(recipe: Recipe? = nil) {
        guard let meeting else { return }

        isRegenerating = true
        regenerateError = nil

        activeTask = Task {
            do {
                let settings = appState.settings
                let baseTextGenerator: (String, String) async throws -> String
                let modelUsed: String

                let hasClaudeKey = ((try? KeychainHelper.loadString(forKey: KeychainHelper.Key.claudeAPIKey)) ?? "")?.isEmpty == false
                // Refresh Ollama status so we have a live check, not a stale cached value
                await appState.ollamaService.refreshStatus()
                let ollamaReachable = appState.ollamaService.isReachable

                let useOllama = settings.useLocalLLM || (!hasClaudeKey && ollamaReachable)

                if useOllama {
                    let ollamaService = appState.ollamaService
                    let ollamaModel = settings.ollamaModel  // "auto" or explicit e.g. "llama3.2:3b"
                    baseTextGenerator = { sys, usr in
                        try await ollamaService.generate(systemPrompt: sys, userPrompt: usr, model: ollamaModel)
                    }
                    modelUsed = "ollama/\(ollamaModel)"
                } else if hasClaudeKey {
                    let claude = ClaudeService()
                    let claudeModel = settings.claudeModel
                    baseTextGenerator = { sys, usr in
                        try await claude.sendMessage(systemPrompt: sys, userPrompt: usr, model: claudeModel)
                    }
                    modelUsed = settings.claudeModel
                } else {
                    isRegenerating = false
                    regenerateError = "No AI configured. Enable On-Device AI in Settings → On-Device, or add a Claude API key in Settings → Claude."
                    return
                }

                // If a recipe is selected, override the system prompt with its template
                let textGenerator: (String, String) async throws -> String
                if let recipe {
                    textGenerator = { _, usr in try await baseTextGenerator(recipe.promptTemplate, usr) }
                } else {
                    textGenerator = baseTextGenerator
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

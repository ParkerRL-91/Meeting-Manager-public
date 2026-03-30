import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// Displays the result of running a recipe on a meeting, with options to copy
/// the output, run again, or view a loading state during generation.
struct RecipeResultView: View {
    let recipe: Recipe
    let meetingId: String

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var engine = RecipeEngine()
    @State private var outputText: String = ""
    @State private var meeting: Meeting?
    @State private var hasResult = false
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()
                .foregroundStyle(Color.appSeparator)

            if engine.isProcessing {
                loadingState
            } else if let error = engine.lastError {
                errorState(error)
            } else if hasResult {
                resultContent
            } else {
                readyState
            }
        }
        .frame(minWidth: 480, idealWidth: 560, minHeight: 400, idealHeight: 550)
        .background(Color.appBackground)
        .task {
            meeting = try? await appState.meetingRepository.find(id: meetingId)
            await loadExistingResult()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(recipe.name)
                    .font(.title2.bold())
                    .foregroundStyle(Color.appTextPrimary)

                if let meeting {
                    Text(meeting.title)
                        .font(.caption)
                        .foregroundStyle(Color.appTextSecondary)
                }
            }

            Spacer()

            if hasResult && !engine.isProcessing {
                Button {
                    copyToClipboard()
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.bordered)

                Button {
                    Task { await runRecipe() }
                } label: {
                    Label("Run Again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }

            Button("Done") {
                dismiss()
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }

    // MARK: - Loading State

    private var loadingState: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .scaleEffect(1.2)
            Text("Generating output...")
                .font(.headline)
                .foregroundStyle(Color.appTextSecondary)
            Text("This may take a moment depending on the meeting length.")
                .font(.caption)
                .foregroundStyle(Color.appTextTertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Error State

    private func errorState(_ error: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(Color.appWarning)
            Text("Recipe Failed")
                .font(.headline)
                .foregroundStyle(Color.appTextPrimary)
            Text(error)
                .font(.caption)
                .foregroundStyle(Color.appTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button {
                Task { await runRecipe() }
            } label: {
                Label("Try Again", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Ready State (no result yet)

    private var readyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: recipe.category.icon)
                .font(.system(size: 36))
                .foregroundStyle(Color.appAccent)
            Text("Ready to Run")
                .font(.headline)
                .foregroundStyle(Color.appTextPrimary)
            Text(recipe.description)
                .font(.caption)
                .foregroundStyle(Color.appTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button {
                Task { await runRecipe() }
            } label: {
                Label("Run Recipe", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Result Content

    private var resultContent: some View {
        ScrollView {
            Text(outputText)
                .font(.body)
                .foregroundStyle(Color.appTextPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
    }

    // MARK: - Actions

    private func loadExistingResult() async {
        let resultRepo = RecipeResultRepository(database: appState.database)
        if let existing = try? await resultRepo.latestResult(meetingId: meetingId, recipeId: recipe.id) {
            outputText = existing.outputText
            hasResult = true
        }
    }

    private func runRecipe() async {
        guard let meeting else { return }

        let transcriptRepo = appState.transcriptRepository
        let noteRepo = appState.noteRepository
        let resultRepo = RecipeResultRepository(database: appState.database)

        // Build textGenerator with same AI routing as SummaryView
        let textGenerator: (String, String) async throws -> String
        do {
            let settings = appState.settings
            let hasClaudeKey = ((try? KeychainHelper.loadString(forKey: KeychainHelper.Key.claudeAPIKey)) ?? "")?.isEmpty == false
            await appState.ollamaService.refreshStatus()
            let ollamaReachable = appState.ollamaService.isReachable
            let useOllama = settings.useLocalLLM || (!hasClaudeKey && ollamaReachable)

            if useOllama {
                let ollamaService = appState.ollamaService
                let ollamaModel = settings.ollamaModel
                textGenerator = { sys, usr in
                    try await ollamaService.generate(systemPrompt: sys, userPrompt: usr, model: ollamaModel)
                }
            } else if hasClaudeKey {
                let claude = ClaudeService()
                let claudeModel = settings.claudeModel
                textGenerator = { sys, usr in
                    try await claude.sendMessage(systemPrompt: sys, userPrompt: usr, model: claudeModel)
                }
            } else {
                engine.lastError = "No AI configured. Enable On-Device AI in Settings → On-Device, or add a Claude API key in Settings → Claude."
                return
            }

            let result = try await engine.execute(
                recipe: recipe,
                meeting: meeting,
                transcriptRepo: transcriptRepo,
                noteRepo: noteRepo,
                resultRepo: resultRepo,
                textGenerator: textGenerator
            )
            outputText = result
            hasResult = true
        } catch {
            // Error is already captured in engine.lastError
        }
    }

    private func copyToClipboard() {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(outputText, forType: .string)
        #endif

        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            await MainActor.run { copied = false }
        }
    }
}

// MARK: - Preview

// #Preview("Recipe Result") {
//     RecipeResultView(
//         recipe: Recipe(
//             name: "Follow-Up Email",
//             description: "Draft a follow-up email",
//             promptTemplate: "Test",
//             category: .email,
//             isBuiltIn: true
//         ),
//         meetingId: "preview-1"
//     )
//     .environment(AppState())
//     .frame(width: 560, height: 550)
// }

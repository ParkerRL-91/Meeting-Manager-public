import SwiftUI

struct LocalModelStepView: View {
    @Environment(AppState.self) private var appState
    @State private var ollamaInstalled = false
    @State private var isCheckingOllama = false
    @State private var installError: String?

    /// TASK-082: curated onboarding model choices. The recommended small,
    /// non-thinking model is pushed (pre-selected). Tags are pinned exactly —
    /// the bare `qwen3:4b` (thinking-only) is never offered.
    private struct ModelChoice: Identifiable {
        let id: String          // the exact ollama tag
        let title: String
        let detail: String
        let recommended: Bool
    }
    private let modelChoices: [ModelChoice] = [
        ModelChoice(id: "qwen3:4b-instruct",
                    title: "Qwen3 4B Instruct",
                    detail: "Recommended. About 2.5 GB. Generates summaries directly in seconds.",
                    recommended: true),
        ModelChoice(id: "qwen3:8b",
                    title: "Qwen3 8B",
                    detail: "Higher quality on long meetings. About 5 GB; uses a reasoning step.",
                    recommended: false),
        ModelChoice(id: "qwen2.5:3b-instruct",
                    title: "Qwen2.5 3B Instruct",
                    detail: "Smallest and fastest. About 2 GB; good for shorter meetings.",
                    recommended: false),
    ]

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            Image(systemName: "desktopcomputer")
                .font(.system(size: 56))
                .foregroundStyle(Color.appAccent)

            Text("On-Device AI Setup")
                .font(.largeTitle)
                .fontWeight(.bold)
                .foregroundStyle(Color.appTextPrimary)

            Text("On-device AI uses Ollama to run language models locally on your Mac. No data leaves your computer.")
                .font(.body)
                .foregroundStyle(Color.appTextSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)

            // Requirements notice
            VStack(alignment: .leading, spacing: 12) {
                Label("What you need to know:", systemImage: "info.circle")
                    .font(.headline)
                    .foregroundStyle(Color.appAccent)

                requirementRow(icon: "arrow.down.circle", text: "The on-device AI runtime is downloaded automatically and managed inside Meeting Manager — there is no separate app to install.")
                requirementRow(icon: "memorychip", text: "Recommended: 8 GB+ RAM for smooth performance")
                requirementRow(icon: "clock", text: "The model downloads after you finish onboarding; it may take a few minutes depending on your connection.")
                requirementRow(icon: "lock.shield", text: "All processing happens locally — your meeting data never leaves your Mac")
            }
            .padding(20)
            .background(Color.appSurface)
            .cornerRadius(12)
            .frame(maxWidth: 480)

            // TASK-082: choose a model — the recommended small one is pushed.
            VStack(alignment: .leading, spacing: 10) {
                Label("Choose your on-device model:", systemImage: "cpu")
                    .font(.headline)
                    .foregroundStyle(Color.appAccent)
                ForEach(modelChoices) { choice in
                    modelChoiceRow(choice)
                }
                Text("You can change this anytime in Settings → On-Device.")
                    .font(.caption2)
                    .foregroundStyle(Color.appTextTertiary)
            }
            .padding(20)
            .background(Color.appSurface)
            .cornerRadius(12)
            .frame(maxWidth: 480)

            // Ollama status
            VStack(spacing: 12) {
                if ollamaInstalled {
                    Label("Ollama is installed and ready", systemImage: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(Color.appSuccess)
                } else {
                    Text("Ollama will be set up automatically when you finish onboarding.")
                        .font(.caption)
                        .foregroundStyle(Color.appTextSecondary)
                        .multilineTextAlignment(.center)
                }

                if let error = installError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(Color.appWarning)
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await checkOllamaStatus()
        }
    }

    @ViewBuilder
    private func modelChoiceRow(_ choice: ModelChoice) -> some View {
        @Bindable var appState = appState
        let selected = appState.settings.ollamaModel == choice.id
        Button {
            appState.settings.ollamaModel = choice.id
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.appAccent : Color.appTextTertiary)
                    .font(.subheadline)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(choice.title)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Color.appTextPrimary)
                        if choice.recommended {
                            Text("RECOMMENDED")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Color.appAccent)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.appAccentSubtle)
                                .clipShape(Capsule())
                        }
                    }
                    Text(choice.detail)
                        .font(.caption)
                        .foregroundStyle(Color.appTextSecondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func requirementRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(Color.appTextSecondary)
                .frame(width: 20)

            Text(text)
                .font(.subheadline)
                .foregroundStyle(Color.appTextPrimary)
        }
    }

    private func checkOllamaStatus() async {
        isCheckingOllama = true
        let ollama = OllamaService()
        await ollama.refreshStatus()
        ollamaInstalled = ollama.isReachable
        isCheckingOllama = false
    }
}

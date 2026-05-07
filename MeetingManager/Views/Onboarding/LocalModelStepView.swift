import SwiftUI

struct LocalModelStepView: View {
    @Environment(AppState.self) private var appState
    @State private var ollamaInstalled = false
    @State private var isCheckingOllama = false
    @State private var installError: String?

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

                requirementRow(icon: "arrow.down.circle", text: "Ollama will be downloaded automatically (~60 MB)")
                requirementRow(icon: "internaldrive", text: "The default model (Qwen3 4B) takes about 3 GB of disk space; an 8B model is downloaded in the background for longer meetings.")
                requirementRow(icon: "memorychip", text: "Recommended: 8 GB+ RAM for smooth performance")
                requirementRow(icon: "clock", text: "First download may take a few minutes depending on your connection")
                requirementRow(icon: "lock.shield", text: "All processing happens locally — your meeting data never leaves your Mac")
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

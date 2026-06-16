import SwiftUI

/// Slim status footer shown at the bottom of the sidebar while ANY background
/// model download is in progress. Designed to feel like a native macOS status
/// indicator (think Slack's connection state) — calm, non-blocking, and out
/// of the way of primary navigation.
///
/// Two sources feed this banner today:
///
///   1. **WhisperKit transcription model** — `appState.isLoadingModel` /
///      `appState.modelDownloadProgress`. Triggered automatically on first
///      launch and after Settings → Re-download model.
///
///   2. **Ollama local-LLM tier pulls** — `appState.ollamaInstaller.phase`.
///      Triggered by `verifyLocalModelsOnStartup()` when the user is on the
///      local path and the Qwen3 ladder isn't fully installed yet, or by
///      Settings → AI (Local) → first-time setup.
///
/// When both are active simultaneously (rare — typically only on a fresh
/// install with on-device AI enabled), WhisperKit takes the visible slot
/// because the user can't transcribe without it; the Ollama pull continues
/// silently in the background.
struct ModelDownloadBanner: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Group {
            if appState.isLoadingModel {
                // WhisperKit takes priority when both are active — see doc comment.
                whisperKitBanner
            } else if let pull = ollamaPullStatus {
                ollamaBanner(name: pull.name, progress: pull.progress)
            }
        }
        // Animate the show/hide so the banner fades out the moment the model
        // load completes, instead of snapping away (or worse, sticking at
        // 100% if the visibility flag is briefly stale).
        .animation(.easeInOut(duration: 0.25), value: appState.isLoadingModel)
        .animation(.easeInOut(duration: 0.25), value: ollamaPullStatus?.progress)
    }

    // MARK: - WhisperKit

    private var whisperKitBanner: some View {
        bannerBody(
            icon: "arrow.down.circle",
            title: "Downloading transcription model",
            progress: appState.modelDownloadProgress,
            help: "Recording works now — transcription will start once the model finishes downloading."
        )
    }

    // MARK: - Ollama

    /// Resolves the installer phase to a `(name, progress)` pair when a pull
    /// is in progress, otherwise nil.
    private var ollamaPullStatus: (name: String, progress: Double)? {
        switch appState.ollamaInstaller.phase {
        case .pullingModel(let name, let progress):
            return (name, progress)
        default:
            return nil
        }
    }

    private func ollamaBanner(name: String, progress: Double) -> some View {
        // Friendlier display: "Downloading Qwen3 4B" instead of "qwen3:4b"
        let display = friendlyName(for: name)
        return bannerBody(
            icon: "arrow.down.circle",
            title: "Downloading \(display)",
            progress: progress,
            help: "On-device AI model download — runs in the background. Other features still work."
        )
    }

    private func friendlyName(for ollamaTag: String) -> String {
        // qwen3:4b → "Qwen3 4B"; llama3.1:8b → "Llama 3.1 8B"
        let parts = ollamaTag.split(separator: ":")
        guard parts.count == 2 else { return ollamaTag }
        let base = String(parts[0])
            .replacingOccurrences(of: "qwen3", with: "Qwen3")
            .replacingOccurrences(of: "llama3.2", with: "Llama 3.2")
            .replacingOccurrences(of: "llama3.1", with: "Llama 3.1")
            .replacingOccurrences(of: "phi3", with: "Phi-3")
        // "4b-instruct" → "4B Instruct"; "8b" → "8B".
        let size = String(parts[1]).split(separator: "-").map { seg -> String in
            seg.allSatisfy { $0.isNumber || $0 == "b" } ? seg.uppercased() : seg.capitalized
        }.joined(separator: " ")
        return "\(base) \(size)"
    }

    // MARK: - Shared body

    private func bannerBody(icon: String, title: String, progress: Double, help: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption2)
                    .foregroundStyle(Color.appAccent)
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.appTextSecondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(Int(progress * 100))%")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Color.appTextTertiary)
            }
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .tint(Color.appAccent)
                .scaleEffect(x: 1, y: 0.6, anchor: .center)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.appAccent.opacity(0.06))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.appSeparator.opacity(0.5))
                .frame(height: 0.5)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .animation(.easeInOut(duration: 0.2), value: progress)
        .help(help)
    }
}

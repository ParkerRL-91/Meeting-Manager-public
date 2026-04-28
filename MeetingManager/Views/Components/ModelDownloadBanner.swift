import SwiftUI

/// Slim status footer shown at the bottom of the sidebar while the WhisperKit
/// transcription model downloads in the background. Designed to feel like a
/// native macOS status indicator (think Slack's connection state) — calm,
/// non-blocking, and out of the way of primary navigation.
struct ModelDownloadBanner: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if appState.isLoadingModel {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle")
                        .font(.caption2)
                        .foregroundStyle(Color.appAccent)
                    Text("Downloading model")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.appTextSecondary)
                    Spacer(minLength: 4)
                    Text("\(Int(appState.modelDownloadProgress * 100))%")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Color.appTextTertiary)
                }
                ProgressView(value: appState.modelDownloadProgress)
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
            .animation(.easeInOut(duration: 0.2), value: appState.isLoadingModel)
            .help("Recording works now — transcription will start once the model finishes downloading.")
        }
    }
}

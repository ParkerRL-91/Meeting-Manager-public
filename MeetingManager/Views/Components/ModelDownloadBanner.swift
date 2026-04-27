import SwiftUI

/// Persistent banner shown at the top of HomeView while WhisperKit model downloads.
/// Replaces the blocking onboarding step — user can use the rest of the app while it runs.
struct ModelDownloadBanner: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if appState.isLoadingModel {
            HStack(spacing: 10) {
                ProgressView(value: appState.modelDownloadProgress)
                    .progressViewStyle(.linear)
                    .tint(Color.appAccent)
                    .frame(maxWidth: 120)
                Text("Downloading transcription model… \(Int(appState.modelDownloadProgress * 100))%")
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.appAccent.opacity(0.08))
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(.easeInOut(duration: 0.2), value: appState.isLoadingModel)
        }
    }
}

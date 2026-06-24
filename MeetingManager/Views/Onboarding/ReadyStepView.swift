import SwiftUI
import AVFoundation

struct ReadyStepView: View {
    @Environment(AppState.self) private var appState
    let onComplete: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 64))
                .foregroundStyle(Color.appSuccess)

            Text("You're All Set!")
                .font(.largeTitle)
                .fontWeight(.bold)
                .foregroundStyle(Color.appTextPrimary)

            Text("Here's a summary of your setup:")
                .font(.body)
                .foregroundStyle(Color.appTextSecondary)

            VStack(alignment: .leading, spacing: 12) {
                setupRow(
                    granted: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                    label: "Microphone access"
                )
                setupRow(
                    granted: GoogleAuthManager().isSignedIn,
                    label: "Google Calendar",
                    skippedText: "Not connected"
                )
                setupRow(
                    granted: (try? KeychainHelper.loadString(forKey: KeychainHelper.Key.claudeAPIKey)).flatMap({ $0 }) != nil
                        || (try? KeychainHelper.loadString(forKey: KeychainHelper.Key.geminiAPIKey)).flatMap({ $0 }) != nil,
                    label: "Cloud AI key"
                )
                setupRow(
                    granted: appState.transcriptionService.isModelLoaded,
                    label: "Transcription model",
                    skippedText: appState.isLoadingModel ? "Downloading..." : "Not ready"
                )
            }
            .padding(20)
            .background(Color.appSurface)
            .cornerRadius(12)
            .frame(maxWidth: 360)

            Text("You can change any of these in Settings at any time.")
                .font(.caption)
                .foregroundStyle(Color.appTextTertiary)

            Spacer()

            Button(action: onComplete) {
                Text("Start Using Meeting Manager")
                    .font(.headline)
                    .frame(maxWidth: 300)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.appAccent)

            Spacer()
                .frame(height: 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func setupRow(granted: Bool, label: String, skippedText: String = "Skipped") -> some View {
        HStack(spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "minus.circle")
                .foregroundStyle(granted ? Color.appSuccess : Color.appTextTertiary)

            Text(label)
                .font(.body)
                .foregroundStyle(Color.appTextPrimary)

            Spacer()

            Text(granted ? "Configured" : skippedText)
                .font(.caption)
                .foregroundStyle(granted ? Color.appSuccess : Color.appTextSecondary)
        }
    }
}

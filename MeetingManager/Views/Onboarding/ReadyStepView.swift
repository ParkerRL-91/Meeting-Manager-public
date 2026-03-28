import SwiftUI
import AVFoundation

struct ReadyStepView: View {
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
                    granted: (try? KeychainHelper.loadString(forKey: KeychainHelper.Key.claudeAPIKey)).flatMap({ $0 }) != nil,
                    label: "Claude API key"
                )
                setupRow(
                    granted: false,
                    label: "Google Calendar",
                    skippedText: "Not connected"
                )
            }
            .padding(20)
            .background(Color.appSurface)
            .cornerRadius(12)
            .frame(maxWidth: 360)

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

#Preview {
    ReadyStepView(onComplete: {})
        .frame(width: 600, height: 500)
        .background(Color.appBackground)
        .preferredColorScheme(.dark)
}

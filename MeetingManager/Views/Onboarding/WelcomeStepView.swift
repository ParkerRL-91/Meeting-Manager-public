import SwiftUI
import AVFoundation
import AppKit

/// Combined Welcome + Microphone permission step (P2-T01).
/// Microphone is the only permission needed to start recording — screen recording
/// is requested later, only when the user actually tries to capture system audio.
struct WelcomeStepView: View {
    let onNext: () -> Void

    @State private var microphoneStatus: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "waveform.badge.mic")
                .font(.system(size: 72))
                .foregroundStyle(Color.appAccent)

            Text("Meeting Manager")
                .font(.largeTitle)
                .fontWeight(.bold)
                .foregroundStyle(Color.appTextPrimary)

            Text("Capture, transcribe, and summarize your meetings with AI")
                .font(.title3)
                .foregroundStyle(Color.appTextSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)

            // Microphone permission card
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "mic.fill")
                        .font(.title2)
                        .foregroundStyle(Color.appAccent)
                        .frame(width: 32)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Microphone access")
                            .font(.headline)
                            .foregroundStyle(Color.appTextPrimary)
                        Text("Required to record and transcribe your meetings")
                            .font(.caption)
                            .foregroundStyle(Color.appTextSecondary)
                    }

                    Spacer()

                    Text(microphoneStatusText)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(microphoneStatusColor)
                }

                if microphoneStatus == .notDetermined {
                    Button("Enable Microphone Access") {
                        requestMicrophoneAccess()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.appAccent)
                    .controlSize(.small)
                } else if microphoneStatus == .denied || microphoneStatus == .restricted {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(Color.appWarning)
                        Text("Microphone was denied. Open System Settings to allow it.")
                            .font(.caption)
                            .foregroundStyle(Color.appTextSecondary)
                    }
                    Button("Open Microphone Settings") {
                        openMicrophoneSettings()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(16)
            .background(Color.appSurface)
            .cornerRadius(12)
            .frame(maxWidth: 440)

            Text("Screen-recording permission is requested later, only when you record system audio.")
                .font(.caption)
                .foregroundStyle(Color.appTextTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)

            Spacer()

            Button(action: onNext) {
                Text("Get Started")
                    .font(.headline)
                    .frame(maxWidth: 260)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.appAccent)

            Spacer()
                .frame(height: 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
            // Auto-trigger the OS prompt so users don't have to hunt for the button.
            if microphoneStatus == .notDetermined {
                requestMicrophoneAccess()
            }
        }
    }

    // MARK: - Helpers

    private var microphoneStatusText: String {
        switch microphoneStatus {
        case .authorized: return "Granted"
        case .denied, .restricted: return "Denied"
        case .notDetermined: return "Not Set"
        @unknown default: return "Unknown"
        }
    }

    private var microphoneStatusColor: Color {
        switch microphoneStatus {
        case .authorized: return Color.appSuccess
        case .denied, .restricted: return Color.appRecording
        case .notDetermined: return Color.appWarning
        @unknown default: return Color.appTextSecondary
        }
    }

    private func requestMicrophoneAccess() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in
            DispatchQueue.main.async {
                microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
            }
        }
    }

    private func openMicrophoneSettings() {
        let primary = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        let fallback = "x-apple.systempreferences:"
        if let url = URL(string: primary) {
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open(url, configuration: config) { _, error in
                if error != nil, let fallbackURL = URL(string: fallback) {
                    NSWorkspace.shared.open(fallbackURL)
                }
            }
        }
    }
}

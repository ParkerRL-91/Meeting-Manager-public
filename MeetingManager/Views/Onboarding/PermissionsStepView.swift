import SwiftUI
import AVFoundation

struct PermissionsStepView: View {
    @State private var microphoneStatus: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var screenRecordingGranted: Bool = false
    private let sessionManager = AudioSessionManager()

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: "lock.shield")
                .font(.system(size: 56))
                .foregroundStyle(Color.appAccent)

            Text("Permissions")
                .font(.largeTitle)
                .fontWeight(.bold)
                .foregroundStyle(Color.appTextPrimary)

            Text("Meeting Manager needs these permissions to capture and transcribe your meetings.")
                .font(.body)
                .foregroundStyle(Color.appTextSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)

            VStack(spacing: 0) {
                // Microphone permission
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "mic.fill")
                            .font(.title2)
                            .foregroundStyle(Color.appAccent)
                            .frame(width: 32)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Microphone")
                                .font(.headline)
                                .foregroundStyle(Color.appTextPrimary)
                            Text("Required to capture meeting audio")
                                .font(.caption)
                                .foregroundStyle(Color.appTextSecondary)
                        }

                        Spacer()

                        Text(microphoneStatusText)
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(microphoneStatusColor)
                    }

                    if microphoneStatus == .notDetermined {
                        Button("Grant Access") {
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

                Divider()
                    .background(Color.appSeparator)

                // Screen Recording
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "rectangle.inset.filled.badge.record")
                            .font(.title2)
                            .foregroundStyle(Color.appAccent)
                            .frame(width: 32)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Screen Recording")
                                .font(.headline)
                                .foregroundStyle(Color.appTextPrimary)
                            Text("Captures audio from Zoom, Teams, and other call apps so Meeting Manager can hear all participants.")
                                .font(.caption)
                                .foregroundStyle(Color.appTextSecondary)
                        }

                        Spacer()

                        Text(screenRecordingGranted ? "Granted" : "Not Enabled")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(screenRecordingGranted ? Color.appSuccess : Color.appWarning)
                    }

                    if !screenRecordingGranted {
                        Text("macOS requires you to enable this manually:")
                            .font(.caption)
                            .foregroundStyle(Color.appTextSecondary)

                        VStack(alignment: .leading, spacing: 4) {
                            stepText("1. Click the button below to open System Settings")
                            stepText("2. Find \"Meeting Manager\" in the list")
                            stepText("3. Toggle it on, then come back here")
                        }

                        HStack(spacing: 12) {
                            Button("Open Screen Recording Settings") {
                                openScreenRecordingSettings()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Button("Check Again") {
                                checkScreenRecordingPermission()
                            }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .foregroundStyle(Color.appAccent)
                        }
                    }
                }
                .padding(16)
            }
            .background(Color.appSurface)
            .cornerRadius(12)
            .frame(maxWidth: 500)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
            checkScreenRecordingPermission()
        }
    }

    private func stepText(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(Color.appTextTertiary)
    }

    // MARK: - Status Helpers

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
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
            }
        }
    }

    private func openMicrophoneSettings() {
        openSystemSettings(
            primary: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
            fallback: "x-apple.systempreferences:"
        )
    }

    private func checkScreenRecordingPermission() {
        screenRecordingGranted = sessionManager.hasScreenRecordingPermission()
    }

    private func openScreenRecordingSettings() {
        openSystemSettings(
            primary: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            fallback: "x-apple.systempreferences:"
        )
    }

    /// Open a System Settings URL with fallback to the top-level settings if the
    /// specific deep link fails (URL schemes change across macOS versions).
    private func openSystemSettings(primary: String, fallback: String) {
        if let url = URL(string: primary) {
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open(url, configuration: config) { _, error in
                if error != nil, let fallbackURL = URL(string: fallback) {
                    NSWorkspace.shared.open(fallbackURL)
                }
            }
        } else if let fallbackURL = URL(string: fallback) {
            NSWorkspace.shared.open(fallbackURL)
        }
    }
}

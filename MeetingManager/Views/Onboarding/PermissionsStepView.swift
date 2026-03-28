import SwiftUI
import AVFoundation

struct PermissionsStepView: View {
    @State private var microphoneStatus: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Text("Permissions")
                .font(.largeTitle)
                .fontWeight(.bold)
                .foregroundStyle(Color.appTextPrimary)

            Text("Meeting Manager needs access to audio to capture and transcribe your meetings.")
                .font(.body)
                .foregroundStyle(Color.appTextSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)

            VStack(spacing: 16) {
                // Microphone permission
                permissionRow(
                    icon: "mic.fill",
                    title: "Microphone",
                    description: "Required to capture meeting audio",
                    status: microphoneStatusText,
                    statusColor: microphoneStatusColor,
                    actionLabel: microphoneStatus == .notDetermined ? "Grant Access" : nil,
                    action: requestMicrophoneAccess
                )

                Divider()
                    .background(Color.appSeparator)

                // Screen Recording note
                permissionRow(
                    icon: "rectangle.inset.filled.badge.record",
                    title: "Screen Recording",
                    description: "Needed for system audio capture. Enable in System Settings > Privacy & Security > Screen Recording.",
                    status: "Manual Setup",
                    statusColor: Color.appWarning,
                    actionLabel: "Open System Settings",
                    action: openScreenRecordingSettings
                )
            }
            .padding(20)
            .background(Color.appSurface)
            .cornerRadius(12)
            .frame(maxWidth: 480)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Permission Row

    private func permissionRow(
        icon: String,
        title: String,
        description: String,
        status: String,
        statusColor: Color,
        actionLabel: String?,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(Color.appAccent)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(Color.appTextPrimary)

                    Spacer()

                    Text(status)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(statusColor)
                }

                Text(description)
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)

                if let actionLabel {
                    Button(actionLabel, action: action)
                        .font(.caption)
                        .buttonStyle(.link)
                        .padding(.top, 4)
                }
            }
        }
    }

    // MARK: - Microphone Helpers

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

    private func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

// #Preview {
//     PermissionsStepView()
//         .frame(width: 600, height: 500)
//         .background(Color.appBackground)
//         .preferredColorScheme(.dark)
// }

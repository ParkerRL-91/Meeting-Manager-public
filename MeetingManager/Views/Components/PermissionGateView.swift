import SwiftUI
import AVFoundation
import ScreenCaptureKit
import os

/// Lightweight permission gate shown on every app launch.
///
/// Checks microphone and screen recording permissions. If both are granted,
/// this view is never visible — the user goes straight to the app. If either
/// is missing, it shows a focused prompt to fix it. Once granted, the gate
/// disappears automatically.
///
/// This solves the "works once then keeps asking" problem: even if macOS
/// revokes permissions (e.g. after a system update or code signing change),
/// the user sees a clear fix path immediately instead of a broken app.
struct PermissionGateView: View {
    @Binding var permissionsReady: Bool

    @State private var micGranted = false
    @State private var screenGranted = false
    @State private var checking = true
    @State private var resetMessage: String?

    private let sessionManager = AudioSessionManager()

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "lock.open.fill")
                .font(.system(size: 48))
                .foregroundStyle(Color.appAccent)

            Text("Permissions Needed")
                .font(.title)
                .fontWeight(.bold)
                .foregroundStyle(Color.appTextPrimary)

            Text("Meeting Manager needs these permissions to work.\nThis only takes a moment.")
                .font(.body)
                .foregroundStyle(Color.appTextSecondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 0) {
                // Microphone
                permissionRow(
                    icon: "mic.fill",
                    title: "Microphone",
                    subtitle: "Capture meeting audio",
                    granted: micGranted
                ) {
                    if !micGranted {
                        Button("Grant Access") {
                            requestMicrophone()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.appAccent)
                        .controlSize(.small)
                    }
                }

                Divider().background(Color.appSeparator)

                // Screen Recording
                permissionRow(
                    icon: "rectangle.inset.filled.badge.record",
                    title: "Screen Recording",
                    subtitle: "Hear all meeting participants",
                    granted: screenGranted
                ) {
                    if !screenGranted {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Toggle on Meeting Manager in System Settings:")
                                .font(.caption)
                                .foregroundStyle(Color.appTextTertiary)

                            HStack(spacing: 12) {
                                Button("Open Settings") {
                                    openScreenRecordingSettings()
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(Color.appAccent)
                                .controlSize(.small)

                                Button("Check Again") {
                                    Task { await checkPermissions() }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }
                }
            }
            .background(Color.appSurface)
            .cornerRadius(12)
            .frame(maxWidth: 480)

            // Permissions sometimes show as granted in System Settings yet
            // the app still says they're missing — this happens after an
            // update because macOS TCC ties grants to a binary signature
            // that self-signed builds don't preserve. Reset clears the
            // stale entries so macOS will re-prompt cleanly.
            VStack(spacing: 8) {
                Text("Stuck? If System Settings shows permissions as granted but this screen still asks for them, reset them and try again.")
                    .font(.caption)
                    .foregroundStyle(Color.appTextTertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)

                Button {
                    resetAppPermissions()
                } label: {
                    Label("Reset App Permissions", systemImage: "arrow.counterclockwise.circle")
                        .font(.callout)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if let resetMessage {
                    Text(resetMessage)
                        .font(.caption)
                        .foregroundStyle(resetMessage.starts(with: "✓") ? Color.appSuccess : Color.appWarning)
                }
            }
            .padding(.top, 12)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await checkPermissions()
        }
    }

    // MARK: - Permission Row

    @ViewBuilder
    private func permissionRow<Actions: View>(
        icon: String,
        title: String,
        subtitle: String,
        granted: Bool,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(Color.appAccent)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(Color.appTextPrimary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Color.appTextSecondary)
                }

                Spacer()

                if granted {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Color.appSuccess)
                } else {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Color.appWarning)
                }
            }

            actions()
        }
        .padding(16)
    }

    // MARK: - Permission Checks

    private func checkPermissions() async {
        checking = true

        // Microphone
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        micGranted = (micStatus == .authorized)

        // Screen Recording — use the async ScreenCaptureKit check on macOS 14.2+
        if #available(macOS 14.2, *) {
            screenGranted = await sessionManager.hasScreenRecordingPermissionAsync()
        } else {
            screenGranted = sessionManager.hasScreenRecordingPermission()
        }

        checking = false

        // Both granted → dismiss the gate
        if micGranted && screenGranted {
            withAnimation(.easeOut(duration: 0.3)) {
                permissionsReady = true
            }
        }
    }

    private func requestMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                micGranted = granted
                if granted && screenGranted {
                    withAnimation(.easeOut(duration: 0.3)) {
                        permissionsReady = true
                    }
                }
            }
        }
    }

    private func openScreenRecordingSettings() {
        let primary = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        if let url = URL(string: primary) {
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open(url, configuration: config) { _, error in
                if error != nil, let fallback = URL(string: "x-apple.systempreferences:") {
                    NSWorkspace.shared.open(fallback)
                }
            }
        }
    }

    /// Wipe TCC entries for this app's bundle ID. Equivalent to clicking
    /// the "Reset App Permissions" button in Settings → General →
    /// Troubleshooting, but available right here on the gate where users
    /// most often discover the broken state. Re-runs the permission check
    /// after the reset so the UI reflects the cleared state immediately.
    private func resetAppPermissions() {
        Logger.ui.info("[PermissionGate] resetAppPermissions invoked")
        let services = ["Microphone", "Calendar", "Reminders", "ScreenCapture"]
        var failed: [String] = []
        for service in services {
            let task = Process()
            task.launchPath = "/usr/bin/tccutil"
            task.arguments = ["reset", service, "com.meetingmanager.app"]
            do {
                try task.run()
                task.waitUntilExit()
                if task.terminationStatus != 0 {
                    failed.append(service)
                    Logger.ui.warning("[PermissionGate] tccutil reset \(service, privacy: .public) exited \(task.terminationStatus)")
                }
            } catch {
                failed.append(service)
                Logger.ui.error("[PermissionGate] tccutil reset \(service, privacy: .public) threw: \(error.localizedDescription, privacy: .public)")
            }
        }
        if failed.isEmpty {
            resetMessage = "✓ Permissions cleared. Click Grant Access / Open Settings above to re-grant."
        } else {
            resetMessage = "Reset failed for: \(failed.joined(separator: ", "))"
        }
        // Re-poll so any state changes (e.g. user already had partial grants
        // that got cleared) reflect in the row checkmarks.
        Task { await checkPermissions() }
        // Auto-clear the message after 8s.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            resetMessage = nil
        }
    }
}

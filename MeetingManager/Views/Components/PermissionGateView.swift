import SwiftUI
import AVFoundation
import ScreenCaptureKit
import AppKit
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
///
/// Wraps everything in a `ScrollView` and uses fixed top padding instead of
/// `Spacer()` so the Reset App Permissions button at the bottom is *never*
/// pushed below the visible viewport on shorter windows. Earlier versions
/// hid the recovery button on tall windows because two `Spacer()`s shoved
/// it off-screen.
struct PermissionGateView: View {
    @Binding var permissionsReady: Bool

    @State private var micGranted = false
    @State private var screenGranted = false
    @State private var storageWritable = false
    @State private var checking = true

    private let sessionManager = AudioSessionManager()

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
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
                    Divider().background(Color.appSeparator)

                    // Recording Storage — not a TCC permission, but a launch
                    // readiness condition: the app can't record if it can't
                    // write the WAV. Almost always green (default App Support);
                    // only demands action when the location is unwritable
                    // (e.g. a foreign-owned folder after migrating Macs).
                    permissionRow(
                        icon: "internaldrive.fill",
                        title: "Recording Storage",
                        subtitle: "Save meeting audio to disk",
                        granted: storageWritable
                    ) {
                        if !storageWritable {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("This folder can't be written to. Pick one you own:")
                                    .font(.caption)
                                    .foregroundStyle(Color.appTextTertiary)

                                HStack(spacing: 12) {
                                    Button("Choose Folder…") {
                                        chooseStorageFolder()
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

                // Divider above the recovery affordance — visually separates
                // the primary "do the right thing" flow from the "fix-broken-
                // state" flow. Without it the reset button reads as part of
                // the normal grant flow, which it isn't.
                Divider()
                    .frame(maxWidth: 480)
                    .padding(.top, 4)

                PermissionResetButton(style: .prominent) {
                    Task { await checkPermissions() }
                }
                .frame(maxWidth: 480)
            }
            .padding(.top, 60)
            .padding(.bottom, 40)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)
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

        // Recording storage — probe an actual write (not just dir existence).
        storageWritable = RecordingStorage.shared.isPreferredWritable()

        checking = false

        // All ready → dismiss the gate
        if micGranted && screenGranted && storageWritable {
            withAnimation(.easeOut(duration: 0.3)) {
                permissionsReady = true
            }
        }
    }

    private func requestMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                micGranted = granted
                if granted && screenGranted && storageWritable {
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

    private func chooseStorageFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder where Meeting Manager can save audio recordings."
        panel.prompt = "Use This Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        RecordingStorage.shared.customDirectory = url
        Task { await checkPermissions() }
    }
}

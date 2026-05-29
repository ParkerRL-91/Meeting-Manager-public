import SwiftUI
import AVFoundation
import os

/// Settings view for audio input device selection and permission management.
struct AudioSettingsView: View {

    // MARK: - State

    @Environment(AppState.self) private var appState

    @State private var availableDevices: [AVCaptureDevice] = []
    @State private var hasMicPermission: Bool = false
    @State private var hasScreenRecordingPermission: Bool = false

    private let audioManager = AudioSessionManager()

    /// The microphone auto-detection would currently pick.
    private var autoDetectedDeviceName: String {
        audioManager.bestInputDevice()?.localizedName ?? "system default"
    }

    // MARK: - Body

    var body: some View {
        Form {
            inputDeviceSection
            permissionsSection
        }
        .formStyle(.grouped)
        .onAppear(perform: loadState)
    }

    // MARK: - Sections

    private var inputDeviceSection: some View {
        @Bindable var appState = appState
        return Section {
            Toggle("Override microphone selection", isOn: Binding(
                get: { appState.settings.micOverrideEnabled },
                set: { newValue in
                    appState.settings.micOverrideEnabled = newValue
                    // Pre-fill with the auto-detected device so enabling the
                    // override starts from a sensible, working selection.
                    if newValue, appState.settings.micOverrideDeviceID.isEmpty,
                       let best = audioManager.bestInputDevice() {
                        appState.settings.micOverrideDeviceID = best.uniqueID
                    }
                }
            ))

            if appState.settings.micOverrideEnabled {
                if availableDevices.isEmpty {
                    Text("No audio input devices found")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Microphone", selection: Binding(
                        get: { appState.settings.micOverrideDeviceID },
                        set: { appState.settings.micOverrideDeviceID = $0 }
                    )) {
                        ForEach(availableDevices, id: \.uniqueID) { device in
                            Text(device.localizedName).tag(device.uniqueID)
                        }
                    }
                }
            } else {
                Label("Automatically using \(autoDetectedDeviceName)", systemImage: "wand.and.stars")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Input Device")
        } footer: {
            Text(appState.settings.micOverrideEnabled
                 ? "Recording from the microphone you selected. If it's unplugged or can't capture audio, Meeting Manager falls back to automatic selection so recordings are never silent."
                 : "Meeting Manager automatically selects the best available microphone and adapts when you plug or unplug devices. Turn on the override only if you need to force a specific microphone.")
        }
    }

    private var permissionsSection: some View {
        Section {
            // Microphone permission
            HStack {
                Label {
                    Text("Microphone Access")
                } icon: {
                    Image(systemName: hasMicPermission ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(hasMicPermission ? Color.appSuccess : .red)
                }

                Spacer()

                if hasMicPermission {
                    Text("Granted")
                        .font(.caption)
                        .foregroundStyle(Color.appSuccess)
                } else {
                    Button("Request Permission") {
                        requestMicPermission()
                    }
                    .controlSize(.small)
                }
            }

            // Screen recording permission
            HStack {
                Label {
                    Text("Screen Recording")
                } icon: {
                    Image(systemName: hasScreenRecordingPermission ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(hasScreenRecordingPermission ? Color.appSuccess : .red)
                }

                Spacer()

                if hasScreenRecordingPermission {
                    Text("Granted")
                        .font(.caption)
                        .foregroundStyle(Color.appSuccess)
                } else {
                    Button("Open System Settings") {
                        openScreenRecordingSettings()
                    }
                    .controlSize(.small)
                }
            }

            if !hasMicPermission {
                Button("Open System Settings") {
                    openMicrophoneSettings()
                }
            }
        } header: {
            Text("Permissions")
        } footer: {
            Text("Microphone access is required to capture meeting audio. Screen recording permission is needed to capture system audio from video call apps.")
        }
    }

    // MARK: - Actions

    private func loadState() {
        availableDevices = audioManager.availableInputDevices()
        hasScreenRecordingPermission = audioManager.hasScreenRecordingPermission()

        // Check current mic permission status
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        hasMicPermission = (status == .authorized)
    }

    private func requestMicPermission() {
        Task {
            let granted = await audioManager.requestMicrophonePermission()
            await MainActor.run {
                hasMicPermission = granted
            }
        }
    }

    private func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    private func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Preview

// #Preview("Audio Settings") {
//     AudioSettingsView()
//         .frame(width: 500, height: 400)
// }

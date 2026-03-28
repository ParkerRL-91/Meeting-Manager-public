import SwiftUI
import AVFoundation
import os

/// Settings view for audio input device selection and permission management.
struct AudioSettingsView: View {

    // MARK: - State

    @State private var selectedDeviceID: String = ""
    @State private var availableDevices: [AVCaptureDevice] = []
    @State private var hasMicPermission: Bool = false
    @State private var hasScreenRecordingPermission: Bool = false

    private let audioManager = AudioSessionManager()

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
        Section {
            if availableDevices.isEmpty {
                Text("No audio input devices found")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Input Device", selection: $selectedDeviceID) {
                    ForEach(availableDevices, id: \.uniqueID) { device in
                        Text(device.localizedName).tag(device.uniqueID)
                    }
                }
                .onChange(of: selectedDeviceID) { _, newValue in
                    Logger.audio.info("Selected audio device: \(newValue)")
                }
            }
        } header: {
            Text("Input Device")
        } footer: {
            Text("Select the microphone used for recording meeting audio.")
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
                        .foregroundStyle(hasMicPermission ? .appSuccess : .red)
                }

                Spacer()

                if hasMicPermission {
                    Text("Granted")
                        .font(.caption)
                        .foregroundStyle(.appSuccess)
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
                        .foregroundStyle(hasScreenRecordingPermission ? .appSuccess : .red)
                }

                Spacer()

                if hasScreenRecordingPermission {
                    Text("Granted")
                        .font(.caption)
                        .foregroundStyle(.appSuccess)
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

        // Set default selection
        if let defaultDevice = audioManager.defaultInputDevice() {
            selectedDeviceID = defaultDevice.uniqueID
        } else if let first = availableDevices.first {
            selectedDeviceID = first.uniqueID
        }

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

#Preview("Audio Settings") {
    AudioSettingsView()
        .frame(width: 500, height: 400)
}

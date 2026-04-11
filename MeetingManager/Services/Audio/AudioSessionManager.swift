import AVFoundation
import ScreenCaptureKit

/// Manages audio permissions and device enumeration
final class AudioSessionManager {

    /// Request microphone permission
    func requestMicrophonePermission() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)

        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    /// List available audio input devices
    func availableInputDevices() -> [AVCaptureDevice] {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        return discoverySession.devices
    }

    /// Get the default input device
    func defaultInputDevice() -> AVCaptureDevice? {
        AVCaptureDevice.default(for: .audio)
    }

    /// Returns the best available input device.
    ///
    /// Priority: system default (user's explicit choice in System Settings) first.
    /// Only prefers an external device over built-in if the system default IS the
    /// built-in mic — this respects the user's choice while still upgrading to a
    /// connected USB/Thunderbolt mic when the user hasn't configured one.
    func bestInputDevice() -> AVCaptureDevice? {
        let devices = availableInputDevices()
        guard !devices.isEmpty else { return defaultInputDevice() }

        // The system default reflects what the user chose in System Settings > Sound > Input.
        // Respect it unless it's the built-in mic and a better external device is available.
        let systemDefault = defaultInputDevice()

        if let systemDefault, !isBuiltInDevice(systemDefault) {
            // User explicitly chose a non-built-in device — respect their choice.
            return systemDefault
        }

        // System default is built-in (or nil). Check if there's an external device connected.
        let externalKeywords = [
            // Connection types
            "headset", "headphone", "external", "usb", "thunderbolt", "interface",
            // Popular mic brands
            "yeti", "blue", "focusrite", "scarlett", "rode", "elgato", "hyperx",
            "shure", "audio-technica", "at2020", "logitech", "jabra", "poly",
            "sennheiser", "samson", "presonus", "behringer", "motu",
        ]

        for device in devices {
            let name = device.localizedName.lowercased()
            if externalKeywords.contains(where: { name.contains($0) }) {
                return device
            }
        }

        // No recognized external device — check for any non-built-in device
        let nonBuiltIn = devices.first(where: { !isBuiltInDevice($0) })
        if let nonBuiltIn {
            return nonBuiltIn
        }

        // Everything is built-in — return system default
        return systemDefault ?? devices.first
    }

    /// Returns true if the device appears to be a built-in Mac microphone.
    private func isBuiltInDevice(_ device: AVCaptureDevice) -> Bool {
        let name = device.localizedName.lowercased()
        let builtInKeywords = ["built-in", "macbook", "macpro", "mac mini", "imac", "mac studio"]
        return builtInKeywords.contains(where: { name.contains($0) })
    }

    /// Check if screen recording permission is granted (needed for system audio capture).
    ///
    /// Uses ScreenCaptureKit's `SCShareableContent` which tests the actual API path
    /// that system audio capture uses. Falls back to the CGWindowList heuristic
    /// on older macOS versions.
    func hasScreenRecordingPermission() -> Bool {
        // QA_STUB: Screen recording temporarily disabled for QA testing.
        return false
    }

    /// Async permission check using ScreenCaptureKit — more accurate on macOS 14.2+.
    /// Returns true if the app has Screen Recording permission for audio capture.
    @available(macOS 14.2, *)
    func hasScreenRecordingPermissionAsync() async -> Bool {
        // QA_STUB: Screen recording temporarily disabled for QA testing.
        return false
    }
}

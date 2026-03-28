import AVFoundation

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

    /// Returns the best available input device, preferring external/USB devices over built-in
    func bestInputDevice() -> AVCaptureDevice? {
        let devices = availableInputDevices()

        // Priority order: external/USB > headset > built-in default
        let externalKeywords = ["headset", "headphone", "external", "usb", "thunderbolt", "interface", "yeti", "blue", "focusrite", "scarlett"]
        let builtInKeywords = ["built-in", "macbook", "macpro", "mac mini", "imac"]

        // First try to find a high-quality external device
        for device in devices {
            let name = device.localizedName.lowercased()
            if externalKeywords.contains(where: { name.contains($0) }) {
                return device
            }
        }

        // Avoid built-in if possible, return first non-built-in
        let nonBuiltIn = devices.filter { device in
            let name = device.localizedName.lowercased()
            return !builtInKeywords.contains(where: { name.contains($0) })
        }
        if let first = nonBuiltIn.first {
            return first
        }

        // Fall back to system default
        return defaultInputDevice()
    }

    /// Check if screen recording permission is granted (needed for system audio capture)
    func hasScreenRecordingPermission() -> Bool {
        // Screen recording permission check via CGWindowListCopyWindowInfo
        // If the app can access window info, permission is granted
        let windowList = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]
        return windowList != nil && !(windowList?.isEmpty ?? true)
    }
}

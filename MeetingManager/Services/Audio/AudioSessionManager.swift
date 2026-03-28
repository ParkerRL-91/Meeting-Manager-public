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

    /// Check if screen recording permission is granted (needed for system audio capture)
    func hasScreenRecordingPermission() -> Bool {
        // Screen recording permission check via CGWindowListCopyWindowInfo
        // If the app can access window info, permission is granted
        let windowList = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]
        return windowList != nil && !(windowList?.isEmpty ?? true)
    }
}

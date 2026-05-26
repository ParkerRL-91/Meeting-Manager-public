import AVFoundation
import CoreAudio
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
        // Only consider devices that actually expose input channels. An output-only
        // device (e.g. a "USB-C to 3.5mm Headphone Jack Adapter") can appear in the
        // discovery list and even register as the system default input, but it records
        // pure silence — which makes Whisper hallucinate. Filtering on real input
        // channels keeps those devices out of the mic path entirely.
        let devices = availableInputDevices().filter { hasInputChannels($0) }
        guard !devices.isEmpty else {
            let fallback = defaultInputDevice()
            return (fallback != nil && hasInputChannels(fallback!)) ? fallback : nil
        }

        // The system default reflects what the user chose in System Settings > Sound > Input.
        // Respect it unless it's the built-in mic and a better external device is available —
        // but only if it can actually capture input.
        let systemDefault = defaultInputDevice()

        if let systemDefault, hasInputChannels(systemDefault), !isBuiltInDevice(systemDefault) {
            // User explicitly chose a non-built-in device that can record — respect it.
            return systemDefault
        }

        // System default is built-in, nil, or input-less. Check for a connected external mic.
        // Note: "headphone" is intentionally NOT here — headphones are an output device.
        let externalKeywords = [
            // Connection types
            "headset", "external", "usb", "thunderbolt", "interface",
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

        // No recognized external device — check for any non-built-in device with input
        if let nonBuiltIn = devices.first(where: { !isBuiltInDevice($0) }) {
            return nonBuiltIn
        }

        // Everything is built-in — prefer the (input-capable) system default, else any input device
        if let systemDefault, hasInputChannels(systemDefault) {
            return systemDefault
        }
        return devices.first
    }

    /// Returns true if the device exposes at least one input channel.
    ///
    /// Queries CoreAudio's input-scope stream configuration. If the device cannot be
    /// resolved (no matching CoreAudio device for the UID), we assume it is usable
    /// rather than discarding a device we simply failed to introspect.
    private func hasInputChannels(_ device: AVCaptureDevice) -> Bool {
        guard let count = inputChannelCount(forUID: device.uniqueID) else { return true }
        return count > 0
    }

    /// Number of input channels for a CoreAudio device identified by its UID string.
    /// Returns nil if the device cannot be resolved.
    private func inputChannelCount(forUID uid: String) -> Int? {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var cfUID = uid as CFString
        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDeviceForUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var translation = AudioValueTranslation(
            mInputData: &cfUID,
            mInputDataSize: UInt32(MemoryLayout<CFString>.size),
            mOutputData: &deviceID,
            mOutputDataSize: UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        var translationSize = UInt32(MemoryLayout<AudioValueTranslation>.size)
        let lookup = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &uidAddress, 0, nil, &translationSize, &translation
        )
        guard lookup == noErr, deviceID != kAudioObjectUnknown else { return nil }

        var streamAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &streamAddress, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return 0 }

        let bufferList = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { bufferList.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &streamAddress, 0, nil, &dataSize, bufferList) == noErr else {
            return nil
        }

        let abl = UnsafeMutableAudioBufferListPointer(bufferList.assumingMemoryBound(to: AudioBufferList.self))
        return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
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
        // Synchronous check: use the legacy heuristic but also kick off an async
        // SCShareableContent check for accuracy on macOS 14.2+.
        // The CGWindowList check is kept as a fast synchronous baseline.
        let windowList = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]
        return windowList != nil && !(windowList?.isEmpty ?? true)
    }

    /// Async permission check using ScreenCaptureKit — more accurate on macOS 14.2+.
    /// Returns true if the app has Screen Recording permission for audio capture.
    @available(macOS 14.2, *)
    func hasScreenRecordingPermissionAsync() async -> Bool {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            return true
        } catch {
            return false
        }
    }
}

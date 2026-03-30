import AVFoundation
import CoreAudio
import os

/// Captures microphone input using AVAudioEngine.
///
/// Feeds raw hardware-format audio to onRawBuffer (for SFSpeechRecognizer),
/// and manually downsampled 16kHz mono Float32 to onBuffer (for WhisperKit + WAV recording).
///
/// Uses simple linear interpolation for downsampling instead of AVAudioConverter,
/// which produces near-silent output in real-time streaming scenarios.
final class MicrophoneCapture {
    /// 16kHz mono Float32 buffers for WhisperKit + WAV recording.
    var onBuffer: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?
    /// Raw hardware-format buffers for SFSpeechRecognizer.
    var onRawBuffer: ((AVAudioPCMBuffer) -> Void)?

    let engine = AVAudioEngine()
    private var isRunning = false
    private(set) var preferredInputDeviceID: String?
    /// Diagnostic: callback for logging raw buffer info (set by AudioCaptureService)
    var onDiagnostic: ((String) -> Void)?
    private var rawBufferCount: Int = 0

    /// The actual AudioDeviceID being used (for diagnostics)
    private(set) var activeDeviceID: AudioDeviceID = 0

    /// Target format: 16kHz mono Float32.
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16000,
        channels: 1,
        interleaved: false
    )!

    func configure(inputDeviceID: String) {
        self.preferredInputDeviceID = inputDeviceID.isEmpty ? nil : inputDeviceID
    }

    func start() throws {
        guard !isRunning else { return }

        // Try to set the preferred device; fall back to system default on failure.
        configureInputDevice()

        installTapOnInputNode()

        // Try to start the engine. If it fails (e.g., device error -10868),
        // reset the engine, fall back to the system default device, and retry once.
        do {
            try engine.start()
        } catch {
            onDiagnostic?("DIAG:mic_engine FIRST START FAILED: \(error.localizedDescription), attempting fallback")
            Logger.audio.error("AVAudioEngine start failed: \(error.localizedDescription) — attempting fallback to default device")

            engine.inputNode.removeTap(onBus: 0)
            engine.reset()

            // Fall back to system default device
            let defaultID = getDefaultInputDeviceID()
            if defaultID != kAudioObjectUnknown && defaultID != activeDeviceID {
                activeDeviceID = defaultID
                _ = setInputDeviceByID(defaultID)
                onDiagnostic?("DIAG:mic_device fallback to default deviceID=\(defaultID) name=\(getDeviceName(defaultID))")
            }

            // Re-check format after reset
            let retryFormat = engine.inputNode.outputFormat(forBus: 0)
            guard retryFormat.sampleRate > 0 else {
                throw AudioCaptureError.captureSetupFailed("No valid audio input device available. Please check System Settings > Sound > Input.")
            }

            // Re-install tap and retry
            installTapOnInputNode()

            do {
                try engine.start()
                onDiagnostic?("DIAG:mic_engine fallback START succeeded with default device")
                Logger.audio.info("AVAudioEngine fallback start succeeded with default device")
            } catch {
                onDiagnostic?("DIAG:mic_engine FALLBACK START ALSO FAILED: \(error.localizedDescription)")
                Logger.audio.error("AVAudioEngine fallback also failed: \(error.localizedDescription)")
                throw AudioCaptureError.captureSetupFailed(
                    "Could not start audio capture: \(error.localizedDescription). "
                    + "Please check that your microphone is connected and enabled in System Settings > Sound > Input."
                )
            }
        }

        isRunning = true
        Logger.audio.info("MicrophoneCapture started (manual downsample to 16kHz)")
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        Logger.audio.info("MicrophoneCapture stopped")
    }

    // MARK: - Device Configuration

    /// Configure the input device: try preferred, fall back to system default.
    private func configureInputDevice() {
        if let deviceUID = preferredInputDeviceID {
            if !setInputDevice(uid: deviceUID) {
                onDiagnostic?("DIAG:mic_device preferred device failed, trying system default")
                let defaultID = getDefaultInputDeviceID()
                if defaultID != kAudioObjectUnknown {
                    activeDeviceID = defaultID
                    _ = setInputDeviceByID(defaultID)
                    onDiagnostic?("DIAG:mic_device fell back to system default deviceID=\(defaultID) name=\(getDeviceName(defaultID))")
                }
            }
        } else {
            let defaultID = getDefaultInputDeviceID()
            if defaultID != kAudioObjectUnknown {
                activeDeviceID = defaultID
                _ = setInputDeviceByID(defaultID)
                onDiagnostic?("DIAG:mic_device using system default deviceID=\(defaultID) name=\(getDeviceName(defaultID))")
            }
        }
    }

    // MARK: - Tap Installation

    /// Install the audio tap on the engine's input node. Handles downsampling to 16kHz mono.
    private func installTapOnInputNode() {
        let inputNode = engine.inputNode
        inputNode.removeTap(onBus: 0)

        let hwFormat = inputNode.outputFormat(forBus: 0)
        let hwRate = hwFormat.sampleRate
        let hwChannels = Int(hwFormat.channelCount)

        guard hwRate > 0 else { return }

        Logger.audio.info("Mic: \(hwRate)Hz \(hwChannels)ch → downsampling to 16kHz mono")

        inputNode.installTap(onBus: 0, bufferSize: 8192, format: nil) {
            [weak self] buffer, time in
            guard let self else { return }

            // Diagnostic: log raw hardware buffer info periodically
            self.rawBufferCount += 1
            if self.rawBufferCount <= 3 || self.rawBufferCount % 200 == 0 {
                var rawRMS: Float = 0
                var sampleDump = ""
                if let fcd = buffer.floatChannelData, buffer.frameLength > 0 {
                    let ptr = fcd[0]
                    var sum: Float = 0
                    let n = min(8192, Int(buffer.frameLength))
                    for i in 0..<n { sum += ptr[i] * ptr[i] }
                    rawRMS = sqrtf(sum / Float(n))
                    let samples = (0..<min(10, Int(buffer.frameLength))).map { String(format: "%.6f", ptr[$0]) }
                    sampleDump = samples.joined(separator: ",")
                }
                let fmt = buffer.format
                self.onDiagnostic?("DIAG:raw_mic #\(self.rawBufferCount) frames=\(buffer.frameLength) rms=\(String(format: "%.6f", rawRMS)) fmt=\(fmt.sampleRate)/\(fmt.channelCount)ch samples=[\(sampleDump)]")
            }

            // Send raw buffer for SFSpeechRecognizer
            self.onRawBuffer?(buffer)

            // Downsample to 16kHz mono
            if let downsampled = self.downsample(buffer: buffer, fromRate: hwRate, channels: hwChannels) {
                self.onBuffer?(downsampled, time)
            }
        }
    }

    // MARK: - Downsampling

    /// Downsample a multi-channel buffer to 16kHz mono Float32 using linear interpolation.
    private func downsample(buffer: AVAudioPCMBuffer, fromRate hwRate: Double, channels hwChannels: Int) -> AVAudioPCMBuffer? {
        guard let channelData = buffer.floatChannelData else { return nil }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return nil }

        // Mix all channels to mono
        var monoSamples = [Float](repeating: 0, count: frameCount)
        for ch in 0..<hwChannels {
            let chPtr = channelData[ch]
            for i in 0..<frameCount {
                monoSamples[i] += chPtr[i]
            }
        }
        if hwChannels > 1 {
            let scale = 1.0 / Float(hwChannels)
            for i in 0..<frameCount {
                monoSamples[i] *= scale
            }
        }

        // Resample from hwRate to 16000 Hz
        let ratio = 16000.0 / hwRate
        let outputCount = Int(Double(frameCount) * ratio)
        guard outputCount > 0 else { return nil }

        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat,
                                                frameCapacity: AVAudioFrameCount(outputCount)) else { return nil }
        outBuffer.frameLength = AVAudioFrameCount(outputCount)
        guard let outPtr = outBuffer.floatChannelData?[0] else { return nil }

        // Linear interpolation resampling
        for i in 0..<outputCount {
            let srcPos = Double(i) / ratio
            let srcIdx = Int(srcPos)
            let frac = Float(srcPos - Double(srcIdx))

            if srcIdx + 1 < frameCount {
                outPtr[i] = monoSamples[srcIdx] * (1 - frac) + monoSamples[srcIdx + 1] * frac
            } else if srcIdx < frameCount {
                outPtr[i] = monoSamples[srcIdx]
            }
        }

        return outBuffer
    }

    // MARK: - Core Audio Device Management

    /// Set the input device on the engine's underlying audio unit by UID string.
    /// Returns true if successful.
    @discardableResult
    private func setInputDevice(uid: String) -> Bool {
        var deviceID = getDeviceIDForUID(uid)
        if deviceID == kAudioObjectUnknown {
            onDiagnostic?("DIAG:mic_device WARNING: could not find device for UID '\(uid)', using system default")
            deviceID = getDefaultInputDeviceID()
        }
        guard deviceID != kAudioObjectUnknown else { return false }
        activeDeviceID = deviceID
        let success = setInputDeviceByID(deviceID)
        if success {
            onDiagnostic?("DIAG:mic_device set to '\(getDeviceName(deviceID))' (id=\(deviceID), uid=\(uid))")
        }
        return success
    }

    /// Set the input device on the engine's audio unit by AudioDeviceID.
    /// Returns true if successful.
    @discardableResult
    private func setInputDeviceByID(_ deviceID: AudioDeviceID) -> Bool {
        let inputNode = engine.inputNode
        guard let audioUnit = inputNode.audioUnit else {
            onDiagnostic?("DIAG:mic_device ERROR: audioUnit is nil — engine may not be initialized")
            Logger.audio.error("Cannot set input device: audioUnit is nil")
            return false
        }
        var devID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &devID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            onDiagnostic?("DIAG:mic_device ERROR: AudioUnitSetProperty failed with status \(status) for device \(deviceID) '\(getDeviceName(deviceID))'")
            Logger.audio.error("AudioUnitSetProperty failed: \(status) for device \(deviceID)")
            return false
        }
        return true
    }

    /// Get the system default input device ID.
    private func getDefaultInputDeviceID() -> AudioDeviceID {
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        return deviceID
    }

    /// Look up an AudioDeviceID from a UID string.
    private func getDeviceIDForUID(_ uid: String) -> AudioDeviceID {
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var cfUID: CFString = uid as CFString
        var translation = AudioValueTranslation(
            mInputData: &cfUID,
            mInputDataSize: UInt32(MemoryLayout<CFString>.size),
            mOutputData: &deviceID,
            mOutputDataSize: UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        var size = UInt32(MemoryLayout<AudioValueTranslation>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDeviceForUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &translation
        )
        return deviceID
    }

    /// Get the human-readable name of an AudioDeviceID.
    private func getDeviceName(_ deviceID: AudioDeviceID) -> String {
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name)
        return name as String
    }
}

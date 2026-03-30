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
        self.preferredInputDeviceID = inputDeviceID
    }

    func start() throws {
        guard !isRunning else { return }

        // Set the input device on the engine's audio unit if a preferred device was configured.
        // This is critical — without it, AVAudioEngine may capture from a device that
        // delivers silence (e.g., when the browser has exclusive access to a USB mic).
        if let deviceUID = preferredInputDeviceID {
            setInputDevice(uid: deviceUID)
        } else {
            // Use the system default input device
            let defaultID = getDefaultInputDeviceID()
            if defaultID != kAudioObjectUnknown {
                activeDeviceID = defaultID
                setInputDeviceByID(defaultID)
                onDiagnostic?("DIAG:mic_device using system default deviceID=\(defaultID) name=\(getDeviceName(defaultID))")
            }
        }

        let inputNode = engine.inputNode
        inputNode.removeTap(onBus: 0)

        let hwFormat = inputNode.outputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0 else {
            throw AudioCaptureError.deviceNotFound
        }

        let hwRate = hwFormat.sampleRate
        let hwChannels = Int(hwFormat.channelCount)
        Logger.audio.info("Mic: \(hwRate)Hz \(hwChannels)ch → downsampling to 16kHz mono")

        inputNode.installTap(onBus: 0, bufferSize: 8192, format: nil) {
            [weak self] buffer, time in
            guard let self else { return }

            // Diagnostic: log raw hardware buffer info periodically
            self.rawBufferCount += 1
            if self.rawBufferCount <= 3 || self.rawBufferCount % 200 == 0 {
                // Dump first few raw samples to diagnose zero-level issue
                var sampleDump = ""
                var rawRMS: Float = 0
                if let fcd = buffer.floatChannelData, buffer.frameLength > 0 {
                    let ptr = fcd[0]
                    var sum: Float = 0
                    let n = min(8192, Int(buffer.frameLength))
                    for i in 0..<n {
                        sum += ptr[i] * ptr[i]
                    }
                    rawRMS = sqrtf(sum / Float(n))
                    // Show first 10 samples
                    let samples = (0..<min(10, Int(buffer.frameLength))).map { String(format: "%.6f", ptr[$0]) }
                    sampleDump = samples.joined(separator: ",")
                }
                let fmt = buffer.format
                self.onDiagnostic?("DIAG:raw_mic #\(self.rawBufferCount) frames=\(buffer.frameLength) rms=\(String(format: "%.6f", rawRMS)) fmt=\(fmt.sampleRate)/\(fmt.channelCount)ch samples=[\(sampleDump)]")
            }

            // Send raw buffer for SFSpeechRecognizer
            self.onRawBuffer?(buffer)

            // Downsample to 16kHz mono using simple linear interpolation
            guard let channelData = buffer.floatChannelData else { return }
            let frameCount = Int(buffer.frameLength)
            guard frameCount > 0 else { return }

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
            guard outputCount > 0 else { return }

            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: self.targetFormat,
                                                    frameCapacity: AVAudioFrameCount(outputCount)) else { return }
            outBuffer.frameLength = AVAudioFrameCount(outputCount)
            guard let outPtr = outBuffer.floatChannelData?[0] else { return }

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

            self.onBuffer?(outBuffer, time)
        }

        try engine.start()
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

    // MARK: - Core Audio Device Management

    /// Set the input device on the engine's underlying audio unit by UID string.
    private func setInputDevice(uid: String) {
        // Find the AudioDeviceID for this UID
        var deviceID = getDeviceIDForUID(uid)
        if deviceID == kAudioObjectUnknown {
            onDiagnostic?("DIAG:mic_device WARNING: could not find device for UID '\(uid)', using system default")
            deviceID = getDefaultInputDeviceID()
        }
        guard deviceID != kAudioObjectUnknown else { return }
        activeDeviceID = deviceID
        setInputDeviceByID(deviceID)
        onDiagnostic?("DIAG:mic_device set to '\(getDeviceName(deviceID))' (id=\(deviceID), uid=\(uid))")
    }

    /// Set the input device on the engine's audio unit by AudioDeviceID.
    private func setInputDeviceByID(_ deviceID: AudioDeviceID) {
        let inputNode = engine.inputNode
        let audioUnit = inputNode.audioUnit!
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
            onDiagnostic?("DIAG:mic_device ERROR: AudioUnitSetProperty failed with status \(status)")
        }
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

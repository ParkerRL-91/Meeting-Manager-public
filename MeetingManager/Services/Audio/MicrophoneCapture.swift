import AVFoundation
import CoreAudio
import os

/// Error surfaced when the microphone device is disconnected mid-recording.
enum MicrophoneCaptureError: LocalizedError {
    case deviceDisconnected(String)
    case permissionDenied
    case permissionRestricted

    var errorDescription: String? {
        switch self {
        case .deviceDisconnected(let detail):
            return "Microphone disconnected: \(detail)"
        case .permissionDenied:
            return "Microphone permission denied. Please grant access in System Settings > Privacy & Security > Microphone."
        case .permissionRestricted:
            return "Microphone access is restricted on this device."
        }
    }
}

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

    /// Called when the microphone device is disconnected mid-recording.
    var onDeviceDisconnected: ((Error) -> Void)?

    /// AVAudioEngine instance. `var` because we deliberately recreate it on
    /// `stop()` — reusing a stopped engine across recording sessions has
    /// repeatedly caused -10868 (`kAudioUnitErr_FormatNotSupported`) on the
    /// next `start()` when the input HAL hasn't fully released the prior
    /// format. A fresh engine sidesteps the issue entirely.
    var engine = AVAudioEngine()
    private var isRunning = false
    /// Wall-clock time the last `stop()` returned. Used to throttle the next
    /// `start()` so the CoreAudio HAL has time to release the input device.
    private var lastStopAt: Date?
    private(set) var preferredInputDeviceID: String?
    /// Diagnostic: callback for logging raw buffer info (set by AudioCaptureService)
    var onDiagnostic: ((String) -> Void)?
    private var rawBufferCount: Int = 0

    /// Lock protecting mutable state (`isRunning`, `rawBufferCount`) accessed
    /// from both the main thread and the audio callback queue.
    private let lock = NSLock()

    /// Observer token for audio engine configuration change notifications.
    private var configChangeObserver: NSObjectProtocol?

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
        lock.lock()
        guard !isRunning else { lock.unlock(); return }
        lock.unlock()

        // If we just stopped, give the HAL a moment to release the device.
        // Without this, immediate reopen hits -10868 (FormatNotSupported)
        // because the previous tap's IO unit is still tearing down.
        if let stopped = lastStopAt {
            let elapsed = Date().timeIntervalSince(stopped)
            let minGap: TimeInterval = 0.25
            if elapsed < minGap {
                Thread.sleep(forTimeInterval: minGap - elapsed)
            }
        }

        // Task 7: Check microphone permission before attempting capture
        let authStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        switch authStatus {
        case .denied:
            throw MicrophoneCaptureError.permissionDenied
        case .restricted:
            throw MicrophoneCaptureError.permissionRestricted
        case .notDetermined:
            // Permission not yet requested — the caller (AudioCaptureService) should
            // have requested it before reaching here, but handle it defensively.
            // We cannot await here (sync func), so throw a clear error.
            throw MicrophoneCaptureError.permissionDenied
        case .authorized:
            break
        @unknown default:
            break
        }

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
                // Last-resort recovery for -10868 and friends: discard this
                // engine instance entirely and try once more with a fresh one.
                // Same logic as stop() — works around the HAL not releasing
                // the input format when the engine is reused. Sleeps briefly
                // to give CoreAudio time to settle.
                onDiagnostic?("DIAG:mic_engine FALLBACK START FAILED: \(error.localizedDescription) — recreating engine")
                Logger.audio.error("AVAudioEngine fallback failed: \(error.localizedDescription) — rebuilding engine")
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
                engine = AVAudioEngine()
                Thread.sleep(forTimeInterval: 0.3)
                configureInputDevice()
                installTapOnInputNode()
                do {
                    try engine.start()
                    onDiagnostic?("DIAG:mic_engine rebuilt engine START succeeded")
                    Logger.audio.info("AVAudioEngine succeeded after engine rebuild")
                } catch {
                    onDiagnostic?("DIAG:mic_engine REBUILT ENGINE ALSO FAILED: \(error.localizedDescription)")
                    Logger.audio.error("AVAudioEngine even after rebuild failed: \(error.localizedDescription)")
                    throw AudioCaptureError.captureSetupFailed(
                        "Could not start audio capture: \(error.localizedDescription). "
                        + "Please check that your microphone is connected and enabled in System Settings > Sound > Input."
                    )
                }
            }
        }

        lock.lock()
        isRunning = true
        lock.unlock()

        // Task 6: Register for audio engine configuration changes (device disconnect/reconnect)
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.handleEngineConfigurationChange()
        }

        Logger.audio.info("MicrophoneCapture started (manual downsample to 16kHz)")
    }

    func stop() {
        lock.lock()
        guard isRunning else { lock.unlock(); return }
        isRunning = false
        lock.unlock()

        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        // Recreate the engine for the next session. Reusing a stopped engine
        // is supposed to be safe but in practice it leaves the input IO unit
        // in a half-released state — the next start() then fails with
        // -10868 (FormatNotSupported). A fresh engine is cheap (~ms) and
        // makes "stop → start" idempotent.
        engine = AVAudioEngine()
        lastStopAt = Date()

        Logger.audio.info("MicrophoneCapture stopped (engine recreated for next session)")
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

            // Check if still running under lock
            self.lock.lock()
            guard self.isRunning else { self.lock.unlock(); return }
            self.rawBufferCount += 1
            let currentRawBufferCount = self.rawBufferCount
            self.lock.unlock()

            // Diagnostic: log raw hardware buffer info periodically
            if currentRawBufferCount <= 3 || currentRawBufferCount % 200 == 0 {
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
                self.onDiagnostic?("DIAG:raw_mic #\(currentRawBufferCount) frames=\(buffer.frameLength) rms=\(String(format: "%.6f", rawRMS)) fmt=\(fmt.sampleRate)/\(fmt.channelCount)ch samples=[\(sampleDump)]")
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

    // MARK: - Device Disconnection Handling

    /// Called when the AVAudioEngine configuration changes (e.g., device disconnected/reconnected).
    private func handleEngineConfigurationChange() {
        lock.lock()
        let wasRunning = isRunning
        lock.unlock()

        guard wasRunning else { return }

        onDiagnostic?("DIAG:mic_device AVAudioEngine configuration changed — device may have disconnected")
        Logger.audio.warning("AVAudioEngine configuration changed mid-recording")

        // Check if the engine's input node still has a valid format
        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        if inputFormat.sampleRate == 0 || inputFormat.channelCount == 0 {
            // Device is gone — stop gracefully and notify
            Logger.audio.error("Microphone device disconnected mid-recording — stopping capture")
            onDiagnostic?("DIAG:mic_device DISCONNECTED — stopping capture gracefully")
            stop()
            let error = MicrophoneCaptureError.deviceDisconnected(
                "The microphone was disconnected during recording. Please reconnect and restart."
            )
            onDeviceDisconnected?(error)
        } else {
            // Device changed but still valid — try to restart the engine.
            // Re-check isRunning under lock first: stop() may have run between
            // the notification firing and now, in which case restarting would
            // resurrect a capture the caller just tore down.
            lock.lock()
            let stillRunning = isRunning
            lock.unlock()
            guard stillRunning else {
                onDiagnostic?("DIAG:mic_device config changed after stop — not restarting")
                return
            }
            onDiagnostic?("DIAG:mic_device config changed but format still valid (\(inputFormat.sampleRate)Hz/\(inputFormat.channelCount)ch), attempting restart")
            // Re-pin the device we selected before restarting. A configuration
            // change (a device (dis)connect, a Continuity mic appearing) can
            // silently revert AVAudioEngine's input to the *system default* —
            // which may be a phantom aggregate/Continuity mic that captures pure
            // silence. Re-applying our chosen device + tap keeps capture on the
            // intended mic instead of drifting onto a silent default mid-meeting.
            if activeDeviceID != kAudioObjectUnknown && activeDeviceID != 0 {
                _ = setInputDeviceByID(activeDeviceID)
            }
            installTapOnInputNode()
            do {
                try engine.start()
                onDiagnostic?("DIAG:mic_device engine restarted successfully after config change (device re-pinned to \(getDeviceName(activeDeviceID)))")
            } catch {
                Logger.audio.error("Failed to restart engine after config change: \(error.localizedDescription)")
                onDiagnostic?("DIAG:mic_device engine restart FAILED: \(error.localizedDescription)")
                stop()
                let disconnectError = MicrophoneCaptureError.deviceDisconnected(
                    "Microphone configuration changed and engine could not restart: \(error.localizedDescription)"
                )
                onDeviceDisconnected?(disconnectError)
            }
        }
    }
}

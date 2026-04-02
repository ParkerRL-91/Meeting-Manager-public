import AVFoundation
import Combine
import os

// MARK: - AudioCapturing Protocol

/// Abstraction over audio capture so MeetingStateMachine can be tested without hardware.
@MainActor
protocol AudioCapturing: AnyObject {
    var micLevel: Float { get }
    var systemLevel: Float { get }
    var currentAudioFileURL: URL? { get }
    var onSilenceDetected: (() -> Void)? { get set }
    func startCapture(meetingId: String) async throws
    @discardableResult func stopCapture() -> URL?
}

// MARK: - AudioCaptureService

/// Orchestrates mic + system audio capture for meeting recording
@MainActor
final class AudioCaptureService: ObservableObject, AudioCapturing {
    @Published var isCapturing = false
    @Published var micLevel: Float = 0
    @Published var systemLevel: Float = 0

    /// Called when sustained silence is detected (no speech for `silenceTimeout` seconds).
    /// The meeting should be auto-stopped.
    var onSilenceDetected: (() -> Void)?

    /// Called when the audio buffer hits its max duration capacity (default 2 hours).
    /// The meeting should be auto-stopped to prevent unbounded memory growth.
    var onCapacityReached: (() -> Void)?

    /// Called when the AudioBufferManager encounters a write error (e.g., disk full).
    /// The error is surfaced to the user via AppState.lastUserError.
    var onWriteError: ((Error) -> Void)?

    /// How many consecutive seconds of silence before triggering auto-stop.
    var silenceTimeout: TimeInterval = 45

    /// Diagnostic counters for buffer callbacks (logged periodically by test harness).
    /// Accessed from audio callback queues via lock — stored as nonisolated to allow
    /// mutation from nonisolated contexts (audio thread callbacks).
    private let _counterLock = NSLock()
    nonisolated(unsafe) private var _micBufferCount: Int = 0
    nonisolated(unsafe) private var _sysBufferCount: Int = 0

    /// Thread-safe increment and return of mic buffer count.
    nonisolated private func incrementMicBufferCount() -> Int {
        _counterLock.withLock {
            _micBufferCount += 1
            return _micBufferCount
        }
    }

    /// Thread-safe increment and return of sys buffer count.
    nonisolated private func incrementSysBufferCount() -> Int {
        _counterLock.withLock {
            _sysBufferCount += 1
            return _sysBufferCount
        }
    }

    /// Thread-safe reset of buffer counters.
    nonisolated private func resetBufferCounts() {
        _counterLock.withLock {
            _micBufferCount = 0
            _sysBufferCount = 0
        }
    }

    /// Tracks consecutive seconds of silence for auto-stop.
    private var consecutiveSilentSeconds: Int = 0
    private var silenceCheckTimer: Timer?

    /// Thread-safe atomic levels updated directly in audio buffer callbacks.
    /// Use these for polling from the main thread instead of the @Published properties
    /// which depend on MainActor Task scheduling.
    private let _atomicMicLevel: UnsafeMutablePointer<Float> = {
        let p = UnsafeMutablePointer<Float>.allocate(capacity: 1)
        p.initialize(to: 0)
        return p
    }()
    private let _atomicSystemLevel: UnsafeMutablePointer<Float> = {
        let p = UnsafeMutablePointer<Float>.allocate(capacity: 1)
        p.initialize(to: 0)
        return p
    }()

    /// Read the latest mic level atomically (safe to call from any thread).
    nonisolated var latestMicLevel: Float { _atomicMicLevel.pointee }
    /// Read the latest system level atomically (safe to call from any thread).
    nonisolated var latestSystemLevel: Float { _atomicSystemLevel.pointee }

    let micCapture = MicrophoneCapture()

    /// Callback for raw (unconverted) mic buffers — used by SFSpeechRecognizer.
    var onRawMicBuffer: ((AVAudioPCMBuffer) -> Void)?

    /// The AVAudioEngine used by mic capture — exposed for SFSpeechRecognizer integration.
    var micEngine: AVAudioEngine { micCapture.engine }
    private let systemTap: AnyObject? = {
        if #available(macOS 14.2, *) {
            return SystemAudioTap()
        }
        return nil
    }()
    private let bufferManager = AudioBufferManager()
    private let sessionManager = AudioSessionManager()

    /// The URL of the current recording's WAV file. Used for batch transcription after meeting ends.
    private(set) var currentAudioFileURL: URL?

    @available(macOS 14.2, *)
    private var systemAudioTap: SystemAudioTap? { systemTap as? SystemAudioTap }

    /// Start capturing audio from both mic and system
    func startCapture(meetingId: String) async throws {
        guard !isCapturing else { return }

        // Verify permissions
        guard await sessionManager.requestMicrophonePermission() else {
            throw AudioCaptureError.microphonePermissionDenied
        }

        // Set up audio file for recording
        let audioDir = try audioDirectory()
        let fileURL = audioDir.appendingPathComponent("\(meetingId).wav")
        currentAudioFileURL = fileURL

        try bufferManager.prepareForRecording(outputURL: fileURL)

        // Surface write errors (e.g. disk full) to the caller via onWriteError
        bufferManager.onWriteError = { [weak self] error in
            self?.onWriteError?(error)
        }

        // Select the best available input device and configure mic capture
        if let bestDevice = sessionManager.bestInputDevice() {
            Logger.audio.info("Selected input device: \(bestDevice.localizedName) (id: \(bestDevice.uniqueID))")
            micCapture.configure(inputDeviceID: bestDevice.uniqueID)
        } else {
            Logger.audio.info("No preferred input device found; using system default")
        }

        // Wire raw buffer callback for speech recognizer.
        // Read the property dynamically so late-set callbacks are captured correctly.
        micCapture.onRawBuffer = { [weak self] buffer in
            self?.onRawMicBuffer?(buffer)
        }

        // Wire diagnostic logging from mic capture
        micCapture.onDiagnostic = { [weak self] msg in
            self?.logToFile(msg)
        }

        // Wire device disconnection handler (Task 6)
        micCapture.onDeviceDisconnected = { [weak self] error in
            guard let self else { return }
            Logger.audio.error("Mic device disconnected: \(error.localizedDescription)")
            self.logToFile("Audio: mic device DISCONNECTED — \(error.localizedDescription)")
            Task { @MainActor in
                _ = self.stopCapture()
            }
        }

        // Start mic capture — converted 16kHz buffers to buffer manager
        micCapture.onBuffer = { [weak self] buffer, time in
            guard let self else { return }
            self.bufferManager.appendMicBuffer(buffer, at: time)
            self.updateMicLevel(buffer)
            // Diagnostic: log every ~2 seconds (16kHz / 8192 ≈ 2 buffers/sec for converted)
            let count = self.incrementMicBufferCount()
            if count % 20 == 1 {
                let rms = buffer.rmsLevel
                self.logToFile("DIAG:mic_buffer count=\(count) frames=\(buffer.frameLength) rms=\(String(format: "%.4f", rms))")
            }
        }

        // ┌─────────────────────────────────────────────────────────────────┐
        // │ IMPORTANT: Start system audio tap BEFORE mic capture.           │
        // │ The system tap creates an aggregate device that can hijack the  │
        // │ default input. By starting the tap first, we ensure the mic     │
        // │ engine is set to the real hardware mic after the aggregate      │
        // │ device is created.                                              │
        // └─────────────────────────────────────────────────────────────────┘

        // Start system audio capture FIRST (for remote participant audio).
        // This captures what comes out of your speakers/headphones — i.e. the other
        // people on the call. Requires Screen Recording permission in System Settings.
        // Failure here is non-fatal — mic-only recording is still useful.
        resetBufferCounts()
        if #available(macOS 14.2, *) {
            if let tap = systemAudioTap {
                // Wire diagnostic logging for system audio tap
                tap.onDiagnostic = { [weak self] msg in
                    self?.logToFile(msg)
                }
                tap.onBuffer = { [weak self] buffer, time in
                    guard let self else { return }
                    self.bufferManager.appendSystemBuffer(buffer, at: time)
                    self.updateSystemLevel(buffer)
                    // Diagnostic: log system buffer periodically
                    let sysCount = self.incrementSysBufferCount()
                    if sysCount % 20 == 1 {
                        let rms = buffer.rmsLevel
                        self.logToFile("DIAG:sys_buffer count=\(sysCount) frames=\(buffer.frameLength) rms=\(String(format: "%.4f", rms))")
                    }
                }
                do {
                    try await tap.start()
                    Logger.audio.info("System audio tap started successfully — capturing remote participants")
                    logToFile("Audio: system audio tap STARTED (remote participant capture active)")
                } catch {
                    Logger.audio.error("System audio tap FAILED: \(error.localizedDescription)")
                    logToFile("Audio: system audio tap FAILED — \(error.localizedDescription). Only mic will be recorded. Grant Screen Recording permission to capture remote participants.")
                }
            } else {
                Logger.audio.warning("System audio tap not available (requires macOS 14.2+)")
                logToFile("Audio: system audio tap not available (requires macOS 14.2+)")
            }
        } else {
            logToFile("Audio: system audio tap requires macOS 14.2+ — only mic will be recorded")
        }

        // Now start mic capture AFTER system tap (so the aggregate device is already created
        // and won't hijack the mic input). Re-configure to the real hardware device.
        if let bestDevice = sessionManager.bestInputDevice() {
            logToFile("Audio: re-setting mic to hardware device '\(bestDevice.localizedName)' after system tap setup")
            micCapture.configure(inputDeviceID: bestDevice.uniqueID)
        } else {
            // No preferred device found — clear any stale preference so MicrophoneCapture
            // uses the system default, which is the safest fallback on an unfamiliar Mac.
            micCapture.configure(inputDeviceID: "")
            logToFile("Audio: no preferred input device found, will use system default")
        }

        do {
            try micCapture.start()
        } catch {
            // Log the failure and try once more with a completely clean slate
            logToFile("Audio: mic capture FAILED on first attempt: \(error.localizedDescription)")
            Logger.audio.error("Mic capture failed: \(error.localizedDescription) — retrying with system default")

            // Reset preference and let MicrophoneCapture pick the system default
            micCapture.configure(inputDeviceID: "")
            try micCapture.start()
        }
        let engineRunning = micCapture.engine.isRunning
        let inputFormat = micCapture.engine.inputNode.outputFormat(forBus: 0)
        logToFile("Audio: mic capture STARTED (device: \(sessionManager.bestInputDevice()?.localizedName ?? "default"), engine.running=\(engineRunning), inputFormat=\(inputFormat.sampleRate)Hz/\(inputFormat.channelCount)ch)")

        // Start silence monitoring AFTER both captures are running
        consecutiveSilentSeconds = 0
        silenceCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }

            // Check buffer capacity limit (prevents multi-GB buffer from long recordings)
            if self.bufferManager.isAtCapacity {
                Logger.audio.warning("Buffer capacity reached (\(Int(self.bufferManager.maxRecordingDurationSeconds / 3600))h limit) — triggering auto-stop")
                self.onCapacityReached?()
                return
            }

            // micLevel is updated by updateMicLevel on every buffer
            // Threshold lowered from 0.005 — USB webcam mics have very low signal (~0.002-0.006)
            if self.micLevel < 0.001 {
                self.consecutiveSilentSeconds += 1
                if self.consecutiveSilentSeconds >= Int(self.silenceTimeout) {
                    Logger.audio.info("Silence detected for \(self.consecutiveSilentSeconds)s — triggering auto-stop")
                    self.onSilenceDetected?()
                    self.consecutiveSilentSeconds = 0 // Reset so it doesn't fire repeatedly
                }
            } else {
                self.consecutiveSilentSeconds = 0
            }
        }

        isCapturing = true
    }

    /// Stop all audio capture
    func stopCapture() -> URL? {
        silenceCheckTimer?.invalidate()
        silenceCheckTimer = nil
        consecutiveSilentSeconds = 0
        micCapture.stop()
        if #available(macOS 14.2, *) {
            systemAudioTap?.stop()
        }
        bufferManager.finishRecording()

        isCapturing = false
        micLevel = 0
        systemLevel = 0

        return currentAudioFileURL
    }

    /// Get the buffer manager for the transcription service
    var transcriptionBuffer: AudioBufferManager {
        bufferManager
    }

    // MARK: - Private

    /// Write to the shared app log file for debugging with user.
    /// Marked nonisolated because it is called from audio callback queues.
    nonisolated private func logToFile(_ message: String) {
        AppFileLogger.shared.log(message)
    }

    private func audioDirectory() throws -> URL {
        let url = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("MeetingManager/Audio", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Called from audio callback queues — must be nonisolated to avoid MainActor hop.
    /// Uses atomic pointer for thread-safe write, then dispatches UI update to MainActor.
    nonisolated private func updateMicLevel(_ buffer: AVAudioPCMBuffer) {
        let level = buffer.rmsLevel
        _atomicMicLevel.pointee = level
        Task { @MainActor in
            self.micLevel = level
        }
    }

    /// Called from audio callback queues — must be nonisolated to avoid MainActor hop.
    nonisolated private func updateSystemLevel(_ buffer: AVAudioPCMBuffer) {
        let level = buffer.rmsLevel
        _atomicSystemLevel.pointee = level
        Task { @MainActor in
            self.systemLevel = level
        }
    }

    deinit {
        _atomicMicLevel.deallocate()
        _atomicSystemLevel.deallocate()
    }
}

// MARK: - Errors

enum AudioCaptureError: LocalizedError {
    case microphonePermissionDenied
    case systemAudioPermissionDenied
    case deviceNotFound
    case captureSetupFailed(String)

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone permission is required to record meetings."
        case .systemAudioPermissionDenied:
            return "Screen Recording permission is required to capture remote audio."
        case .deviceNotFound:
            return "Audio device not found."
        case .captureSetupFailed(let reason):
            return "Audio capture setup failed: \(reason)"
        }
    }
}

// MARK: - AVAudioPCMBuffer Extension

extension AVAudioPCMBuffer {
    var rmsLevel: Float {
        guard let channelData = floatChannelData, frameLength > 0 else { return 0 }
        let samples = channelData[0]
        var sum: Float = 0
        for i in 0..<Int(frameLength) {
            sum += samples[i] * samples[i]
        }
        let rms = sqrtf(sum / Float(frameLength))
        return min(max(rms, 0), 1)
    }
}

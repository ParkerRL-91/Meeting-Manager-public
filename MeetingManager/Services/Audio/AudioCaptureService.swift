import AVFoundation
import Combine
import CoreAudio
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
    @discardableResult func stopCapture() async -> URL?
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

    /// Called once per recording when the mic appears dead — silent for a sustained
    /// period while system audio proves the call is live. Non-fatal: recording
    /// continues (remote audio is still captured), but the user is warned so they
    /// can fix their input device. The String is a user-facing message.
    var onMicProblemDetected: ((String) -> Void)?

    /// Called when the AudioBufferManager encounters a write error (e.g., disk full).
    /// The error is surfaced to the user via AppState.lastUserError.
    var onWriteError: ((Error) -> Void)?

    /// Called when the system-audio tap can't start (almost always missing
    /// Screen Recording permission), so remote participants won't be recorded —
    /// only the local mic. Surfaced to the user with an actionable message,
    /// since this can't be requested programmatically and needs a relaunch.
    var onSystemAudioUnavailable: ((String) -> Void)?

    /// How many consecutive seconds of silence before triggering auto-stop.
    /// 5 minutes — meetings often have long pauses (presentations, screen sharing, muted mic).
    var silenceTimeout: TimeInterval = 300

    /// Supplies the user's overridden microphone UID at capture start, or nil to
    /// auto-detect. Set by AppState from the (off-by-default) mic-override
    /// setting. Read at each capture start so it always reflects current
    /// settings without needing to hook every settings-save site.
    var preferredInputDeviceIDProvider: (() -> String?)?

    /// The device to record from: the user's override when it's set and usable,
    /// otherwise the auto-detected best input. Auto-detection is the default and
    /// the fallback when an overridden device is missing or output-only.
    private func resolveInputDevice() -> AVCaptureDevice? {
        if let uid = preferredInputDeviceIDProvider?(),
           let overridden = sessionManager.inputDevice(forUID: uid) {
            return overridden
        }
        return sessionManager.bestInputDevice()
    }

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

    /// Tracks consecutive seconds where the mic is silent but system audio is active —
    /// the signature of a dead/wrong input device on a live call.
    private var consecutiveMicDeadSeconds: Int = 0
    /// Latches true once the mic-problem warning has fired, so it only warns once per recording.
    private var micProblemWarned = false
    /// Mic RMS below this is treated as "effectively dead". A real working mic
    /// always has a noise floor above this even when the user is silent — only a
    /// truly broken/output-only/disconnected input reads near literal zero. The
    /// old 0.0005 threshold tripped on a quietly-listening user (e.g. the first
    /// minute of a meeting before they speak), which caused the warning to fire
    /// false-positive on most calls.
    private let micDeadThreshold: Float = 0.00005
    /// System RMS above this means remote participants are clearly *talking*
    /// (not just ambient/blip noise). Raised from 0.01 so a brief network blip
    /// doesn't accumulate dead-mic seconds while the user is listening quietly.
    private let systemActiveThreshold: Float = 0.05
    /// Seconds of effectively-dead mic while system audio is active+loud before
    /// warning. Raised from 45s — a user listening to others for 45s is normal
    /// at the start of a call. 5 minutes of continuous "mic at zero while others
    /// are loudly talking" is the actual dead-device signal worth surfacing.
    private let micDeadWarnSeconds = 300

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

    /// One bounded system-tap restart per capture session (display change /
    /// sleep-wake blips recover; permission revocation doesn't loop forever).
    private var systemTapRestartAttempted = false

    /// In-flight detached mic switch, if any — awaited by stopCapture so a
    /// switch's stop→configure→start can't land after teardown.
    private var activeMicSwitchTask: Task<String?, Never>?

    /// Set synchronously at stopCapture entry. `isCapturing` stays true
    /// through the awaited merge (a new start must not race the file
    /// rewrite), so liveness guards in mic recovery / mic switch / tap-death
    /// recovery must check THIS flag — otherwise a disconnect Task queued
    /// just before stop can restart the mic or SCK stream after the meeting
    /// ended.
    private var isStoppingCapture = false

    // MARK: - Dynamic mic switching

    /// Where the live mic audio comes from. `.engine` is the normal AVAudioEngine
    /// path; `.screenCaptureKit` is the fallback used when a conferencing app holds
    /// the mic (set in `startMicrophoneWithRetry`). The two paths switch devices
    /// differently, so the coordinator branches on this.
    enum MicSource { case engine, screenCaptureKit }
    private(set) var micSource: MicSource = .engine

    /// Serializes `switchMicrophone` so rapid requests don't race. While a switch
    /// is in flight, the latest request is parked in `pendingSwitchUID` (only the
    /// final selection wins) and run when the current switch finishes.
    private var isMicSwitching = false
    private var pendingSwitchUID: (String?)?

    /// Reads whether the user has pinned a specific mic (override on). Wired by
    /// AppState. When override is on, the system-default auto-follow is suppressed.
    var isMicOverrideEnabledProvider: (() -> Bool)?

    /// Fired when mic recovery starts (true) / ends (false), so AppState can show a
    /// "reconnecting microphone" banner. Event-driven, not polled.
    var onMicRecoveryStateChanged: ((Bool) -> Void)?

    /// True while the mic is disconnected and we're holding the recording open
    /// waiting for a replacement device (system audio keeps capturing meanwhile).
    private(set) var isMicRecovering = false
    private var micRecoveryDeadlineTask: Task<Void, Never>?
    /// How long to wait for a replacement mic before ending the meeting.
    private let micRecoveryWindow: TimeInterval = 30

    /// CoreAudio property listeners (default-input-changed for auto-follow,
    /// device-list-changed as the recovery retry signal). Stored so the exact same
    /// block reference can be removed. Callbacks fire on `listenerQueue`, then hop
    /// to the main actor before touching any state.
    private var defaultInputListenerBlock: AudioObjectPropertyListenerBlock?
    private var devicesListListenerBlock: AudioObjectPropertyListenerBlock?
    private let listenerQueue = DispatchQueue(label: "com.meetingmanager.coreaudio-listener")
    private var defaultFollowDebounceTask: Task<Void, Never>?

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

        // Set up audio file for recording. First session uses the canonical
        // <meetingId>.wav name; a reopen/resume session gets a unique suffix —
        // AVAudioFile(forWriting:) truncates, so reusing the canonical name
        // would destroy the prior session's audio.
        let audioDir = try audioDirectory()
        var fileURL = audioDir.appendingPathComponent("\(meetingId).wav")
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let stamp = Int(Date().timeIntervalSince1970)
            fileURL = audioDir.appendingPathComponent("\(meetingId)-\(stamp).wav")
        }
        currentAudioFileURL = fileURL
        micSource = .engine   // SCK-mic fallback (if any) flips this in startMicrophoneWithRetry

        try bufferManager.prepareForRecording(outputURL: fileURL)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)

        // Surface write errors (e.g. disk full) to the caller via onWriteError
        bufferManager.onWriteError = { [weak self] error in
            self?.onWriteError?(error)
        }

        // Select the input device (user override if set and usable, else
        // auto-detected best) and configure mic capture.
        if let chosenDevice = resolveInputDevice() {
            Logger.audio.info("Selected input device: \(chosenDevice.localizedName) (id: \(chosenDevice.uniqueID))")
            micCapture.configure(inputDeviceID: chosenDevice.uniqueID)
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

        // Wire device disconnection handler. Instead of ending the meeting, enter
        // bounded recovery: keep the file + system tap alive and wait for a
        // replacement mic (see beginMicRecovery). System audio keeps capturing
        // remote participants throughout.
        micCapture.onDeviceDisconnected = { [weak self] error in
            guard let self else { return }
            Logger.audio.error("Mic device disconnected: \(error.localizedDescription)")
            self.logToFile("Audio: mic device DISCONNECTED — \(error.localizedDescription); entering bounded recovery (system audio continues)")
            Task { @MainActor in
                self.beginMicRecovery(reason: .disconnected)
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
        var systemTapStarted = false
        if #available(macOS 14.2, *) {
            if let tap = systemAudioTap {
                // Wire diagnostic logging for system audio tap
                tap.onDiagnostic = { [weak self] msg in
                    self?.logToFile(msg)
                }
                // Mid-capture SCK stream death (permission revoked, display
                // change, sleep/wake). Zero the levels so the dual-silence
                // auto-stop isn't held hostage by a frozen last value, try ONE
                // restart for transient causes, and tell the user when remote
                // audio is genuinely gone. Without this the rest of the
                // meeting recorded mic-only with no signal anywhere.
                systemTapRestartAttempted = false
                tap.onStreamStopped = { [weak self] error in
                    Task { @MainActor [weak self] in
                        guard let self, self.isCapturing, !self.isStoppingCapture else { return }
                        self._atomicSystemLevel.pointee = 0
                        self.systemLevel = 0
                        if self.micSource == .screenCaptureKit {
                            // The SCK stream carried the mic too — both inputs
                            // are dead. Zero the mic level so the silence
                            // auto-stop ends the meeting with what we have.
                            self._atomicMicLevel.pointee = 0
                            self.micLevel = 0
                        }
                        self.logToFile("Audio: system tap DIED mid-capture — \(error.localizedDescription)")

                        if self.micSource == .engine, !self.systemTapRestartAttempted,
                           let tap = self.systemAudioTap {
                            self.systemTapRestartAttempted = true
                            try? await Task.sleep(for: .seconds(2))
                            guard self.isCapturing, !self.isStoppingCapture else { return }
                            do {
                                try await tap.start()
                                self.logToFile("Audio: system tap RESTARTED after mid-capture death")
                                return
                            } catch {
                                self.logToFile("Audio: system tap restart FAILED — \(error.localizedDescription)")
                            }
                        }
                        self.onSystemAudioUnavailable?("System audio capture stopped mid-meeting (\(error.localizedDescription)). Remote participants are no longer being recorded — only your microphone.")
                    }
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
                    systemTapStarted = true
                    Logger.audio.info("System audio tap started successfully — capturing remote participants")
                    logToFile("Audio: system audio tap STARTED (remote participant capture active)")
                } catch {
                    Logger.audio.error("System audio tap FAILED: \(error.localizedDescription)")
                    logToFile("Audio: system audio tap FAILED — \(error.localizedDescription). Only mic will be recorded. Grant Screen Recording permission to capture remote participants.")
                    onSystemAudioUnavailable?("Remote participants aren't being recorded — only your microphone. Grant Screen Recording permission in System Settings → Privacy & Security → Screen Recording, then quit and reopen Meeting Manager.")
                }
            } else {
                Logger.audio.warning("System audio tap not available (requires macOS 14.2+)")
                logToFile("Audio: system audio tap not available (requires macOS 14.2+)")
                onSystemAudioUnavailable?("System audio capture needs macOS 14.2 or later, so remote participants won't be recorded — only your microphone.")
            }
        } else {
            logToFile("Audio: system audio tap requires macOS 14.2+ — only mic will be recorded")
        }

        // Now start mic capture AFTER system tap (so the aggregate device is already created
        // and won't hijack the mic input). Re-configure to the real hardware device.
        if let chosenDevice = resolveInputDevice() {
            logToFile("Audio: re-setting mic to hardware device '\(chosenDevice.localizedName)' after system tap setup")
            micCapture.configure(inputDeviceID: chosenDevice.uniqueID)
        } else {
            // No preferred device found — clear any stale preference so MicrophoneCapture
            // uses the system default, which is the safest fallback on an unfamiliar Mac.
            micCapture.configure(inputDeviceID: "")
            logToFile("Audio: no preferred input device found, will use system default")
        }

        do {
            try await startMicrophoneWithRetry(systemTapRunning: systemTapStarted)
        } catch {
            // Terminal mic failure after all retries + fallbacks. Tear down the
            // system-audio tap before bailing — otherwise its ScreenCaptureKit
            // stream is leaked, and accumulating streams wedge the HAL so input
            // fails with -10868 on EVERY device until relaunch. Reset all state so
            // the NEXT attempt starts clean and the app stays usable (no relaunch).
            logToFile("Audio: mic capture FAILED terminally after retries — full teardown so the app stays usable")
            micCapture.stop()
            if #available(macOS 14.2, *) {
                systemAudioTap?.stop()
            }
            bufferManager.finishRecording()
            isCapturing = false
            throw error
        }
        let engineRunning = micCapture.engine.isRunning
        let inputFormat = micCapture.engine.inputNode.outputFormat(forBus: 0)
        logToFile("Audio: mic capture STARTED (device: \(resolveInputDevice()?.localizedName ?? "default"), engine.running=\(engineRunning), inputFormat=\(inputFormat.sampleRate)Hz/\(inputFormat.channelCount)ch)")

        // Start silence monitoring AFTER both captures are running
        consecutiveSilentSeconds = 0
        consecutiveMicDeadSeconds = 0
        micProblemWarned = false
        silenceCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }

            // Check buffer capacity limit (prevents multi-GB buffer from long recordings)
            if self.bufferManager.isAtCapacity {
                Logger.audio.warning("Buffer capacity reached (\(Int(self.bufferManager.maxRecordingDurationSeconds / 3600))h limit) — triggering auto-stop")
                self.onCapacityReached?()
                return
            }

            // Dead-mic detection: mic produces no signal while system audio is clearly
            // live. This is the "wrong input device" failure (e.g. an output-only
            // headphone dongle selected as the mic) — the call records remote audio
            // fine but the local mic is silent, so we warn the user without stopping.
            if !self.micProblemWarned
                && !self.isMicRecovering
                && self.micLevel < self.micDeadThreshold
                && self.systemLevel >= self.systemActiveThreshold {
                self.consecutiveMicDeadSeconds += 1
                if self.consecutiveMicDeadSeconds >= self.micDeadWarnSeconds {
                    self.micProblemWarned = true
                    self.logToFile("Audio: mic appears DEAD — no signal for \(self.consecutiveMicDeadSeconds)s while system audio active. Likely wrong input device.")
                    Logger.audio.warning("Mic dead-signal detected while system audio active — warning user")
                    self.onMicProblemDetected?(
                        "Your microphone isn't picking up any sound, but the call audio is being recorded. "
                        + "Check System Settings > Sound > Input and pick your microphone — your voice won't be in this transcript otherwise."
                    )
                }
            } else if self.micLevel >= self.micDeadThreshold {
                self.consecutiveMicDeadSeconds = 0
            }

            // Silence = both mic AND system audio below threshold.
            // Must check both: mic can be zero (e.g. aggregate device routing issue) while
            // remote participants are still speaking over system audio, and vice versa.
            // Threshold lowered from 0.005 — USB webcam mics have very low signal (~0.002-0.006)
            if self.micLevel < 0.001 && self.systemLevel < 0.001 {
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

        // Install device-change listeners LAST — after isCapturing is set and all
        // start-time device churn (aggregate creation, the tap dance) is done — so
        // they only fire on genuine mid-recording changes.
        installAudioDeviceListeners()
    }

    /// Start the mic engine resiliently against CoreAudio -10868
    /// (`kAudioUnitErr_FormatNotSupported`). That error means the input device
    /// couldn't be acquired — almost always TRANSIENT: another app is holding the
    /// mic (a browser tab or Zoom/Meet/Teams in a call), or the audio HAL is
    /// briefly wedged after a prior crash/leak. A single immediate retry isn't
    /// enough because the contending app or HAL often needs a second or two to
    /// release. We retry with exponential backoff (recreating the engine each
    /// time via `micCapture.stop()`), and as a last resort tear down the
    /// system-audio tap — whose aggregate device can itself wedge the hardware
    /// input — and record mic-only. Backoff uses `Task.sleep`, so the main actor
    /// stays responsive between attempts (no UI freeze). Throws only if every
    /// path fails; callers then reset state so the app stays usable.
    private func startMicrophoneWithRetry(systemTapRunning: Bool) async throws {
        func attempt(useDefaultDevice: Bool) -> Error? {
            if useDefaultDevice {
                micCapture.configure(inputDeviceID: "")
            } else if let dev = resolveInputDevice() {
                micCapture.configure(inputDeviceID: dev.uniqueID)
            } else {
                micCapture.configure(inputDeviceID: "")
            }
            do { try micCapture.start(); return nil } catch { return error }
        }

        // Attempt 1: the preferred/auto-selected device.
        if attempt(useDefaultDevice: false) == nil { return }

        // Attempts 2…4: let the contending app / HAL settle, recreate the engine,
        // and fall back to the system default device.
        let backoffsNs: [UInt64] = [400_000_000, 900_000_000, 1_800_000_000]  // 0.4s, 0.9s, 1.8s
        var lastError: Error?
        for (i, delay) in backoffsNs.enumerated() {
            micCapture.stop()  // recreates the engine — makes the next start idempotent
            try? await Task.sleep(nanoseconds: delay)
            if let err = attempt(useDefaultDevice: true) {
                lastError = err
                logToFile("Audio: mic start retry \(i + 2)/\(backoffsNs.count + 1) failed after backoff: \(err.localizedDescription)")
            } else {
                logToFile("Audio: mic start SUCCEEDED on retry \(i + 2) (device/HAL had to settle)")
                return
            }
        }

        // AVAudioEngine still can't get the mic. The diagnostics show this is
        // almost always the conferencing app (Zoom/Meet/Teams) holding the device
        // — AVAudioEngine's input unit loses that contention with -10868. So
        // capture the mic through ScreenCaptureKit instead: SCK taps the mic at
        // the system level and COEXISTS with the call app (it's already capturing
        // system audio from that same call). macOS 15+.
        if systemTapRunning, #available(macOS 15.0, *), let tap = systemAudioTap {
            logToFile("Audio: AVAudioEngine mic blocked (-10868) — switching mic capture to ScreenCaptureKit (coexists with the call app)")
            micCapture.stop()  // fully release the AVAudioEngine input
            tap.onMicBuffer = { [weak self] buffer, time in
                guard let self else { return }
                self.bufferManager.appendMicBuffer(buffer, at: time)
                self.updateMicLevel(buffer)
            }
            // Restart the stream with mic enabled. Try the preferred device, then
            // the system default; verify buffers actually flow before trusting it.
            for micUID in [resolveInputDevice()?.uniqueID, nil] {
                tap.stop()
                try? await Task.sleep(nanoseconds: 300_000_000)
                do {
                    try await tap.start(captureMicrophone: true, micDeviceUID: micUID)
                } catch {
                    logToFile("Audio: SCK mic start failed (device=\(micUID ?? "default")): \(error.localizedDescription)")
                    continue
                }
                try? await Task.sleep(nanoseconds: 1_500_000_000)  // let mic buffers arrive
                if tap.micBufferCount > 0 {
                    logToFile("Audio: mic now captured via ScreenCaptureKit (\(tap.micBufferCount) buffers, device=\(micUID ?? "default")) — full mic+system recording")
                    micSource = .screenCaptureKit
                    return
                }
                logToFile("Audio: SCK mic produced no buffers (device=\(micUID ?? "default"))")
            }
            // SCK mic didn't produce audio — drop it and keep system audio only.
            tap.onMicBuffer = nil
            tap.stop()
            try? await Task.sleep(nanoseconds: 300_000_000)
            try? await tap.start()
        }

        // Non-fatal degradation: if we have system audio, record SYSTEM-ONLY
        // rather than failing the whole meeting. The user still gets the other
        // participants and a transcript — never a blocking error mid-meeting.
        if systemTapRunning {
            logToFile("Audio: recording SYSTEM-ONLY this session — mic unavailable (held by another app)")
            onSystemAudioUnavailable?("Your microphone is in use by another app, so this recording captures the other participants but not your own voice. Quit the app using the mic (a browser tab in a call, Zoom, Meet, or Teams) and start again to capture both sides.")
            return
        }

        // Truly nothing to record — no mic AND no system audio.
        throw AudioCaptureError.captureSetupFailed(
            "Couldn't access the microphone"
            + (lastError != nil ? " (\(lastError!.localizedDescription))" : "")
            + ", and no system audio is available. Close any app using the mic, or grant Screen Recording permission, then start again. You don't need to restart Meeting Manager."
        )
    }

    /// Stop all audio capture
    func stopCapture() async -> URL? {
        isStoppingCapture = true
        defer { isStoppingCapture = false }
        // Cancel any in-flight mic recovery / switching and tear down listeners
        // up front, so nothing tries to resume a recording we're ending.
        removeAudioDeviceListeners()
        micRecoveryDeadlineTask?.cancel()
        micRecoveryDeadlineTask = nil
        if isMicRecovering {
            isMicRecovering = false
            onMicRecoveryStateChanged?(false)
        }
        pendingSwitchUID = nil

        // Let an in-flight mic switch land before tearing down — its start()
        // arriving after micCapture.stop() would resurrect the engine.
        if let switchTask = activeMicSwitchTask {
            _ = await switchTask.value
            activeMicSwitchTask = nil
        }

        silenceCheckTimer?.invalidate()
        silenceCheckTimer = nil
        consecutiveSilentSeconds = 0
        consecutiveMicDeadSeconds = 0
        micProblemWarned = false
        micCapture.stop()
        if #available(macOS 14.2, *) {
            systemAudioTap?.stop()
        }

        // finishRecording streams BOTH full WAVs to rebuild the mixed file
        // (~1.4 GB of I/O for a 2-hour meeting). Run it detached and await:
        // the MainActor is released for the duration instead of beachballing
        // at the exact moment the user clicks Stop, and callers still get
        // the merged file before transcription is enqueued.
        let bm = bufferManager
        await Task.detached(priority: .userInitiated) {
            bm.finishRecording()
        }.value

        isCapturing = false
        micLevel = 0
        systemLevel = 0

        return currentAudioFileURL
    }

    /// Get the buffer manager for the transcription service
    var transcriptionBuffer: AudioBufferManager {
        bufferManager
    }

    // MARK: - Dynamic mic switching

    private enum MicRecoveryReason { case disconnected, switchFailed }

    /// Switch the active microphone mid-recording WITHOUT ending the meeting.
    /// `uid` nil = resolve via override/auto. No-ops when not capturing, when the
    /// target is already active, or (for auto-follow) on the SCK mic path. Serialized
    /// so rapid requests collapse to the final selection. The WAV file and the
    /// system-audio tap are never touched — only the mic engine re-points.
    func switchMicrophone(toUID requestedUID: String?) async {
        guard isCapturing, !isStoppingCapture else {
            logToFile("Audio: mic switch ignored — not capturing (or stopping)")
            return
        }
        guard !isMicSwitching else {
            pendingSwitchUID = .some(requestedUID)   // overwrite — only the latest wins
            return
        }
        isMicSwitching = true
        defer {
            isMicSwitching = false
            if case let .some(next) = pendingSwitchUID {
                pendingSwitchUID = nil
                Task { @MainActor in await self.switchMicrophone(toUID: next) }
            }
        }

        // Resolve target: an explicit (validated) UID wins, else override/best.
        let target: AVCaptureDevice?
        if let requestedUID, let dev = sessionManager.inputDevice(forUID: requestedUID) {
            target = dev
        } else {
            target = resolveInputDevice()
        }
        guard let target else {
            logToFile("Audio: mic switch — no usable device, keeping current")
            return
        }

        // No-op if we're already on it.
        let targetID = sessionManager.deviceID(forUID: target.uniqueID)
        if targetID != AudioDeviceID(kAudioObjectUnknown), targetID == micCapture.currentDeviceID {
            logToFile("Audio: mic switch no-op — already on \(target.localizedName)")
            return
        }

        // SCK fallback path: no AVAudioEngine mic to swap; restart the stream instead.
        if micSource == .screenCaptureKit {
            await switchSCKMic(toUID: target.uniqueID, label: target.localizedName)
            return
        }

        // Engine path — run the (briefly blocking) switch off the main actor.
        // The task is stored so stopCapture can await an in-flight switch:
        // switchDevice is stop→configure→start, and a start() landing after
        // the recording's teardown would leave the mic engine running.
        let targetUID = target.uniqueID
        let switchTask = Task.detached(priority: .userInitiated) { [micCapture] in
            micCapture.switchDevice(toUID: targetUID)?.localizedDescription
        }
        activeMicSwitchTask = switchTask
        let failure: String? = await switchTask.value
        activeMicSwitchTask = nil

        if let failure {
            logToFile("Audio: mic switch FAILED (\(target.localizedName)): \(failure) — entering recovery")
            beginMicRecovery(reason: .switchFailed)
            return
        }
        consecutiveMicDeadSeconds = 0
        micProblemWarned = false
        logToFile("Audio: mic switch OK — now on \(target.localizedName) (engine.running=\(micCapture.engine.isRunning))")
    }

    /// Switch the microphone while on the ScreenCaptureKit fallback path. Restarting
    /// the SCK stream also restarts system capture, so this is reserved for explicit
    /// user picks / recovery — auto-follow suppresses it upstream.
    private func switchSCKMic(toUID uid: String, label: String) async {
        guard #available(macOS 15.0, *), let tap = systemAudioTap else {
            logToFile("Audio: SCK mic switch unavailable on this OS — keeping current")
            return
        }
        logToFile("Audio: switching SCK mic to \(label)")
        tap.stop()
        try? await Task.sleep(nanoseconds: 300_000_000)
        do {
            try await tap.start(captureMicrophone: true, micDeviceUID: uid)
        } catch {
            logToFile("Audio: SCK mic switch failed (\(label)): \(error.localizedDescription)")
            return
        }
        try? await Task.sleep(nanoseconds: 1_000_000_000)  // let mic buffers arrive
        logToFile(tap.micBufferCount > 0
            ? "Audio: SCK mic switch OK — now on \(label)"
            : "Audio: SCK mic switch produced no buffers (\(label))")
    }

    // MARK: - Mic recovery (disconnect)

    /// Enter bounded recovery: keep the recording + file + system tap alive, warn
    /// once, and wait `micRecoveryWindow` for a usable replacement mic. Ends the
    /// meeting (via the existing auto-stop) only if the window expires.
    private func beginMicRecovery(reason: MicRecoveryReason) {
        guard isCapturing, !isStoppingCapture, !isMicRecovering else { return }
        isMicRecovering = true
        onMicRecoveryStateChanged?(true)
        micProblemWarned = true   // suppress the generic dead-mic warning; we have our own
        logToFile("Audio: mic recovery STARTED (\(reason)) — holding recording open; system audio continues")
        onMicProblemDetected?(
            "Your microphone disconnected. Meeting Manager is still recording the call — "
            + "reconnect a microphone and your audio will resume automatically."
        )
        micRecoveryDeadlineTask?.cancel()
        micRecoveryDeadlineTask = Task { [weak self] in
            guard let self else { return }
            if await self.attemptMicResume() { return }   // a replacement may already be present
            try? await Task.sleep(nanoseconds: UInt64(self.micRecoveryWindow * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self.failMicRecovery()
        }
    }

    /// Try to resume onto the best currently-available input. Safe to call
    /// concurrently (deadline task + devices-list listener) — guarded and serialized.
    @discardableResult
    private func attemptMicResume() async -> Bool {
        guard isMicRecovering else { return true }
        guard let target = resolveInputDevice(),
              sessionManager.inputDevice(forUID: target.uniqueID) != nil,
              !sessionManager.isUnreliableInput(uid: target.uniqueID) else {
            return false
        }
        await switchMicrophone(toUID: target.uniqueID)
        guard isMicRecovering else { return true }   // a concurrent attempt may have ended it
        if micCapture.engine.isRunning {
            endMicRecovery(resumedOn: target.localizedName)
            return true
        }
        return false
    }

    private func endMicRecovery(resumedOn label: String) {
        guard isMicRecovering else { return }
        micRecoveryDeadlineTask?.cancel()
        micRecoveryDeadlineTask = nil
        isMicRecovering = false
        onMicRecoveryStateChanged?(false)
        consecutiveMicDeadSeconds = 0
        consecutiveSilentSeconds = 0
        micProblemWarned = false
        logToFile("Audio: mic recovery ENDED — resumed on \(label)")
    }

    private func failMicRecovery() {
        guard isMicRecovering, isCapturing else { return }
        isMicRecovering = false
        onMicRecoveryStateChanged?(false)
        micRecoveryDeadlineTask = nil
        logToFile("Audio: mic recovery window (\(Int(micRecoveryWindow))s) expired — no replacement; ending recording")
        onSilenceDetected?()   // reuse the established auto-stop → AppState.stopRecording
    }

    // MARK: - CoreAudio device listeners

    /// Install listeners for default-input change (auto-follow) and device-list
    /// change (recovery retry). Installed at the END of startCapture so start-time
    /// device churn never fires them; idempotent.
    private func installAudioDeviceListeners() {
        guard defaultInputListenerBlock == nil else { return }
        let systemObject = AudioObjectID(kAudioObjectSystemObject)

        var defaultAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let defaultBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.handleDefaultInputChanged() }
        }
        defaultInputListenerBlock = defaultBlock
        AudioObjectAddPropertyListenerBlock(systemObject, &defaultAddr, listenerQueue, defaultBlock)

        var devicesAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let devicesBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.handleDevicesListChanged() }
        }
        devicesListListenerBlock = devicesBlock
        AudioObjectAddPropertyListenerBlock(systemObject, &devicesAddr, listenerQueue, devicesBlock)

        logToFile("Audio: CoreAudio device listeners installed")
    }

    private func removeAudioDeviceListeners() {
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        if let block = defaultInputListenerBlock {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(systemObject, &addr, listenerQueue, block)
            defaultInputListenerBlock = nil
        }
        if let block = devicesListListenerBlock {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(systemObject, &addr, listenerQueue, block)
            devicesListListenerBlock = nil
        }
        defaultFollowDebounceTask?.cancel()
        defaultFollowDebounceTask = nil
    }

    /// System default input changed. Follow it only when the user hasn't pinned a
    /// mic, we're on the engine path, and the new default is a real (non-phantom)
    /// input. Debounced to absorb Control-Center / aggregate flapping.
    private func handleDefaultInputChanged() {
        guard isCapturing, !isMicRecovering else { return }
        guard isMicOverrideEnabledProvider?() != true else {
            logToFile("Audio: default input changed — override ON, not following")
            return
        }
        guard micSource == .engine else {
            logToFile("Audio: default input changed — on SCK mic path, not auto-following")
            return
        }
        defaultFollowDebounceTask?.cancel()
        defaultFollowDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, let self, self.isCapturing, !self.isMicRecovering,
                  self.isMicOverrideEnabledProvider?() != true else { return }
            let newID = self.sessionManager.defaultInputDeviceID()
            guard newID != AudioDeviceID(kAudioObjectUnknown),
                  let uid = self.sessionManager.uid(forDeviceID: newID),
                  let device = self.sessionManager.inputDevice(forUID: uid),
                  !self.sessionManager.isUnreliableInput(uid: uid) else {
                self.logToFile("Audio: default input changed — new default is unusable/phantom, not following")
                return
            }
            if newID == self.micCapture.currentDeviceID { return }   // already on it
            self.logToFile("Audio: default input changed — following to \(device.localizedName)")
            await self.switchMicrophone(toUID: uid)
        }
    }

    /// Device list changed. Only meaningful during recovery, where a newly-appeared
    /// device is our cue to retry the resume.
    private func handleDevicesListChanged() {
        guard isMicRecovering else { return }
        Task { @MainActor in await self.attemptMicResume() }
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
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
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

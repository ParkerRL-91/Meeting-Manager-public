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

    /// Signal-independent mic-health snapshot (TASK-095). Reflects liveness (noise
    /// floor present), device identity, and mute-state even while no one is
    /// speaking — drives the recording-bar status (REQ-6) and is distinct from the
    /// talk-time level meter (`micLevel`). Updated on the 1 Hz health tick.
    @Published private(set) var micHealth: MicHealthSnapshot = .unknown

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

    /// Called when the preferred recording location wasn't writable and capture
    /// fell back to a temporary folder. Non-fatal — the recording still happens;
    /// the message tells the user to fix the location. Surfaced via AppState.
    var onStorageWarning: ((String) -> Void)?

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
    /// System RMS above this means remote participants are clearly *talking*
    /// (not just ambient/blip noise). Raised from 0.01 so a brief network blip
    /// doesn't accumulate dead-mic seconds while the user is listening quietly.
    private let systemActiveThreshold: Float = 0.05
    /// Seconds of effectively-dead mic while system audio is active+loud before
    /// warning. Raised from 45s — a user listening to others for 45s is normal
    /// at the start of a call. 5 minutes of continuous "mic at zero while others
    /// are loudly talking" is the actual dead-device signal worth surfacing.
    private let micDeadWarnSeconds = 300

    // MARK: - Signal-independent mic health (TASK-095)

    /// Window of recent per-tick mic RMS used to classify liveness. Liveness is
    /// "is there a noise floor", so the classifier keys on the loudest sample in
    /// the window (a working mic floor flickers; a dead stream is flat zero
    /// throughout). Capped at `healthWindowTicks`.
    private var recentMicRMS: [Float] = []
    private let healthWindowTicks = 3

    /// Event-driven re-validation clock (REQ-3): armed on a CoreAudio config
    /// change, it gives the re-pinned device a short window to show a live floor
    /// before the self-heal fires — ≤ ~15 s, vs the old 300 s silence window.
    private var configRevalidateDeadlineTask: Task<Void, Never>?
    private let configRevalidateWindow: TimeInterval = 12

    /// Self-heal (REQ-5) state: bounded in-place input rebuilds after a config
    /// change wedges capture on a flat/dead stream. Reset per recording.
    private var selfHealAttempts = 0
    private let maxSelfHealAttempts = 3
    private var isSelfHealing = false
    private var selfHealWarned = false
    /// Latches "the mic was live going into a reconfiguration" across re-arms within
    /// one wedge episode (REQ-5). The 2026-06-17 incident reconfigured the shared mic
    /// REPEATEDLY; re-reading was-live from the (now-silent) verdict on each re-arm
    /// would lose the signal and miss the heal. Set true on a config change while a
    /// floor is present; cleared the moment a floor returns or the device is muted
    /// (updateMicHealth), on heal success, and at capture start.
    private var micWasLiveBeforeWedge = false
    /// Internal retry clock for the self-heal ladder (REQ-5). A clean wedge with no
    /// further CoreAudio events would otherwise spend only ONE of the budgeted
    /// attempts and stall; after an unverified heal this re-fires the next attempt
    /// without waiting on an external config/device event. Cancelled on stop.
    private var selfHealRetryTask: Task<Void, Never>?
    private let selfHealRetryDelay: TimeInterval = 3

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
    ///
    /// Assigned and cleared on the main actor (AppState wires/unwires the Apple
    /// Speech feed at recording start/stop) but INVOKED on the mic engine's tap
    /// thread, so the storage is lock-guarded: a plain property let ARC race the
    /// reader's retain of the closure box against `= nil`'s release. `nonisolated`
    /// because the tap thread reads it.
    private let _callbackLock = NSLock()
    nonisolated(unsafe) private var _onRawMicBuffer: ((AVAudioPCMBuffer) -> Void)?
    nonisolated var onRawMicBuffer: ((AVAudioPCMBuffer) -> Void)? {
        get { _callbackLock.withLock { _onRawMicBuffer } }
        set { _callbackLock.withLock { _onRawMicBuffer = newValue } }
    }

    /// Whether the mic engine is currently running. Goes through
    /// `MicrophoneCapture.engineLiveness`, which snapshots under MicrophoneCapture's
    /// lock — callers must never reach for the `AVAudioEngine` reference itself,
    /// which lifecycle operations reassign.
    var micEngineIsRunning: Bool { micCapture.engineLiveness.isRunning }
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

    /// In-flight detached self-heal rebuild, if any. Awaited by stopCapture for the
    /// same reason as the switch task, and additionally so the teardown's
    /// `micCapture.stop()` — which now waits on MicrophoneCapture's lifecycle queue
    /// — never blocks the main actor behind a multi-second device cycle.
    private var activeMicRebuildTask: Task<String?, Never>?

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

    /// ONE gate for both mic-lifecycle coordinators. `switchMicrophone` and
    /// `selfHealInput` each drive MicrophoneCapture through a stop→start, and each
    /// used to guard only its OWN flag — so a self-heal and a switch could run
    /// concurrently, which is precisely the overlap that raced the engine. Held for
    /// the duration of either operation; a switch that loses the race parks itself in
    /// `pendingSwitchUID` (only the final selection wins) and is drained by whichever
    /// operation was holding the gate.
    private var isMicLifecycleBusy = false
    private var pendingSwitchUID: (String?)?

    /// Run the request parked while the gate was held. Called from the gate's
    /// release path in both `switchMicrophone` and `selfHealInput`.
    private func drainPendingSwitch() {
        guard case let .some(next) = pendingSwitchUID else { return }
        pendingSwitchUID = nil
        Task { @MainActor in await self.switchMicrophone(toUID: next) }
    }

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
    /// Why the current recovery started — failure semantics differ: a
    /// start-time failure degrades to system-only on expiry (the call audio
    /// is good; ending the meeting would throw it away), while a
    /// mid-recording disconnect keeps the established end-recording behavior.
    private var micRecoveryReason: MicRecoveryReason = .disconnected
    /// Grace period before recovery surfaces anything to the user. A
    /// Bluetooth mic finishing its A2DP→HFP switch resumes in 2–5 s and the
    /// user should never see an error for that (TASK-029).
    private let micRecoveryWarnGrace: TimeInterval = 8
    private var micRecoveryWarnTask: Task<Void, Never>?
    /// Set by startMicrophoneWithRetry when the mic couldn't start but system
    /// audio is recording; consumed at the end of startCapture (recovery can
    /// only begin once `isCapturing` is true and the device listeners exist).
    private var micStartFailedPendingRecovery = false

    /// One-shot: the next startCapture records the microphone only
    /// (quick memos — TASK-052).
    var nextCaptureSkipsSystemAudio = false

    /// Last tick on which system audio cleared the active threshold. The
    /// dead-mic detector uses a 10 s recency window off this instead of a
    /// same-tick check — remote audio dips between sentences and a same-tick
    /// requirement reset the counter before it could ever warn (TASK-034).
    private var lastSystemAudioActiveAt = Date.distantPast

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
        // Resolve a directory that is verified writable *now*. If the user's
        // preferred location can't be written (foreign-owned folder, read-only
        // volume), this routes to a temp fallback so the recording is never
        // lost, and we warn the user to fix the location.
        let audioDir: URL
        switch RecordingStorage.shared.resolveWritableDirectory() {
        case .ok(let url):
            audioDir = url
        case .fellBack(let url, let original, let error):
            audioDir = url
            onStorageWarning?("Couldn't write recordings to “\(original.path)” (\(error.localizedDescription)). Recording to a temporary folder for now — pick a working location in Settings → General → Recordings.")
        }
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
        // Read the property dynamically so late-set callbacks are captured
        // correctly — snapshotting it under `_callbackLock` first, because this runs
        // on the tap thread while the main actor can be clearing it.
        micCapture.onRawBuffer = { [weak self] buffer in
            guard let sink = self?.onRawMicBuffer else { return }
            sink(buffer)
        }

        // Wire diagnostic logging from mic capture
        micCapture.onDiagnostic = { [weak self] msg in
            self?.logToFile(msg)
        }

        // REQ-3: on a CoreAudio configuration change (device (dis)connect, a
        // meeting app renegotiating the shared mic mid-call), run event-driven
        // liveness re-validation on a short clock instead of waiting on the
        // 300 s silence window. MicrophoneCapture has already re-pinned + restarted
        // the engine by the time this fires.
        micCapture.onConfigChangeRevalidate = { [weak self] in
            Task { @MainActor in self?.armConfigChangeRevalidation() }
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
        micStartFailedPendingRecovery = false
        // Quick memos (TASK-052): capture the mic only. Consumed per start —
        // set by AppState.startQuickMemo immediately before the state machine
        // starts capture. Skipping the tap also suppresses the
        // "grant Screen Recording" toast a 20-second memo shouldn't trigger.
        let skipSystemAudio = nextCaptureSkipsSystemAudio
        nextCaptureSkipsSystemAudio = false
        var systemTapStarted = false
        if #available(macOS 14.2, *), !skipSystemAudio {
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
        // An explicit override = the user pinned this device → the cycle tries it
        // FIRST (ahead of the call's in-use mic) and honors it, even the built-in (TASK-114).
        micCapture.preferredIsExplicit = (isMicOverrideEnabledProvider?() == true)

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
        let engineState = micCapture.engineLiveness
        let micSourceLabel = micSource == .screenCaptureKit ? "ScreenCaptureKit"
            : micStartFailedPendingRecovery ? "NONE (recovery pending)" : "engine"
        logToFile("Audio: mic capture STARTED (device: \(resolveInputDevice()?.localizedName ?? "default"), source: \(micSourceLabel), engine.running=\(engineState.isRunning), inputFormat=\(engineState.sampleRate)Hz/\(engineState.channelCount)ch)")

        // Start silence monitoring AFTER both captures are running
        consecutiveSilentSeconds = 0
        consecutiveMicDeadSeconds = 0
        micProblemWarned = false
        lastSystemAudioActiveAt = .distantPast
        recentMicRMS.removeAll(keepingCapacity: true)
        selfHealAttempts = 0
        isSelfHealing = false
        selfHealWarned = false
        selfHealRetryTask?.cancel()
        selfHealRetryTask = nil
        micHealth = .unknown
        silenceCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }

            // Check buffer capacity limit (prevents multi-GB buffer from long recordings)
            if self.bufferManager.isAtCapacity {
                Logger.audio.warning("Buffer capacity reached (\(Int(self.bufferManager.maxRecordingDurationSeconds / 3600))h limit) — triggering auto-stop")
                self.onCapacityReached?()
                return
            }

            // Signal-independent mic health (TASK-095): classify the noise floor
            // and combine with device identity + mute-state every tick.
            self.updateMicHealth()

            // Dead-mic detection, now verdict-driven. The "wrong input device on
            // a live call" failure is real (an output-only dongle selected as the
            // mic records the call fine but no local voice) — but a `flatZero`
            // reading is NEVER enough on its own: a quiet listener and a muted
            // user both read zero and must NOT be warned (REQ-1, REQ-7). Only a
            // `.dead`/`.deviceMismatch` verdict — which requires device-level
            // failure evidence — counts, and only while the call is live.
            // "System active" is a 10 s recency window, not a same-tick check:
            // remote audio fluctuates around the threshold between sentences,
            // and the old same-tick requirement reset the counter every quiet
            // second — a stone-dead mic in a real call never reached the warn
            // threshold (TASK-034).
            if self.systemLevel >= self.systemActiveThreshold {
                self.lastSystemAudioActiveAt = Date()
            }
            let systemRecentlyActive = Date().timeIntervalSince(self.lastSystemAudioActiveAt) < 10
            let verdict = self.micHealth.verdict
            let verdictWarnsDead = (verdict == .dead || verdict == .deviceMismatch)
            if !self.micProblemWarned
                && !self.isMicRecovering
                && !self.isSelfHealing
                && verdictWarnsDead
                && systemRecentlyActive {
                self.consecutiveMicDeadSeconds += 1
                if self.consecutiveMicDeadSeconds >= self.micDeadWarnSeconds {
                    self.micProblemWarned = true
                    self.logToFile("Audio: mic appears DEAD — verdict=\(verdict) for \(self.consecutiveMicDeadSeconds)s while system audio active. Likely wrong input device.")
                    Logger.audio.warning("Mic dead-signal detected while system audio active — warning user")
                    self.onMicProblemDetected?(
                        "Your microphone isn't picking up any sound, but the call audio is being recorded. "
                        + "Check System Settings > Sound > Input and pick your microphone — your voice won't be in this transcript otherwise."
                    )
                }
            } else if verdict.isHealthy {
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
        micWasLiveBeforeWedge = false   // fresh wedge-latch per recording

        // Install device-change listeners LAST — after isCapturing is set and all
        // start-time device churn (aggregate creation, the tap dance) is done — so
        // they only fire on genuine mid-recording changes.
        installAudioDeviceListeners()

        // Mic never started but the call audio is recording: begin bounded
        // recovery now that isCapturing is true and the listeners are live.
        if micStartFailedPendingRecovery {
            micStartFailedPendingRecovery = false
            beginMicRecovery(reason: .startFailed)
        }
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
        // `micCapture.start()` cycles devices and runs the ~0.6 s liveness probe
        // (REQ-4), which blocks its calling thread. Run it OFF the main actor so
        // the initial acquisition doesn't beachball the UI for the probe window —
        // the mid-recording switch/heal paths already detach for the same reason.
        // Device resolution stays on the main actor (it reads `sessionManager`).
        func attempt(useDefaultDevice: Bool) async -> Error? {
            if useDefaultDevice {
                micCapture.configure(inputDeviceID: "")
            } else if let dev = resolveInputDevice() {
                micCapture.configure(inputDeviceID: dev.uniqueID)
            } else {
                micCapture.configure(inputDeviceID: "")
            }
            return await Task.detached(priority: .userInitiated) { [micCapture] in
                do { try micCapture.start(); return nil } catch { return error }
            }.value
        }

        // Attempt 1: the preferred/auto-selected device.
        if await attempt(useDefaultDevice: false) == nil { return }

        // Attempts 2…5: let the contending app / HAL settle, recreate the engine,
        // and fall back to the system default device. The final 3 s rung exists
        // for Bluetooth headsets renegotiating A2DP→HFP when input opens — that
        // takes 1–3+ s, longer when the call app is grabbing the same mic
        // (TASK-029); system audio is already recording during these waits.
        let backoffsNs: [UInt64] = [400_000_000, 900_000_000, 1_800_000_000, 3_000_000_000]
        var lastError: Error?
        for (i, delay) in backoffsNs.enumerated() {
            micCapture.stop()  // recreates the engine — makes the next start idempotent
            try? await Task.sleep(nanoseconds: delay)
            if let err = await attempt(useDefaultDevice: true) {
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
                // Require SIGNAL, not just buffer presence: SCK can deliver
                // perfectly-formed frames of pure silence when the device
                // isn't actually capturing (the 2026-06-11 notification-start
                // incident accepted a dead mic this way and closed every
                // recovery path behind it — TASK-034). 2e-4 sits well below
                // idle room noise on a live mic and well above true silence.
                if tap.micBufferCount > 0, tap.micPeakRMS > 0.0002 {
                    logToFile("Audio: mic now captured via ScreenCaptureKit (\(tap.micBufferCount) buffers, peak rms \(String(format: "%.6f", tap.micPeakRMS)), device=\(micUID ?? "default")) — full mic+system recording")
                    micSource = .screenCaptureKit
                    return
                }
                logToFile("Audio: SCK mic produced \(tap.micBufferCount) buffer(s) with peak rms \(String(format: "%.6f", tap.micPeakRMS)) (device=\(micUID ?? "default")) — \(tap.micBufferCount == 0 ? "no buffers" : "silent, rejecting")")
            }
            // SCK mic didn't produce audio — drop it and keep system audio only.
            // STOP FIRST, then clear the sink: the scmic delivery queue is live
            // until stop() flips the tap's `isRunning`, so nilling the callback
            // ahead of it released the closure box out from under a thread that was
            // about to invoke it.
            tap.stop()
            tap.onMicBuffer = nil
            try? await Task.sleep(nanoseconds: 300_000_000)
            try? await tap.start()
        }

        // Non-fatal degradation: if we have system audio, record SYSTEM-ONLY
        // rather than failing the whole meeting — and instead of declaring
        // defeat with an instant banner, arm bounded mic recovery: the most
        // common cause (a Bluetooth mic mid profile-switch, or the call app
        // briefly holding the device) clears within seconds, and the recovery
        // loop picks the mic up with no user-visible error at all. The flag is
        // consumed at the end of startCapture, after `isCapturing` is true and
        // the device listeners are installed (beginMicRecovery requires both).
        if systemTapRunning {
            logToFile("Audio: mic unavailable at start — recording SYSTEM-ONLY for now; bounded recovery will keep trying")
            micStartFailedPendingRecovery = true
            return
        }

        // Truly nothing to record — no mic AND no system audio.
        throw AudioCaptureError.captureSetupFailed(
            "Couldn't access the microphone"
            + (lastError != nil ? " (\(lastError!.localizedDescription))" : "")
            + ", and no system audio is available. Close any app using the mic, or grant Screen Recording permission, then start again. You don't need to restart Meeting Manager."
        )
    }

    /// Last-N-seconds mixed audio for catch-me-up (TASK-053). Empty when
    /// not recording or the ring hasn't filled yet.
    func catchUpSnapshot(seconds: Double) -> [Float] {
        guard isCapturing else { return [] }
        return bufferManager.liveRingSnapshot(lastSeconds: seconds)
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
        micRecoveryWarnTask?.cancel()
        micRecoveryWarnTask = nil
        configRevalidateDeadlineTask?.cancel()
        configRevalidateDeadlineTask = nil
        selfHealRetryTask?.cancel()
        selfHealRetryTask = nil
        isSelfHealing = false
        if isMicRecovering {
            isMicRecovering = false
            onMicRecoveryStateChanged?(false)
        }
        pendingSwitchUID = nil

        // Let an in-flight mic switch or self-heal rebuild land before tearing
        // down — its start() arriving after micCapture.stop() would resurrect the
        // engine, and `micCapture.stop()` would otherwise block the main actor
        // behind MicrophoneCapture's lifecycle queue for the whole device cycle.
        if let switchTask = activeMicSwitchTask {
            _ = await switchTask.value
            activeMicSwitchTask = nil
        }
        if let rebuildTask = activeMicRebuildTask {
            _ = await rebuildTask.value
            activeMicRebuildTask = nil
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
        micHealth = .unknown

        return currentAudioFileURL
    }

    // MARK: - Dynamic mic switching

    private enum MicRecoveryReason { case disconnected, switchFailed, startFailed }

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
        guard !isMicLifecycleBusy else {
            pendingSwitchUID = .some(requestedUID)   // overwrite — only the latest wins
            return
        }
        isMicLifecycleBusy = true
        defer {
            isMicLifecycleBusy = false
            drainPendingSwitch()
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

        // No-op only if we're already on it AND the engine is actually
        // running. After a start-time failure the device is configured but
        // the engine never started — treating that as "already on it" would
        // block start-failed recovery from ever retrying (TASK-029).
        // One `engineLiveness` snapshot answers both halves, so the bound device
        // and the run state can't come from different instants.
        let targetID = sessionManager.deviceID(forUID: target.uniqueID)
        let engineState = micCapture.engineLiveness
        if targetID != AudioDeviceID(kAudioObjectUnknown), targetID == engineState.deviceID,
           engineState.isRunning {
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
        // A user pick (override on) pins the device — the cycle inside switchDevice
        // tries it FIRST and honors it even if it's the built-in (TASK-114).
        micCapture.preferredIsExplicit = (isMicOverrideEnabledProvider?() == true)
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
        let postSwitchRunning = micCapture.engineLiveness.isRunning
        logToFile("Audio: mic switch OK — now on \(micCapture.currentDeviceName) (requested \(target.localizedName), engine.running=\(postSwitchRunning))")
        // A successful switch — a user pick from the recovery banner, or an auto
        // resume — ends any in-flight recovery search immediately, so the inline
        // "finding a mic" banner clears right away instead of waiting for the next
        // poll tick (TASK-104, "so it stops searching quickly").
        if isMicRecovering, postSwitchRunning {
            endMicRecovery(resumedOn: target.localizedName)
        }
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
        logToFile(tap.micBufferCount > 0 && tap.micPeakRMS > 0.0002
            ? "Audio: SCK mic switch OK — now on \(label)"
            : "Audio: SCK mic switch produced no usable signal (\(tap.micBufferCount) buffers, peak rms \(String(format: "%.6f", tap.micPeakRMS)), \(label))")
    }

    // MARK: - Mic recovery (disconnect)

    /// Enter bounded recovery: keep the recording + file + system tap alive, warn
    /// once, and wait `micRecoveryWindow` for a usable replacement mic. Ends the
    /// meeting (via the existing auto-stop) only if the window expires.
    private func beginMicRecovery(reason: MicRecoveryReason) {
        guard isCapturing, !isStoppingCapture, !isMicRecovering else { return }
        isMicRecovering = true
        micRecoveryReason = reason
        onMicRecoveryStateChanged?(true)
        micProblemWarned = true   // suppress the generic dead-mic warning; we have our own
        logToFile("Audio: mic recovery STARTED (\(reason)) — holding recording open; system audio continues")

        // Warn only if recovery hasn't succeeded within the grace period. The
        // common causes (Bluetooth A2DP→HFP switch, the call app briefly
        // holding the device, unplug-replug) resolve in seconds — surfacing an
        // error banner before recovery has even tried is what made a working
        // mic look broken (TASK-029). Quick resumes show nothing at all.
        micRecoveryWarnTask?.cancel()
        micRecoveryWarnTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(self.micRecoveryWarnGrace * 1_000_000_000))
            guard !Task.isCancelled, self.isMicRecovering else { return }
            self.onMicProblemDetected?(reason == .startFailed
                ? "Your microphone hasn't become available yet, so the recording currently has the call audio only. "
                  + "Meeting Manager keeps trying and will add your mic the moment it frees up."
                : "Your microphone disconnected. Meeting Manager is still recording the call — "
                  + "reconnect a microphone and your audio will resume automatically."
            )
        }

        // Poll inside the window in addition to the device listeners: a
        // Bluetooth profile switch changes an EXISTING device's format
        // without necessarily firing the device-list listener, so
        // event-driven resume alone can miss exactly the case that matters.
        micRecoveryDeadlineTask?.cancel()
        micRecoveryDeadlineTask = Task { [weak self] in
            guard let self else { return }
            let pollOffsets: [TimeInterval] = [0, 2, 5, 10, 20]
            var elapsed: TimeInterval = 0
            for offset in pollOffsets {
                if offset > elapsed {
                    try? await Task.sleep(nanoseconds: UInt64((offset - elapsed) * 1_000_000_000))
                    elapsed = offset
                }
                guard !Task.isCancelled, self.isMicRecovering else { return }
                if await self.attemptMicResume() { return }
            }
            let remaining = self.micRecoveryWindow - elapsed
            if remaining > 0 {
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            }
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
        if micCapture.engineLiveness.isRunning {
            // Device cycling may have landed on a different (working) mic
            // than the target we asked for — report the device we're
            // actually capturing on.
            endMicRecovery(resumedOn: micCapture.currentDeviceName)
            return true
        }
        return false
    }

    private func endMicRecovery(resumedOn label: String) {
        guard isMicRecovering else { return }
        micRecoveryDeadlineTask?.cancel()
        micRecoveryDeadlineTask = nil
        micRecoveryWarnTask?.cancel()
        micRecoveryWarnTask = nil
        isMicRecovering = false
        onMicRecoveryStateChanged?(false)
        consecutiveMicDeadSeconds = 0
        consecutiveSilentSeconds = 0
        micProblemWarned = false
        logToFile("Audio: mic recovery ENDED — resumed on \(label)")
    }

    private func failMicRecovery() {
        guard isMicRecovering, isCapturing else { return }
        micRecoveryWarnTask?.cancel()
        micRecoveryWarnTask = nil

        // The initial recovery window expired without a replacement. Do NOT end
        // the meeting (TASK-104) — the call keeps recording via system audio, and
        // the user can pick a microphone from the inline recovery banner. Keep
        // isMicRecovering TRUE so the banner + picker stay up, and keep watching at
        // low frequency for the life of the recording: the device listeners + this
        // poll resume the moment a usable mic appears (this is also the TASK-034
        // start-time-failure behavior, now applied to every reason). The genuine
        // all-silent (mic AND speaker) 5-minute auto-stop remains the backstop for
        // a truly-ended call, so we never record silence forever.
        logToFile("Audio: mic recovery window (\(Int(micRecoveryWindow))s) expired (\(micRecoveryReason)) — NOT ending; inline mic-picker stays up, still watching for a usable mic")
        onMicProblemDetected?(micRecoveryReason == .startFailed
            ? "Your microphone couldn't be started, so the recording currently has the call audio only. "
              + "Reconnect or pick a microphone from the recording bar and it will be added automatically."
            : "Your microphone disconnected. Meeting Manager is still recording the call — "
              + "reconnect or pick a microphone from the recording bar and your audio resumes."
        )
        micRecoveryDeadlineTask?.cancel()
        micRecoveryDeadlineTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.isMicRecovering, self.isCapturing {
                try? await Task.sleep(nanoseconds: 45_000_000_000)
                guard !Task.isCancelled, self.isMicRecovering, self.isCapturing else { return }
                if await self.attemptMicResume() { return }
            }
        }
    }

    // MARK: - Signal-independent mic health (TASK-095)

    /// The device the capture is MEANT to be on (REQ-2). Used as the "intended
    /// device" for the identity check. nil means "no opinion" (the snapshot treats
    /// that as a match — identity mismatch is only ever flagged on positive proof,
    /// never inferred from a missing reading).
    ///
    /// Two modes, matching how the cycler actually binds the device:
    ///   • Override ON — the user pinned a device. The intended device is that pin
    ///     (when still present), so if the cycler couldn't honor it and fell to a
    ///     different mic, the identity check correctly surfaces `.deviceMismatch`.
    ///   • Override OFF (auto-detect) — the cycler's intent IS "capture from the mic
    ///     it bound," whose ordering puts the meeting's in-use mic FIRST
    ///     (`orderedCandidates`). That can differ from `bestInputDevice()`'s
    ///     independent ranking, so comparing against `bestInputDevice()` would
    ///     false-flag a working, meeting-bound mic as a mismatch during a silent
    ///     stretch — needlessly self-healing a live device (the exact false positive
    ///     this task eliminates, and a cardinal-rule violation). In auto-detect mode
    ///     the bound device is by definition the intended one, so report it.
    private func intendedDeviceUID() -> String? {
        if isMicOverrideEnabledProvider?() == true,
           let uid = preferredInputDeviceIDProvider?(),
           sessionManager.inputDevice(forUID: uid) != nil {
            return uid
        }
        return micCapture.currentDeviceUID ?? resolveInputDevice()?.uniqueID
    }

    /// Recompute the mic-health snapshot (called on the 1 Hz tick). Folds the
    /// latest mic RMS into a short window, classifies the noise floor (liveness),
    /// and asks MicrophoneCapture to combine it with device identity + mute-state.
    /// `deviceLevelFailure` — the hard gate for a "dead" verdict — is true only on
    /// real device-level evidence: the engine isn't running, or the input format
    /// is invalid. A `flatZero` reading by itself is NEVER device-level failure.
    private func updateMicHealth() {
        // Fold the latest mic RMS into a short window and classify the floor.
        // Liveness keys on the loudest sample in the window: a working mic's floor
        // flickers above the denormal band, a dead stream stays flat at zero.
        let level = latestMicLevel
        recentMicRMS.append(level)
        if recentMicRMS.count > healthWindowTicks {
            recentMicRMS.removeFirst(recentMicRMS.count - healthWindowTicks)
        }
        let peak = recentMicRMS.max() ?? level
        // "Constant" must catch a FROZEN stream, not just a bit-exact-zero one: a
        // wedged IO buffer can repeat a non-zero DC value whose per-tick RMS is
        // identical every second, while a live mic's floor always flickers. The pure
        // `windowIsConstant` helper treats zero movement across a full window as
        // frozen, so a frozen non-zero constant classifies as `.flatZero` instead of
        // a false `.live` (D1) — and never demotes a genuinely quiet, flickering mic.
        let isConstant = MicLivenessClassifier.windowIsConstant(
            recentMicRMS, minSamples: healthWindowTicks)
        let liveness = MicLivenessClassifier.classify(rms: peak, isConstant: isConstant)

        // SCK-mic fallback path has no AVAudioEngine to introspect for identity /
        // mute / format, and SCK death is handled by `onStreamStopped`. Report the
        // HONEST floor classification rather than asserting "Live": a floor present
        // reads live/quietLive; a flat-zero SCK stream reads `.silentOK` (calm, no
        // warning, no device switch) — never a false "Live" and never a false
        // "dead" (deviceLevelFailure stays false, so the cardinal rule holds).
        if micSource == .screenCaptureKit {
            let verdict = MicLivenessClassifier.verdict(
                liveness: liveness, isIntendedDevice: true,
                isMuted: false, deviceLevelFailure: false)
            micHealth = MicHealthSnapshot(
                deviceUID: nil,
                deviceName: resolveInputDevice()?.localizedName ?? "",
                isIntendedDevice: true,
                isMuted: false,
                liveness: liveness,
                verdict: verdict
            )
            return
        }

        // Device-level failure evidence (NOT a flat-zero reading): the engine
        // stopped, or the input format is unusable. While recovering/self-healing
        // the engine is legitimately torn down, so don't count that as failure.
        // `engineLiveness` snapshots both under MicrophoneCapture's lock so this
        // MainActor read never races the config-change handler reassigning `engine`
        // (D2).
        let engineState = micCapture.engineLiveness
        let deviceLevelFailure = !isMicRecovering && !isSelfHealing
            && (!engineState.isRunning || !engineState.isFormatUsable)

        let snapshot = micCapture.healthSnapshot(
            liveness: liveness,
            intendedDeviceUID: intendedDeviceUID(),
            deviceLevelFailure: deviceLevelFailure
        )
        micHealth = snapshot
        // A returned floor or an intentional mute ends a wedge episode — clear the
        // latch so a later, unrelated config change can never false-heal off a stale
        // was-live signal (cardinal rule).
        if snapshot.verdict == .live || snapshot.verdict == .quietLive || snapshot.verdict == .muted {
            micWasLiveBeforeWedge = false
        }
    }

    // MARK: - Event-driven re-validation + self-heal (REQ-3, REQ-5)

    /// Armed when MicrophoneCapture reports a configuration-change restart. Gives
    /// the re-pinned device a short window (`configRevalidateWindow`) to show a
    /// live floor; if it stays wedged on a flat/dead stream — and is NOT muted —
    /// trigger a bounded in-place self-heal. Muted, quiet, or recovered streams
    /// cancel the clock and do nothing.
    private func armConfigChangeRevalidation() {
        guard isCapturing, !isStoppingCapture else { return }
        guard micSource == .engine else { return }   // SCK path heals via its own retry
        logToFile("Audio: config change — arming \(Int(configRevalidateWindow))s liveness re-validation (REQ-3)")
        // LATCH (not snapshot) whether the mic was live just before this reconfig, and
        // persist it across re-arms within one wedge episode: the 2026-06-17 incident
        // reconfigured the shared mic REPEATEDLY, and re-reading was-live from the
        // now-silent verdict on a second event would lose the signal and miss the heal.
        // Set true only while a floor is present; the in-window polls and
        // updateMicHealth clear it the moment a floor returns or the device is muted
        // (cardinal rule: never heal a quiet/muted user). `micHealth` here is the last
        // 1 Hz tick, computed before this config-change event fired.
        if micHealth.verdict == .live || micHealth.verdict == .quietLive {
            micWasLiveBeforeWedge = true
        }
        configRevalidateDeadlineTask?.cancel()
        configRevalidateDeadlineTask = Task { [weak self] in
            guard let self else { return }
            // Sample the floor a few times across the window. A returning floor or an
            // intentional mute clears the clock with no heal; device-level failure heals
            // immediately; a PERSISTENT flat-zero (.silentOK) is the ambiguous case,
            // decided at the end of the window using `micWasLiveBeforeWedge`.
            let pollOffsets: [TimeInterval] = [3, 6, 9, 12]
            var elapsed: TimeInterval = 0
            for offset in pollOffsets {
                if offset > elapsed {
                    try? await Task.sleep(nanoseconds: UInt64((offset - elapsed) * 1_000_000_000))
                    elapsed = offset
                }
                guard !Task.isCancelled, self.isCapturing, !self.isStoppingCapture,
                      !self.isMicRecovering, !self.isSelfHealing else { return }
                self.updateMicHealth()
                let v = self.micHealth.verdict
                // Floor returned — recovered, no heal. Clear the wedge latch.
                if v == .live || v == .quietLive { self.micWasLiveBeforeWedge = false; return }
                // Intentional mute — healthy; resumes on unmute. No heal. Clear the latch.
                if v == .muted {
                    self.micWasLiveBeforeWedge = false
                    self.logToFile("Audio: config-change re-validation — device is MUTED, healthy; no heal")
                    return
                }
                // Device-level failure / wrong device — heal immediately (REQ-5).
                if v == .dead || v == .deviceMismatch {
                    self.logToFile("Audio: config-change re-validation — verdict \(v) after \(Int(elapsed))s; self-healing input")
                    await self.selfHealInput()
                    return
                }
                // .silentOK = flat-zero on a correct, running, NOT-muted device. In
                // steady state that is a quiet user, but inside a config-change window
                // it is the silent-wedge signature. Keep watching; decide below.
            }
            // Window elapsed still flat-zero (not muted, correct device, engine still
            // reports "running"). This is the documented incident: the meeting app
            // reconfigured the shared mic and our stream went dead-silent though the
            // engine claims running — NOT `.dead` (the cardinal rule keeps that gate
            // conservative), so a verdict-gated heal could never fire for it. Heal ONLY
            // if the mic was live before the reconfig; a was-already-quiet user is left
            // untouched (cardinal rule).
            guard !Task.isCancelled, self.isCapturing, !self.isStoppingCapture,
                  !self.isMicRecovering, !self.isSelfHealing else { return }
            let endVerdict = self.micHealth.verdict
            if MicLivenessClassifier.shouldHealSilentWedge(endVerdict: endVerdict, wasLiveBeforeChange: self.micWasLiveBeforeWedge) {
                self.logToFile("Audio: config-change re-validation — SILENT WEDGE: mic was live, went flat-zero after reconfig and stayed silent \(Int(self.configRevalidateWindow))s while not muted and still 'running'; self-healing input (REQ-5)")
                await self.selfHealInput()
            } else if endVerdict == .silentOK {
                self.logToFile("Audio: config-change re-validation — flat-zero across window but mic was already quiet at arm; treating as a quiet user, no heal (cardinal rule)")
            }
        }
    }

    /// Bounded in-place input rebuild (REQ-5): tear down + rebuild the
    /// AVAudioEngine input on the SAME intended device with a fresh format
    /// negotiation, keeping the SAME recording session/file (no split). Backoff
    /// between attempts; after `maxSelfHealAttempts` give up to a surfaced
    /// failure. Never runs while muted, recovering, or stopping.
    private func selfHealInput() async {
        // `isMicLifecycleBusy` is the cross-coordinator half of the guard: without it
        // a heal could start while `switchMicrophone` was mid stop→start.
        guard isCapturing, !isStoppingCapture, !isMicRecovering, !isSelfHealing,
              !isMicLifecycleBusy else { return }
        guard micSource == .engine else { return }
        guard selfHealAttempts < maxSelfHealAttempts else {
            if !selfHealWarned {
                selfHealWarned = true
                logToFile("Audio: self-heal exhausted (\(maxSelfHealAttempts) attempts) — surfacing failure; recording continues with available audio")
                onMicProblemDetected?(
                    "Your microphone stopped capturing and couldn't be recovered automatically. "
                    + "The call audio is still being recorded — pick your microphone again in System Settings > Sound > Input to restore your voice."
                )
            }
            return
        }

        isSelfHealing = true
        isMicLifecycleBusy = true
        onMicRecoveryStateChanged?(true)   // reuse the "reconnecting mic" banner
        defer {
            isSelfHealing = false
            isMicLifecycleBusy = false
            onMicRecoveryStateChanged?(false)
            drainPendingSwitch()
        }

        selfHealAttempts += 1
        let attempt = selfHealAttempts
        // Exponential-ish backoff lets coreaudiod finish whatever reconfiguration
        // wedged us before we rebuild.
        let backoffNs: UInt64 = UInt64(attempt) * 400_000_000
        try? await Task.sleep(nanoseconds: backoffNs)
        guard isCapturing, !isStoppingCapture, !isMicRecovering else { return }

        logToFile("Audio: self-heal attempt \(attempt)/\(maxSelfHealAttempts) — rebuilding mic input in place")
        let rebuildTask = Task.detached(priority: .userInitiated) { [micCapture] in
            micCapture.rebuildInputInPlace()?.localizedDescription
        }
        activeMicRebuildTask = rebuildTask
        let failure: String? = await rebuildTask.value
        activeMicRebuildTask = nil
        guard isCapturing, !isStoppingCapture else { return }

        if let failure {
            logToFile("Audio: self-heal attempt \(attempt) FAILED: \(failure)")
            // No external event is guaranteed after a clean wedge, so drive the
            // next attempt on our own clock (REQ-5) instead of stalling at 1 of N.
            scheduleSelfHealRetry()
            return
        }
        // Verify the rebuilt input actually carries a floor before declaring success.
        try? await Task.sleep(nanoseconds: 700_000_000)
        guard isCapturing, !isStoppingCapture else { return }
        updateMicHealth()
        if micHealth.verdict.isHealthy {
            selfHealAttempts = 0
            selfHealWarned = false
            consecutiveMicDeadSeconds = 0
            micWasLiveBeforeWedge = false   // episode resolved
            selfHealRetryTask?.cancel()
            selfHealRetryTask = nil
            logToFile("Audio: self-heal SUCCEEDED on attempt \(attempt) — mic floor restored on \(micCapture.currentDeviceName), recording continues as one session")
        } else {
            logToFile("Audio: self-heal attempt \(attempt) rebuilt the engine but the stream is still \(micHealth.verdict) — scheduling next attempt")
            scheduleSelfHealRetry()
        }
    }

    /// Drive the next self-heal attempt on an internal clock (REQ-5). A clean wedge
    /// (the input stays flat with no further CoreAudio config/device events) would
    /// otherwise leave the remaining attempts unused; this re-fires `selfHealInput`
    /// after a short delay so the bounded ladder actually runs to its budget. The
    /// attempt cap + the muted/healthy guards inside `selfHealInput` still bound it,
    /// and `scheduleSelfHealRetry` is a no-op once the budget is spent (the next
    /// `selfHealInput` surfaces the failure). Cancelled on stop and on success.
    private func scheduleSelfHealRetry() {
        guard isCapturing, !isStoppingCapture, micSource == .engine else { return }
        guard selfHealAttempts < maxSelfHealAttempts else { return }
        selfHealRetryTask?.cancel()
        selfHealRetryTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(self.selfHealRetryDelay * 1_000_000_000))
            guard !Task.isCancelled, self.isCapturing, !self.isStoppingCapture,
                  !self.isMicRecovering, !self.isSelfHealing else { return }
            // Re-validate before re-healing: a floor may have returned on its own,
            // or the device may now be muted — both cancel the ladder (cardinal
            // rule: never re-acquire a healthy/muted mic).
            self.updateMicHealth()
            guard !self.micHealth.verdict.isHealthy else {
                self.logToFile("Audio: self-heal retry — mic recovered to \(self.micHealth.verdict); no further heal")
                return
            }
            await self.selfHealInput()
        }
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

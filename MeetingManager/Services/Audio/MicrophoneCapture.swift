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

// MARK: - Mic liveness & health (TASK-095)

/// What a short window of mic samples proves about the *capture path* —
/// independent of whether the user is talking. The discriminator is the noise
/// floor, NOT the speech level: a working mic always carries a tiny noise floor
/// even in silence, while a wedged/output-only/disconnected input reads bit-exact
/// zero or a frozen constant.
enum MicLiveness: Equatable {
    /// Noise floor present above ε — the capture path is unambiguously alive.
    case live
    /// A tiny but non-zero floor (below the comfortable `live` ε but above the
    /// denormal/zero band). Still proof the path is alive, just very quiet.
    case quietLive
    /// Bit-exact `0.0` or a frozen constant across the whole window. INCONCLUSIVE
    /// on its own: it can mean muted, genuinely-digital-silence, or dead. Must be
    /// disambiguated by mute-state + device health before any "dead" verdict.
    case flatZero
}

/// The combined, signal-independent verdict for the recording-bar status and the
/// self-heal decision. Only `.dead` drives a self-heal — and reaching `.dead`
/// requires device-level failure evidence, never a `flatZero` reading by itself.
enum MicHealthVerdict: Equatable {
    /// Floor present — recording the intended device, live.
    case live
    /// Floor present but very quiet — still live.
    case quietLive
    /// `flatZero` on a correct, alive, running device that is muted. Healthy:
    /// no warning, no self-heal, resumes automatically on unmute.
    case muted
    /// `flatZero` on a correct, alive, running device that is NOT muted. The user
    /// is in genuine digital silence (or listening). Healthy: never "dead".
    case silentOK
    /// The engine's bound device is not the intended device. Surfaced so the user
    /// can switch; does NOT auto-switch to a different device (out of scope).
    case deviceMismatch
    /// Device-level failure (wrong/absent device, format mismatch, IO not
    /// advancing) with no floor. The ONLY verdict that drives self-heal.
    case dead

    /// True when the capture path is healthy — recording the right device with a
    /// floor, or correctly muted/silent on it. Used to suppress false warnings.
    var isHealthy: Bool {
        switch self {
        case .live, .quietLive, .muted, .silentOK: return true
        case .deviceMismatch, .dead: return false
        }
    }
}

/// Snapshot of mic health used by the status surface (REQ-6) and the verdict.
/// A value type of trivially-sendable fields; produced on the audio/lifecycle
/// path and consumed on `@MainActor` (AudioCaptureService → AppState → the pill).
struct MicHealthSnapshot: Equatable {
    var deviceUID: String?
    var deviceName: String
    var isIntendedDevice: Bool
    var isMuted: Bool
    var liveness: MicLiveness
    var verdict: MicHealthVerdict

    static let unknown = MicHealthSnapshot(
        deviceUID: nil, deviceName: "", isIntendedDevice: true,
        isMuted: false, liveness: .flatZero, verdict: .silentOK
    )
}

/// Lock-guarded snapshot of the AVAudioEngine's run/format state for cross-actor
/// health readers (D2). Trivially `Sendable` — two `Bool`s, copied out under `lock`
/// so the caller never touches the `engine` reference, which is reassigned on the
/// config-change thread.
struct EngineLiveness: Sendable {
    var isRunning: Bool
    var isFormatUsable: Bool
}

/// Pure liveness + verdict math. Extracted so it is unit-testable without any
/// CoreAudio hardware (REQ-1, REQ-4, REQ-7). All thresholds are justified
/// against the 2026-06-17 incident floor data.
enum MicLivenessClassifier {
    /// Comfortable "alive" floor. The incident's quiet-but-alive mic read
    /// `0.0001–0.0007`; a real noise floor sits at/above this. RMS ≥ this is
    /// unambiguously `live`.
    static let liveEpsilon: Float = 1e-4
    /// Denormal / gated-zero guard. Anything at or below this is treated as the
    /// zero band — a working mic never floats this low, and FTZ/denormal flushing
    /// can leave sub-`1e-7` trash that must not read as a floor. The dead case in
    /// the incident was bit-exact `0.0000`.
    static let zeroFloor: Float = 1e-7

    /// Classify a window by its RMS and whether every sample is the SAME constant
    /// (a frozen IO buffer reads a flat non-zero constant; a dead buffer reads
    /// flat zero — both are `flatZero` because neither carries a moving floor).
    ///
    /// - `rms`: RMS of the window (already clamped to [0, 1] by the caller).
    /// - `isConstant`: true when max-min across the window is within the zero band
    ///   (no variation — a frozen or bit-exact-zero stream).
    static func classify(rms: Float, isConstant: Bool) -> MicLiveness {
        // A frozen constant (including bit-exact zero) carries no moving floor,
        // regardless of its DC level — inconclusive on its own.
        if isConstant { return .flatZero }
        if rms <= zeroFloor { return .flatZero }
        if rms >= liveEpsilon { return .live }
        return .quietLive
    }

    /// Decide whether a window of per-tick RMS magnitudes is "frozen/constant" for
    /// the steady-state live monitor (D1). A live mic's floor flickers tick-to-tick,
    /// so a window whose max−min stays within the zero band carries no moving floor —
    /// this catches a frozen NON-zero DC stream (identical RMS every second), not just
    /// a bit-exact-zero one. Requires a full window (`minSamples`); with fewer samples
    /// it can't tell "frozen" from "just started", so it falls back to the level-only
    /// zero check (a single tiny sample is not yet proof of a frozen stream).
    ///
    /// A genuine quiet floor moves orders of magnitude more than `zeroFloor`
    /// tick-to-tick (the incident floor swung 1e-4…7e-4, ~1e3× the guard), so this
    /// never demotes a working-but-quiet mic — and even a misfire reads `.silentOK`
    /// (healthy) without device-level failure, so it can never drop or switch a mic.
    static func windowIsConstant(_ window: [Float], minSamples: Int) -> Bool {
        guard let peak = window.max(), let low = window.min() else { return true }
        if window.count >= minSamples {
            return (peak - low) <= zeroFloor
        }
        return peak <= zeroFloor
    }

    /// Reduce the cycler probe accumulators (REQ-4) into a liveness verdict. Pure
    /// so the acquisition gate is unit-testable without CoreAudio — the live wiring
    /// once silently regressed (probe buffers were gated behind the engine's own
    /// `isRunning` flag, so `bufferCount` stayed 0 and a live mic read `.flatZero`
    /// and was rejected). This locks the reduction: NO buffers means no proof of a
    /// floor → `.flatZero`; buffers that carried real variation above the zero band
    /// reduce to `.live`/`.quietLive` (a working mic is never rejected at the gate).
    static func probeVerdict(bufferCount: Int, peakRMS: Float, sawVariation: Bool) -> MicLiveness {
        guard bufferCount > 0 else { return .flatZero }
        // `isConstant` is the inverse of "saw variation": a window with no variation
        // across its whole length is frozen/bit-exact regardless of its peak level.
        return classify(rms: peakRMS, isConstant: !sawVariation)
    }

    /// Combine liveness with device identity, mute-state, and device-level failure
    /// evidence into the final verdict. The reconciliation the spec mandates:
    ///   • floor present (`live`/`quietLive`) → always healthy (path is alive).
    ///   • `flatZero` + muted → `.muted` (never dead, never self-heal).
    ///   • `flatZero` + correct/alive device + not muted → `.silentOK`.
    ///   • wrong/absent device → `.deviceMismatch`.
    ///   • `flatZero` + device-level failure (and NOT muted) → `.dead`.
    ///
    /// `deviceLevelFailure` is the hard evidence gate: wrong/absent device, format
    /// mismatch, or IO not advancing. A `flatZero` reading alone NEVER yields
    /// `.dead`, and muting always wins over any failure signal.
    static func verdict(
        liveness: MicLiveness,
        isIntendedDevice: Bool,
        isMuted: Bool,
        deviceLevelFailure: Bool
    ) -> MicHealthVerdict {
        // Muted is a first-class healthy state and wins over everything except a
        // present floor (a muted device producing a floor is just "live").
        switch liveness {
        case .live: return .live
        case .quietLive: return .quietLive
        case .flatZero:
            if isMuted { return .muted }
            if !isIntendedDevice { return .deviceMismatch }
            if deviceLevelFailure { return .dead }
            return .silentOK
        }
    }

    /// After a config-change re-validation window ends on a persistent `.silentOK`
    /// (flat-zero on a correct, "running", NOT-muted device), decide whether it is a
    /// SILENT WEDGE that warrants a self-heal versus a genuinely quiet user. The
    /// discriminator is whether the mic was live immediately BEFORE the
    /// reconfiguration: a was-live → flat-zero transition is the wedge (the
    /// 2026-06-17 incident, where the engine still reports running so the verdict is
    /// never `.dead`); a was-already-quiet stream is just a quiet user and must NOT
    /// be healed (cardinal rule). Only `.silentOK` is ambiguous — every other end
    /// verdict (live/quietLive/muted/dead/deviceMismatch) is resolved during the
    /// window itself.
    static func shouldHealSilentWedge(endVerdict: MicHealthVerdict, wasLiveBeforeChange: Bool) -> Bool {
        endVerdict == .silentOK && wasLiveBeforeChange
    }
}

/// 2nd-order (RBJ) low-pass applied BEFORE linear-interpolation decimation.
/// Without it, content above the 16 kHz target's 8 kHz Nyquist aliases into
/// the speech band and degrades the transcription input. Stateful IIR —
/// state carries across buffers and resets when the hardware rate changes.
struct BiquadLowPass {
    private var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
    private var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0
    private(set) var configuredRate: Double = 0

    mutating func configure(sampleRate: Double, cutoff: Double = 7000, q: Double = 0.7071) {
        configuredRate = sampleRate
        x1 = 0; x2 = 0; y1 = 0; y2 = 0
        let w0 = 2 * Double.pi * cutoff / sampleRate
        let alpha = sin(w0) / (2 * q)
        let cosw0 = cos(w0)
        let a0 = 1 + alpha
        b0 = Float(((1 - cosw0) / 2) / a0)
        b1 = Float((1 - cosw0) / a0)
        b2 = Float(((1 - cosw0) / 2) / a0)
        a1 = Float((-2 * cosw0) / a0)
        a2 = Float((1 - alpha) / a0)
    }

    mutating func process(_ samples: inout [Float]) {
        for i in 0..<samples.count {
            let x0 = samples[i]
            let y0 = b0 * x0 + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x0
            y2 = y1; y1 = y0
            samples[i] = y0
        }
    }
}

/// Captures microphone input using AVAudioEngine.
///
/// Feeds raw hardware-format audio to onRawBuffer (for SFSpeechRecognizer),
/// and manually downsampled 16kHz mono Float32 to onBuffer (for WhisperKit + WAV recording).
///
/// Uses simple linear interpolation for downsampling instead of AVAudioConverter,
/// which produces near-silent output in real-time streaming scenarios. A
/// stateful biquad low-pass runs before decimation so the interpolation
/// doesn't alias high-frequency content into the speech band.
///
/// `@unchecked Sendable`: every mutable field is either confined to the serialized
/// start/stop/switch lifecycle or guarded by `lock` (`isRunning`, `rawBufferCount`,
/// `activeDeviceID` via `currentDeviceID`). The `engine` reference is reassigned in
/// `stop`, `startByCyclingDevices`, `syncEngineFormatToDevice`, and the config-change
/// handler. The config handler runs on the notification-posting thread and reassigns
/// `engine` while holding `lock` (it can race a cross-actor reader); the start/switch
/// reassignments run before `isRunning` flips true, so no health reader observes them
/// on a live session. Cross-actor readers therefore go through `engineLiveness`,
/// which snapshots the engine reference + its run/format state under `lock` — never
/// touching `engine` unsynchronized.
final class MicrophoneCapture: @unchecked Sendable {
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
    /// Anti-alias low-pass for the downsampler. Touched only on the engine's
    /// tap callback queue (single thread per session); self-reconfigures when
    /// the hardware rate changes.
    private var antiAliasFilter = BiquadLowPass()
    /// Wall-clock time the last `stop()` returned. Used to throttle the next
    /// `start()` so the CoreAudio HAL has time to release the input device.
    private var lastStopAt: Date?
    private(set) var preferredInputDeviceID: String?
    /// True when `preferredInputDeviceID` is an EXPLICIT user pin (mic override on),
    /// so the cycle tries it FIRST — ahead of the call's in-use mic — and honors it
    /// even if it's the built-in. Set on the main actor before start()/switchDevice()
    /// (same set-before-cycle ordering as `preferredInputDeviceID`); read in the cycle.
    var preferredIsExplicit = false
    /// Diagnostic: callback for logging raw buffer info (set by AudioCaptureService)
    var onDiagnostic: ((String) -> Void)?
    private var rawBufferCount: Int = 0

    /// Lock protecting mutable state (`isRunning`, `rawBufferCount`,
    /// probe stats) accessed from both the main thread and the audio
    /// callback queue.
    private let lock = NSLock()

    /// Cycler-probe accumulators (REQ-4), updated in the tap callback under
    /// `lock`. `probePeakRMS` is the loudest window seen since the last reset;
    /// `probeSawVariation` latches true once any window carries real variation
    /// (max≠min beyond the zero band) — together they distinguish a live floor
    /// from a bit-exact-zero / frozen stream.
    private var probePeakRMS: Float = 0
    private var probeSawVariation = false
    private var probeBufferCount = 0
    /// Cheap gate so probe-stat computation costs nothing during steady-state
    /// recording — only the brief cycler probe window sets it.
    private var isProbing = false

    /// Fired (off any audio thread) after a configuration-change restart so the
    /// owner (AudioCaptureService) can run event-driven liveness re-validation on
    /// a short clock (REQ-3) instead of waiting on the 300 s silence window.
    var onConfigChangeRevalidate: (() -> Void)?

    /// Observer token for audio engine configuration change notifications.
    private var configChangeObserver: NSObjectProtocol?

    /// The actual AudioDeviceID being used (for diagnostics)
    private(set) var activeDeviceID: AudioDeviceID = 0

    /// Lock-guarded snapshot of `activeDeviceID` for callers on other actors
    /// (e.g. `AudioCaptureService.switchMicrophone` doing a no-op identity compare).
    var currentDeviceID: AudioDeviceID { lock.withLock { activeDeviceID } }
    /// The device the engine is ACTUALLY on — after device cycling this can
    /// differ from the device the caller requested, so recovery logs the
    /// truth instead of the target it asked for.
    var currentDeviceName: String { getDeviceName(currentDeviceID) }

    /// The CoreAudio UID of the device the engine is ACTUALLY bound to (REQ-2),
    /// or nil if it can't be resolved. Signal-independent identity — answers
    /// "which mic are we on" with zero audio.
    var currentDeviceUID: String? { deviceUID(currentDeviceID) }

    /// Lock-guarded read of the engine's run state + input-format usability for a
    /// cross-actor health reader (D2). Snapshots `engine.isRunning` and the input
    /// node's output format under `lock`, so the caller (`AudioCaptureService`,
    /// `@MainActor`) never reads the `engine` reference unsynchronized while the
    /// config-change handler reassigns it under the same lock. Pure reads on
    /// AVAudioEngine — they do not start/stop IO — so holding `lock` briefly here
    /// can't deadlock the audio path.
    var engineLiveness: EngineLiveness {
        lock.withLock {
            let running = engine.isRunning
            let fmt = engine.inputNode.outputFormat(forBus: 0)
            return EngineLiveness(
                isRunning: running,
                isFormatUsable: Self.isUsableInputFormat(
                    sampleRate: fmt.sampleRate, channelCount: fmt.channelCount)
            )
        }
    }

    /// Signal-independent mic-health snapshot for the status surface (REQ-6) and
    /// the verdict combiner. Reads the bound device's identity + mute state via
    /// CoreAudio (no audio required) and combines them with the supplied
    /// liveness + device-level-failure evidence. The window's RMS/constant
    /// classification is computed by the caller (it owns the level samples);
    /// this fills in identity + mute and runs the pure verdict math.
    ///
    /// `intendedDeviceUID` is the device the caller meant to be on (the user's
    /// selection and/or the mic the meeting is using); nil means "no opinion",
    /// which is treated as a match so we never false-flag a mismatch we can't
    /// prove. Safe to call from any thread (pure CoreAudio reads + a lock-guarded
    /// id snapshot).
    func healthSnapshot(
        liveness: MicLiveness,
        intendedDeviceUID: String?,
        deviceLevelFailure: Bool
    ) -> MicHealthSnapshot {
        let id = currentDeviceID
        let uid = deviceUID(id)
        let muted = isDeviceMuted(id)
        // Unknown intended device, or an unresolvable bound UID, is treated as a
        // match — identity mismatch must be POSITIVELY proven, never inferred
        // from a missing reading (cardinal rule: don't drop a working device).
        let intended: Bool
        if let want = intendedDeviceUID, let have = uid {
            intended = (want == have)
        } else {
            intended = true
        }
        let verdict = MicLivenessClassifier.verdict(
            liveness: liveness,
            isIntendedDevice: intended,
            isMuted: muted,
            deviceLevelFailure: deviceLevelFailure
        )
        return MicHealthSnapshot(
            deviceUID: uid,
            deviceName: getDeviceName(id),
            isIntendedDevice: intended,
            isMuted: muted,
            liveness: liveness,
            verdict: verdict
        )
    }

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

    /// A device mid-transition (a Bluetooth headset switching A2DP→HFP the
    /// moment input opens) can report a 0 Hz / 0-channel format. Installing a
    /// tap with that format raises an ObjC exception inside AVFoundation — not
    /// a Swift error — which killed the whole start sequence with no log line
    /// and no recovery (TASK-029). Validate first and throw cleanly so the
    /// caller's backoff/recovery machinery stays in charge.
    static func isUsableInputFormat(sampleRate: Double, channelCount: UInt32) -> Bool {
        sampleRate > 0 && channelCount > 0
    }

    private func validateInputFormat(stage: String) throws {
        let f = engine.inputNode.outputFormat(forBus: 0)
        guard Self.isUsableInputFormat(sampleRate: f.sampleRate, channelCount: f.channelCount) else {
            onDiagnostic?("DIAG:mic_engine \(stage): input format not ready (\(f.sampleRate)Hz/\(f.channelCount)ch) — failing fast for retry")
            Logger.audio.error("Mic input format not ready at \(stage): \(f.sampleRate)Hz/\(f.channelCount)ch")
            throw AudioCaptureError.captureSetupFailed(
                "No valid audio input format available yet. Please check System Settings > Sound > Input."
            )
        }
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

        // Acquire the mic by CYCLING through every input device until one
        // actually starts. The old preferred → default → "last resort =
        // default" ladder collapsed to a single device whenever the
        // preferred device WAS the system default (2026-06-15 incident: a
        // Bluetooth IEM was both, so all three rungs retried the same dead
        // input and the working built-in mic was never tried). The cycle
        // always reaches the built-in mic.
        try startByCyclingDevices()

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

        // Teardown stays INSIDE the lock: handleEngineConfigurationChange
        // restarts the engine under this same lock (it runs on the
        // notification-posting thread), so a handler interleaving with
        // stop() can no longer install a tap + start the freshly-recreated
        // engine — which left the mic held open after the meeting ended.
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
        lock.unlock()

        Logger.audio.info("MicrophoneCapture stopped (engine recreated for next session)")
    }

    /// Live mid-recording switch to a different input device WITHOUT tearing down
    /// the recording. Internally: `stop()` (recreates the engine, sets `lastStopAt`)
    /// → `configure(inputDeviceID:)` → `start()`. The WAV file and system-audio tap
    /// live in AudioCaptureService/AudioBufferManager and are untouched; the speech
    /// recognizer is buffer-fed (no engine tap), so the only observable effect is a
    /// sub-second silence gap that AudioBufferManager silence-pads. `start()` updates
    /// `activeDeviceID`, so the config-change re-pin guard follows the NEW device.
    /// May block up to ~0.25s on the HAL-release throttle — callers run it off the
    /// main actor. Returns `start()`'s error on failure, `nil` on success.
    func switchDevice(toUID uid: String) -> Error? {
        stop()
        configure(inputDeviceID: uid)
        do {
            try start()
            return nil
        } catch {
            return error
        }
    }

    /// Self-heal re-acquire (REQ-5): tear down and rebuild the input on the SAME
    /// intended device — the programmatic equivalent of "switch the device away
    /// and back" — to recover a wedged/flat stream after a mid-recording format
    /// reconfiguration, WITHOUT restarting the app or splitting the recording.
    /// The WAV file + system tap live in AudioCaptureService and are untouched;
    /// only the AVAudioEngine input is rebuilt with a fresh format negotiation.
    ///
    /// Unlike `switchDevice`, this preserves the current device target (it does
    /// not change `preferredInputDeviceID`) and re-runs the full cycle so format
    /// renegotiation + the liveness probe both apply. Returns `start()`'s error on
    /// failure, `nil` on success. May block on HAL-release throttling — callers
    /// run it off the main actor. Bounded retries/backoff are the caller's job.
    func rebuildInputInPlace() -> Error? {
        onDiagnostic?("DIAG:mic_heal rebuilding input in place (same device, fresh format)")
        stop()
        do {
            try start()
            onDiagnostic?("DIAG:mic_heal rebuild SUCCEEDED on \(currentDeviceName)")
            return nil
        } catch {
            onDiagnostic?("DIAG:mic_heal rebuild FAILED: \(error.localizedDescription)")
            return error
        }
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

        // Persist the hardware input format so -10868 root-causing is possible
        // from the file log: a 0Hz/0ch format means the input device couldn't be
        // acquired at all (permission/contention), which is a different failure
        // than a valid format being rejected by the engine.
        onDiagnostic?("DIAG:mic_format hw=\(hwRate)Hz/\(hwChannels)ch deviceID=\(activeDeviceID) name=\(getDeviceName(activeDeviceID))")

        guard hwRate > 0 else {
            onDiagnostic?("DIAG:mic_format INVALID (0Hz) — input device not acquirable; engine.start() will fail -10868. No tap installed.")
            return
        }

        Logger.audio.info("Mic: \(hwRate)Hz \(hwChannels)ch → downsampling to 16kHz mono")

        inputNode.installTap(onBus: 0, bufferSize: 8192, format: nil) {
            [weak self] buffer, time in
            guard let self else { return }

            self.lock.lock()
            let running = self.isRunning
            let probing = self.isProbing
            if running { self.rawBufferCount += 1 }
            let currentRawBufferCount = self.rawBufferCount
            self.lock.unlock()

            // Cycler liveness probe (REQ-4): collected independently of
            // `isRunning`. The probe runs DURING startByCyclingDevices, before
            // start() flips `isRunning` true — AVAudioEngine delivers tap buffers
            // the moment engine.start() succeeds, so the probe must read them here
            // or it would always see zero buffers and reject a live mic at
            // acquisition (the cardinal-rule regression). Steady-state recording
            // never sets `isProbing`, so it still pays nothing.
            if probing { self.collectProbeStats(buffer) }

            // Everything below feeds the live recording pipeline and must NOT run
            // until the session is officially running (a cycle-probe buffer is not
            // recording audio).
            guard running else { return }

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

    // MARK: - Cycler liveness probe (REQ-4)

    /// Fold one tap buffer into the probe accumulators under `lock`. Computes the
    /// window's RMS and whether it carries real variation (max−min beyond the
    /// zero band) — a bit-exact-zero or frozen-constant stream carries neither.
    private func collectProbeStats(_ buffer: AVAudioPCMBuffer) {
        guard let fcd = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        let ptr = fcd[0]
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        var minV = ptr[0]
        var maxV = ptr[0]
        for i in 0..<n {
            let s = ptr[i]
            sum += s * s
            if s < minV { minV = s }
            if s > maxV { maxV = s }
        }
        let rms = sqrtf(sum / Float(n))
        let varied = (maxV - minV) > MicLivenessClassifier.zeroFloor
        lock.lock()
        probeBufferCount += 1
        if rms > probePeakRMS { probePeakRMS = rms }
        if varied { probeSawVariation = true }
        lock.unlock()
    }

    /// Sample a short live window and classify it (REQ-4). Used by the cycler to
    /// require a live floor — not mere buffer presence — before declaring SUCCESS.
    /// Blocks ~`window` seconds on the calling (lifecycle) thread, which is the
    /// same thread that already sleeps for HAL settling, so this adds no new
    /// concurrency. Returns `.flatZero` when no buffers arrived at all.
    private func probeLiveness(window: TimeInterval) -> MicLiveness {
        lock.lock()
        probePeakRMS = 0
        probeSawVariation = false
        probeBufferCount = 0
        isProbing = true
        lock.unlock()

        Thread.sleep(forTimeInterval: window)

        lock.lock()
        let peak = probePeakRMS
        let varied = probeSawVariation
        let count = probeBufferCount
        isProbing = false
        lock.unlock()

        return MicLivenessClassifier.probeVerdict(
            bufferCount: count, peakRMS: peak, sawVariation: varied)
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

        // Low-pass below the 16 kHz target's Nyquist before decimating —
        // only when genuinely downsampling. Reconfigure (and reset state)
        // when the hardware rate changes (device switch).
        if hwRate > 16000 {
            if antiAliasFilter.configuredRate != hwRate {
                antiAliasFilter.configure(sampleRate: hwRate)
            }
            antiAliasFilter.process(&monoSamples)
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

    /// The device's ACTUAL nominal sample rate, straight from the HAL.
    /// The engine's inputNode can report a stale or factory-default format
    /// (44100/1ch) after a device swap — comparing against this is what
    /// catches it before start() fails with -10868.
    private func getDeviceNominalSampleRate(_ deviceID: AudioDeviceID) -> Double {
        var rate: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate)
        return rate
    }

    /// Total input channels the HAL reports for the device.
    private func getDeviceInputChannelCount(_ deviceID: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size > 0 else { return 0 }
        let bufferList = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                          alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { bufferList.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, bufferList) == noErr else { return 0 }
        let list = bufferList.assumingMemoryBound(to: AudioBufferList.self)
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        return buffers.reduce(0) { $0 + $1.mNumberChannels }
    }

    /// Does the engine's view of the input agree with the HAL's truth?
    /// Rate must match (the -10868 driver); the AU presenting FEWER
    /// channels than the device is normal (mono view of a stereo device).
    static func engineFormatAgreesWithHAL(auRate: Double, auChannels: UInt32,
                                          halRate: Double, halChannels: UInt32) -> Bool {
        guard auRate > 0, auChannels > 0, halRate > 0, halChannels > 0 else { return false }
        return abs(auRate - halRate) < 1.0 && auChannels <= halChannels
    }

    /// Post-device-swap format sync (the 2026-06-12 -10868 incident): after
    /// kAudioOutputUnitProperty_CurrentDevice changes, the inputNode keeps
    /// its previous (or factory 44.1k/1ch) stream format. Starting the
    /// engine in that state ALWAYS fails -10868, and a tap installed with
    /// `format: nil` inherits the phantom. This loop compares the engine's
    /// view against the HAL's nominal format and rebinds (fresh engine +
    /// re-set device) until they agree or attempts run out.
    private func syncEngineFormatToDevice(stage: String, attempts: Int = 5) throws {
        for attempt in 1...attempts {
            let au = engine.inputNode.inputFormat(forBus: 0)
            let halRate = getDeviceNominalSampleRate(activeDeviceID)
            let halChannels = getDeviceInputChannelCount(activeDeviceID)
            if Self.engineFormatAgreesWithHAL(auRate: au.sampleRate, auChannels: au.channelCount,
                                              halRate: halRate, halChannels: halChannels) {
                if attempt > 1 {
                    onDiagnostic?("DIAG:mic_format \(stage): resync succeeded on attempt \(attempt) (AU=\(au.sampleRate)/\(au.channelCount)ch HAL=\(halRate)/\(halChannels)ch)")
                }
                return
            }
            onDiagnostic?("DIAG:mic_format \(stage): AU=\(au.sampleRate)Hz/\(au.channelCount)ch HAL=\(halRate)Hz/\(halChannels)ch MISMATCH — resync \(attempt)/\(attempts)")
            Logger.audio.warning("Mic format mismatch at \(stage): AU \(au.sampleRate)/\(au.channelCount) vs HAL \(halRate)/\(halChannels) — rebinding")
            guard attempt < attempts else { break }
            // Rebind: a fresh engine re-derives formats when its inputNode
            // is touched AFTER the device assignment; the sleep lets
            // coreaudiod finish whatever reconfiguration raced us.
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            engine = AVAudioEngine()
            Thread.sleep(forTimeInterval: 0.12 * Double(attempt))
            _ = setInputDeviceByID(activeDeviceID)
        }
        throw AudioCaptureError.captureSetupFailed(
            "Microphone format never settled: the audio engine reports a different format than the device. "
            + "Another app may be reconfiguring the microphone — recovery will retry shortly."
        )
    }

    /// Core Audio transport type for a device (USB, Bluetooth, Built-in…).
    private func deviceTransportType(_ deviceID: AudioDeviceID) -> UInt32 {
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transport)
        return transport
    }

    /// Every input-capable device on the system (has ≥1 input channel).
    private func allInputDeviceIDs() -> [AudioDeviceID] {
        var size: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter { getDeviceInputChannelCount($0) > 0 }
    }

    /// The built-in (Apple) microphone. NOT a reliability anchor — when the
    /// laptop lid is closed (clamshell, the user's normal setup) the
    /// built-in mic is disabled or delivers pure silence, so it must be
    /// tried LAST, never ahead of a real external mic.
    private func builtInInputDeviceID() -> AudioDeviceID? {
        allInputDeviceIDs().first { deviceTransportType($0) == kAudioDeviceTransportTypeBuiltIn }
    }

    /// Continuity (iPhone/iPad) capture mics hijack the system default and often
    /// deliver pure silence — and a muted one is wrongly accepted as "healthy" by
    /// the cycler (`cyclerAcceptsCandidate` treats flat-zero+muted as live), so the
    /// auto-cycle must never land on one. Mirrors `AudioSessionManager.isUnreliableInput`
    /// for this CoreAudio path. Transport type is the locale-independent primary
    /// signal; the name match is the fallback. An explicit user override still
    /// routes through `switchDevice()`, not this cycle.
    private func isContinuityInput(_ deviceID: AudioDeviceID) -> Bool {
        let transport = deviceTransportType(deviceID)
        if transport == kAudioDeviceTransportTypeContinuityCaptureWired ||
           transport == kAudioDeviceTransportTypeContinuityCaptureWireless { return true }
        let name = getDeviceName(deviceID).lowercased()
        return name.contains("iphone") || name.contains("ipad")
    }

    /// True when ANOTHER process (the meeting/call app) is actively running
    /// IO on this device — i.e. this is the microphone the meeting is using.
    /// Same property the call detector keys on. Read BEFORE we open
    /// anything, so it reflects other apps, not us.
    private func isDeviceRunningSomewhere(_ deviceID: AudioDeviceID) -> Bool {
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }

    /// Input devices the meeting app currently has open — "the microphone
    /// assigned to the meeting", in enumeration order.
    private func inUseInputDeviceIDs() -> [AudioDeviceID] {
        allInputDeviceIDs().filter { isDeviceRunningSomewhere($0) }
    }

    /// Ordered, deduped device list the cycle will try. An EXPLICIT user pick
    /// (`preferredIsExplicit`, i.e. the mic override is on) is authoritative and
    /// goes FIRST. Otherwise the meeting's in-use mic goes first (capture from the
    /// device the call is using) and the built-in goes LAST (dead in clamshell).
    /// Pure → unit-tested.
    static func orderedCandidates(inUseByOthers: [AudioDeviceID],
                                  preferred: AudioDeviceID?,
                                  preferredIsExplicit: Bool,
                                  systemDefault: AudioDeviceID?,
                                  builtIn: AudioDeviceID?,
                                  all: [AudioDeviceID]) -> [AudioDeviceID] {
        var ordered: [AudioDeviceID] = []
        func add(_ id: AudioDeviceID?, allowBuiltIn: Bool = false) {
            guard let id, id != kAudioObjectUnknown, all.contains(id), !ordered.contains(id) else { return }
            if id == builtIn, !allowBuiltIn { return }   // built-in deferred to the very end
            ordered.append(id)
        }
        // 0. An EXPLICIT pick (override on) wins: tried FIRST — ahead of the call's
        //    in-use mic — and honored even if it's the built-in. A lid-closed built-in
        //    is already filtered out of `all`, so this can't resurrect a dead one.
        if preferredIsExplicit { add(preferred, allowBuiltIn: true) }
        for id in inUseByOthers { add(id) }   // 1. the mic the MEETING is using
        add(preferred)                        // 2. preferred (non-explicit / auto path)
        add(systemDefault)                    // 3. macOS default
        for id in all { add(id) }             // 4. other external inputs
        // 5. built-in LAST — only when no external mic could start, because
        //    lid-closed it captures silence and must not preempt a real mic
        //    (unless an explicit pick already placed it at the front).
        if let builtIn, builtIn != kAudioObjectUnknown, all.contains(builtIn), !ordered.contains(builtIn) {
            ordered.append(builtIn)
        }
        return ordered
    }

    /// The cycler's accept/reject decision for a started candidate (REQ-4). Pure
    /// so the gate is unit-testable. Accept when a floor is present (`live`/
    /// `quietLive`) OR the device is muted (a muted-but-correct mic is healthy and
    /// must never be dropped — cardinal rule). Reject ONLY a `flatZero` probe on a
    /// not-muted device (a silent aggregate/wedged stream — the TASK-034 gap).
    static func cyclerAcceptsCandidate(liveness: MicLiveness, isMuted: Bool) -> Bool {
        switch liveness {
        case .live, .quietLive: return true
        case .flatZero: return isMuted
        }
    }

    /// Try each candidate input device with a fresh engine until one
    /// starts. First success commits `activeDeviceID`; total failure
    /// throws (→ system-only recovery, which re-enters this cycle).
    private func startByCyclingDevices() throws {
        // Exclude devices that can't actually capture from the discovery set. Every
        // candidate position in `orderedCandidates` is gated on `all.contains(id)`, so
        // filtering here keeps them out of EVERY slot (in-use, preferred, system-default,
        // and the general scan) — auto-detection never lands on them:
        //   • Continuity (iPhone/iPad) mics — hijack the default and often deliver silence.
        //   • The built-in mic while the laptop lid is CLOSED (clamshell, the user's normal
        //     setup): macOS leaves it selectable but it's physically off, so a failed
        //     external mic must not fall through to a dead built-in that shows as
        //     "selected" yet records nothing.
        let allRaw = allInputDeviceIDs()
        let lidClosed = AudioSessionManager.lidIsClosed()
        let builtInID = builtInInputDeviceID()
        let all = allRaw.filter { id in
            if isContinuityInput(id) { return false }
            if lidClosed, let builtInID, id == builtInID { return false }
            return true
        }
        let excluded = allRaw.filter { !all.contains($0) }
        if !excluded.isEmpty {
            let reason = lidClosed ? "Continuity + lid-closed built-in" : "Continuity (iPhone/iPad)"
            onDiagnostic?("DIAG:mic_cycle excluding \(reason) mic(s): \(excluded.map { getDeviceName($0) }.joined(separator: ", "))")
        }
        let preferredID = preferredInputDeviceID.map { getDeviceIDForUID($0) }
        let inUse = inUseInputDeviceIDs()
        if !inUse.isEmpty {
            onDiagnostic?("DIAG:mic_cycle meeting is using: \(inUse.map { getDeviceName($0) }.joined(separator: ", "))")
        }
        let candidates = Self.orderedCandidates(
            inUseByOthers: inUse,
            preferred: preferredID,
            preferredIsExplicit: preferredIsExplicit,
            systemDefault: getDefaultInputDeviceID(),
            builtIn: builtInInputDeviceID(),
            all: all)

        guard !candidates.isEmpty else {
            onDiagnostic?("DIAG:mic_cycle no input devices found")
            throw AudioCaptureError.captureSetupFailed(
                "No microphone input devices were found. Check System Settings > Sound > Input.")
        }
        onDiagnostic?("DIAG:mic_cycle \(candidates.count) candidate device(s): \(candidates.map { getDeviceName($0) }.joined(separator: ", "))")

        var lastError: Error?
        for (idx, deviceID) in candidates.enumerated() {
            // Fresh engine per candidate — a failed start leaves the IO
            // unit half-wired, and reusing it re-triggers -10868.
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            engine = AVAudioEngine()
            if idx > 0 { Thread.sleep(forTimeInterval: 0.15) }

            activeDeviceID = deviceID
            let label = "\(getDeviceName(deviceID)) (\(idx + 1)/\(candidates.count))"
            guard setInputDeviceByID(deviceID) else {
                onDiagnostic?("DIAG:mic_cycle SET-DEVICE failed for \(label) — next")
                continue
            }
            do {
                try validateInputFormat(stage: "cycle \(idx + 1)")
                try syncEngineFormatToDevice(stage: "cycle \(idx + 1)")
                installTapOnInputNode()
                try engine.start()

                // REQ-4: require a LIVE floor over a short probe window before
                // accepting this candidate — buffer presence alone is not
                // success. This stops the cycle landing on a silent
                // aggregate/device (the recurring TASK-034 gap, e.g. the
                // incident's CADefaultDeviceAggregate that started fine yet
                // carried bit-exact zero). A `flatZero` probe is only accepted
                // when the device is MUTED — a muted-but-correct mic is healthy
                // and must never be dropped (cardinal rule).
                let liveness = probeLiveness(window: 0.6)
                let muted = isDeviceMuted(deviceID)
                if !Self.cyclerAcceptsCandidate(liveness: liveness, isMuted: muted) {
                    onDiagnostic?("DIAG:mic_cycle \(label) started but probe was FLAT-ZERO (not muted) — silent device, trying next")
                    Logger.audio.warning("Mic cycle \(idx + 1) on '\(self.getDeviceName(deviceID))' started but produced a flat-zero stream — rejecting silent device")
                    continue
                }
                let livenessLabel = muted && liveness == .flatZero ? "muted" : "\(liveness)"
                onDiagnostic?("DIAG:mic_cycle SUCCESS on \(label) (liveness=\(livenessLabel))")
                Logger.audio.info("Mic acquired on '\(self.getDeviceName(deviceID))' (candidate \(idx + 1) of \(candidates.count), liveness=\(livenessLabel))")
                return
            } catch {
                lastError = error
                onDiagnostic?("DIAG:mic_cycle \(label) FAILED: \(error.localizedDescription) — trying next device")
                Logger.audio.error("Mic cycle \(idx + 1) on '\(self.getDeviceName(deviceID))' failed: \(error.localizedDescription)")
            }
        }

        throw AudioCaptureError.captureSetupFailed(
            "Tried \(candidates.count) microphone(s); none could start. "
            + "Last error: \(lastError?.localizedDescription ?? "unknown"). "
            + "If you're on Bluetooth earbuds, the meeting app may be holding the mic.")
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

    /// The CoreAudio UID string for a device id, or nil if it can't be resolved.
    /// Mirrors AudioSessionManager.uid(forDeviceID:) — duplicated here because
    /// MicrophoneCapture owns the bound AudioDeviceID and must answer identity
    /// without reaching across to the session manager on the audio path.
    private func deviceUID(_ deviceID: AudioDeviceID) -> String? {
        guard deviceID != kAudioObjectUnknown, deviceID != 0 else { return nil }
        var cfUID: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &cfUID) == noErr else { return nil }
        return cfUID as String
    }

    /// Is the bound input device muted (REQ-7)? Mute is a first-class HEALTHY
    /// state, so this read must be conservative: report muted only on positive
    /// evidence. Checks, in order, on the input scope:
    ///   • `kAudioDevicePropertyMute` (master element 0, then per-channel 1/2),
    ///   • `kAudioDevicePropertyVolumeScalar == 0` (master, then per-channel).
    /// Any one positive read → muted. Unreadable properties are simply skipped
    /// (a device that doesn't expose mute/volume is reported as not-muted, never
    /// guessed). The macOS *system* mic-mute (the menu-bar / hardware mute) also
    /// drives `kAudioDevicePropertyMute` on the active input device, so this same
    /// read covers it without a private API.
    private func isDeviceMuted(_ deviceID: AudioDeviceID) -> Bool {
        guard deviceID != kAudioObjectUnknown, deviceID != 0 else { return false }

        func uint32Property(_ selector: AudioObjectPropertySelector, element: AudioObjectPropertyElement) -> UInt32? {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: element
            )
            guard AudioObjectHasProperty(deviceID, &address) else { return nil }
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else { return nil }
            return value
        }

        func floatProperty(_ selector: AudioObjectPropertySelector, element: AudioObjectPropertyElement) -> Float? {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: element
            )
            guard AudioObjectHasProperty(deviceID, &address) else { return nil }
            var value: Float = 0
            var size = UInt32(MemoryLayout<Float>.size)
            guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else { return nil }
            return value
        }

        // Master + per-channel mute. Element 0 is master; 1/2 are L/R.
        for element: AudioObjectPropertyElement in [kAudioObjectPropertyElementMain, 1, 2] {
            if let muted = uint32Property(kAudioDevicePropertyMute, element: element), muted != 0 {
                return true
            }
        }
        // Volume scalar pinned to 0 is an effective mute (some devices model the
        // menu-bar mute this way instead of the mute property).
        for element: AudioObjectPropertyElement in [kAudioObjectPropertyElementMain, 1, 2] {
            if let vol = floatProperty(kAudioDevicePropertyVolumeScalar, element: element), vol <= 0 {
                return true
            }
        }
        return false
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
            // The re-check AND the restart run under the same lock stop()
            // tears down under: a bare re-check left a window where stop()
            // completed in between and the restart resurrected the capture
            // (mic indicator on, device held, after the meeting ended).
            onDiagnostic?("DIAG:mic_device config changed but format still valid (\(inputFormat.sampleRate)Hz/\(inputFormat.channelCount)ch), attempting restart")
            lock.lock()
            guard isRunning else {
                lock.unlock()
                onDiagnostic?("DIAG:mic_device config changed after stop — not restarting")
                return
            }
            // Re-pin the device we selected before restarting. A configuration
            // change (a device (dis)connect, a Continuity mic appearing) can
            // silently revert AVAudioEngine's input to the *system default* —
            // which may be a phantom aggregate/Continuity mic that captures pure
            // silence. Re-applying our chosen device + tap keeps capture on the
            // intended mic instead of drifting onto a silent default mid-meeting.
            if activeDeviceID != kAudioObjectUnknown && activeDeviceID != 0 {
                _ = setInputDeviceByID(activeDeviceID)
            }
            // Same AU-vs-HAL agreement gate as start(): a config change is
            // exactly when the engine's cached format goes stale.
            var restartError: Error? = nil
            do {
                try syncEngineFormatToDevice(stage: "configChange")
                installTapOnInputNode()
                try engine.start()
            } catch {
                restartError = error
            }
            lock.unlock()

            if let error = restartError {
                Logger.audio.error("Failed to restart engine after config change: \(error.localizedDescription)")
                onDiagnostic?("DIAG:mic_device engine restart FAILED: \(error.localizedDescription)")
                stop()
                let disconnectError = MicrophoneCaptureError.deviceDisconnected(
                    "Microphone configuration changed and engine could not restart: \(error.localizedDescription)"
                )
                onDeviceDisconnected?(disconnectError)
            } else {
                // The format resync may have rebuilt the engine — re-point
                // the configuration-change observer at the live instance,
                // or the NEXT device change goes unnoticed.
                if let observer = configChangeObserver {
                    NotificationCenter.default.removeObserver(observer)
                }
                configChangeObserver = NotificationCenter.default.addObserver(
                    forName: .AVAudioEngineConfigurationChange,
                    object: engine,
                    queue: nil
                ) { [weak self] _ in
                    self?.handleEngineConfigurationChange()
                }
                onDiagnostic?("DIAG:mic_device engine restarted successfully after config change (device re-pinned to \(getDeviceName(activeDeviceID)))")
                // REQ-3: a config change is exactly when capture can silently
                // wedge on a flat stream. Kick event-driven liveness
                // re-validation now (≤ ~15 s clock in the owner) instead of
                // waiting on the 300 s silence window. Fired off-lock so the
                // owner's async work never reenters this lock.
                onConfigChangeRevalidate?()
            }
        }
    }
}

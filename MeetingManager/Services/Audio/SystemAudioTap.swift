import AVFoundation
import ScreenCaptureKit
import os

/// Captures system audio output using ScreenCaptureKit (macOS 13+)
///
/// This captures audio from all apps (Zoom, Teams, browser calls, etc.)
/// to record what remote meeting participants say.
///
/// Requires Screen Recording permission in System Settings > Privacy & Security.
/// Even for audio-only capture, ScreenCaptureKit requires this permission.
@available(macOS 14.2, *)
final class SystemAudioTap: NSObject, SCStreamDelegate, SCStreamOutput {
    /// All four callback vars are assigned on the main actor and invoked on SCK's
    /// delivery queues, so they are `lock`-guarded: a plain `var` lets ARC race the
    /// reader's retain of the closure box against `= nil`'s release. The delivery
    /// path snapshots the sink it needs inside the same locked block that reads
    /// `isRunning`, and invokes it outside the lock.
    var onBuffer: ((AVAudioPCMBuffer, AVAudioTime) -> Void)? {
        get { lock.withLock { _onBuffer } }
        set { lock.withLock { _onBuffer = newValue } }
    }
    private var _onBuffer: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?

    /// Microphone buffers, when this stream is started with `captureMicrophone:`.
    /// Used as the resilient mic path when AVAudioEngine can't acquire the input
    /// device (e.g. -10868 because the conferencing app holds the mic). SCK taps
    /// the mic at the system level, so it COEXISTS with Zoom/Meet/Teams.
    var onMicBuffer: ((AVAudioPCMBuffer, AVAudioTime) -> Void)? {
        get { lock.withLock { _onMicBuffer } }
        set { lock.withLock { _onMicBuffer = newValue } }
    }
    private var _onMicBuffer: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?

    /// Diagnostic callback for logging (set by AudioCaptureService)
    var onDiagnostic: ((String) -> Void)? {
        get { lock.withLock { _onDiagnostic } }
        set { lock.withLock { _onDiagnostic = newValue } }
    }
    private var _onDiagnostic: ((String) -> Void)?

    /// Fired when the SCStream dies mid-capture (permission revoked, display
    /// change, sleep/wake). Without this the owner never learns the remote
    /// audio went silent: levels freeze at their last value — which can hold
    /// the dual-silence auto-stop hostage forever — and the user records
    /// mic-only with no warning. Invoked on the SCK delegate queue.
    var onStreamStopped: ((Error) -> Void)? {
        get { lock.withLock { _onStreamStopped } }
        set { lock.withLock { _onStreamStopped = newValue } }
    }
    private var _onStreamStopped: ((Error) -> Void)?

    private var stream: SCStream?
    private var isRunning = false
    private var bufferCount: Int = 0
    /// Count of microphone sample buffers delivered (to confirm the SCK mic path
    /// is actually producing audio, not just that the stream started).
    private(set) var micBufferCount: Int = 0

    /// Loudest mic buffer seen since start. Buffer COUNT alone validated a
    /// dead mic: SCK can deliver perfectly-formed frames of pure silence
    /// (rms 0.000000 from frame #1 — the 2026-06-11 notification-start
    /// incident), so the fallback probe must check signal, not presence
    /// (TASK-034). Reset on every start.
    private(set) var micPeakRMS: Float = 0

    /// Lock protecting `isRunning`, `stream`, `bufferCount`, and the callback
    /// closures against races between the SCK delivery queues and callers of
    /// start/stop. Critical sections must stay short — the per-buffer delivery
    /// path takes it.
    private let lock = NSLock()

    /// Start capturing system audio via ScreenCaptureKit.
    /// This captures all system audio output except our own app's audio.
    /// - Parameters:
    ///   - captureMicrophone: also capture the microphone through this SCStream
    ///     (macOS 15+). The resilient mic path when AVAudioEngine is contended.
    ///   - micDeviceUID: preferred microphone device UID (nil = system default).
    func start(processID: pid_t? = nil, captureMicrophone: Bool = false, micDeviceUID: String? = nil) async throws {
        lock.lock()
        guard !isRunning else { lock.unlock(); return }
        micBufferCount = 0
        micPeakRMS = 0
        lock.unlock()

        // Get available content for filtering
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            onDiagnostic?("DIAG:sys_tap ERROR getting shareable content: \(error.localizedDescription)")
            throw AudioCaptureError.captureSetupFailed("ScreenCaptureKit content unavailable: \(error.localizedDescription)")
        }

        guard let display = content.displays.first else {
            throw AudioCaptureError.captureSetupFailed("No display found for ScreenCaptureKit")
        }

        onDiagnostic?("DIAG:sys_tap found \(content.displays.count) displays, \(content.applications.count) apps")

        // Exclude our own app from capture to prevent feedback
        let ownBundleID = Bundle.main.bundleIdentifier ?? "com.meetingmanager.app"
        let excludedApps = content.applications.filter { $0.bundleIdentifier == ownBundleID }
        onDiagnostic?("DIAG:sys_tap excluding \(excludedApps.count) own app instances (bundle: \(ownBundleID))")

        // Create filter: capture full display audio, excluding our app
        let filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])

        // Configure for audio-only capture
        let config = SCStreamConfiguration()
        // Minimal video config (SCStream requires video, but we'll ignore it)
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1) // 1 fps minimum
        // Audio config
        config.capturesAudio = true
        config.sampleRate = 48000       // Capture at native rate
        config.channelCount = 2         // Stereo system audio
        config.excludesCurrentProcessAudio = true  // Don't capture our own audio

        // Microphone capture through ScreenCaptureKit (macOS 15+). SCK taps the
        // mic at the system level, so unlike AVAudioEngine it coexists with the
        // conferencing app that's holding the device — this is the fix for the
        // recurring -10868 during calls.
        var micRequested = false
        if captureMicrophone {
            if #available(macOS 15.0, *) {
                config.captureMicrophone = true
                if let uid = micDeviceUID { config.microphoneCaptureDeviceID = uid }
                micRequested = true
                onDiagnostic?("DIAG:sys_tap captureMicrophone=true (SCK mic path) device=\(micDeviceUID ?? "system default")")
            } else {
                onDiagnostic?("DIAG:sys_tap captureMicrophone requested but needs macOS 15+")
            }
        }

        onDiagnostic?("DIAG:sys_tap configuring SCStream: audio=48kHz/2ch, mic=\(micRequested), excludeSelf=true")

        // Create stream
        let stream = SCStream(filter: filter, configuration: config, delegate: self)

        // Add audio output handler
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "com.meetingmanager.systemaudio", qos: .userInteractive))

        // Add microphone output handler (macOS 15+).
        if micRequested, #available(macOS 15.0, *) {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: DispatchQueue(label: "com.meetingmanager.scmic", qos: .userInteractive))
        }

        // Start capture
        do {
            try await stream.startCapture()
            lock.lock()
            self.stream = stream
            self.isRunning = true
            self.bufferCount = 0
            lock.unlock()
            onDiagnostic?("DIAG:sys_tap SCStream started successfully")
        } catch {
            onDiagnostic?("DIAG:sys_tap SCStream start FAILED: \(error.localizedDescription)")
            throw AudioCaptureError.captureSetupFailed("SCStream start failed: \(error.localizedDescription). Check Screen Recording permission.")
        }
    }

    /// Stop system audio capture
    func stop() {
        lock.lock()
        guard isRunning else { lock.unlock(); return }
        isRunning = false
        let capturedStream = stream
        stream = nil
        lock.unlock()

        Task {
            try? await capturedStream?.stopCapture()
        }
    }

    deinit {
        stop()
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // Process system-audio AND microphone buffers (mic only when started with
        // captureMicrophone: on macOS 15+).
        let isMic: Bool
        if #available(macOS 15.0, *) { isMic = (type == .microphone) } else { isMic = false }
        guard type == .audio || isMic else { return }
        guard sampleBuffer.isValid else { return }
        let tag = isMic ? "sc_mic" : "sys_sckit"

        lock.lock()
        guard isRunning else { lock.unlock(); return }
        let currentBufferCount: Int
        if isMic { micBufferCount += 1; currentBufferCount = micBufferCount }
        else { bufferCount += 1; currentBufferCount = bufferCount }
        // Snapshot the sinks under the same lock the main actor rewrites them under
        // and invoke them below OFF the lock. The `isRunning` check above is not
        // enough on its own: the owner can nil a callback in the window between it
        // and the invocation.
        let diagnostic = _onDiagnostic
        let sink = isMic ? _onMicBuffer : _onBuffer
        lock.unlock()

        // Extract audio data from CMSampleBuffer
        guard let formatDesc = sampleBuffer.formatDescription else {
            if currentBufferCount <= 3 {
                diagnostic?("DIAG:sys_sckit #\(currentBufferCount) no format description")
            }
            return
        }

        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee
        let sampleRate = asbd?.mSampleRate ?? 48000
        let channels = asbd?.mChannelsPerFrame ?? 2

        // CoreMedia can hand back a zeroed ASBD during stream reconfiguration.
        // Guard before any division: `totalFloats / channels` would trap on an
        // integer divide-by-zero, and `Int(frameCount * (16000/sampleRate))`
        // would trap converting Inf/NaN to Int.
        guard sampleRate > 0, channels > 0 else { return }

        // Wrap the native-format samples in an AVAudioPCMBuffer and deliver
        // them AS-IS. AudioBufferManager.canonicalize converts to 16 kHz mono
        // with a STATEFUL AVAudioConverter — properly anti-aliased resampling
        // with phase continuity across buffers — which is strictly better
        // than the hand-rolled linear-interpolation downsample this replaced
        // (that aliased >8 kHz content straight into the speech band).
        let nativeFormat = AVAudioFormat(cmAudioFormatDescription: formatDesc)
        let frames = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frames > 0,
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: nativeFormat, frameCapacity: frames) else { return }
        pcmBuffer.frameLength = frames
        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: pcmBuffer.mutableAudioBufferList
        )
        guard copyStatus == noErr else {
            if currentBufferCount <= 3 {
                diagnostic?("DIAG:\(tag) #\(currentBufferCount) PCM copy failed: \(copyStatus)")
            }
            return
        }

        // Diagnostic: log periodically
        if currentBufferCount <= 3 || currentBufferCount % 200 == 0 {
            diagnostic?("DIAG:\(tag) #\(currentBufferCount) frames=\(frames) rate=\(sampleRate) ch=\(channels) rms=\(String(format: "%.6f", pcmBuffer.rmsLevel))")
        }

        // Timestamp = the buffer's PRESENTATION time, not receipt time. The
        // positioned file writer aligns the mixed/system tracks from these
        // timestamps, and receipt-time jitter (queue scheduling) skewed the
        // alignment the diarization energy anchor depends on.
        let pts = sampleBuffer.presentationTimeStamp
        let hostTime = pts.isValid ? CMClockConvertHostTimeToSystemUnits(pts) : mach_absolute_time()
        let time = AVAudioTime(hostTime: hostTime)
        if isMic {
            let rms = pcmBuffer.rmsLevel
            lock.lock()
            if rms > micPeakRMS { micPeakRMS = rms }
            lock.unlock()
        }
        sink?(pcmBuffer, time)
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onDiagnostic?("DIAG:sys_tap SCStream stopped with error: \(error.localizedDescription)")
        Logger.audio.error("System audio stream stopped: \(error.localizedDescription)")
        lock.lock()
        isRunning = false
        let stopped = _onStreamStopped
        lock.unlock()
        stopped?(error)
    }
}

import AVFoundation
import Dispatch
import Foundation

// MARK: - CircularBuffer

/// A fixed-capacity ring buffer for Float samples.
/// Uses contiguous storage for efficient bulk reads.
struct CircularBuffer<Element> {
    private var storage: [Element]
    private var head: Int = 0  // next write position
    private var _count: Int = 0
    let capacity: Int

    init(capacity: Int, defaultValue: Element) {
        self.capacity = capacity
        self.storage = [Element](repeating: defaultValue, count: capacity)
    }

    var count: Int { _count }

    mutating func append(contentsOf elements: some Collection<Element>) {
        for element in elements {
            storage[head] = element
            head = (head + 1) % capacity
            if _count < capacity {
                _count += 1
            }
        }
    }

    /// Read the first `n` elements (oldest) into a contiguous array.
    func prefix(_ n: Int) -> [Element] {
        let n = min(n, _count)
        guard n > 0 else { return [] }
        let start = (head - _count + capacity) % capacity
        var result = [Element]()
        result.reserveCapacity(n)
        for i in 0..<n {
            result.append(storage[(start + i) % capacity])
        }
        return result
    }

    /// Drop the oldest `n` elements.
    mutating func removeFirst(_ n: Int) {
        let n = min(n, _count)
        _count -= n
    }

    mutating func removeAll() {
        _count = 0
        head = 0
    }

    /// Read element at logical index (0 = oldest).
    subscript(index: Int) -> Element {
        let start = (head - _count + capacity) % capacity
        return storage[(start + index) % capacity]
    }
}

// MARK: - AudioBufferManager

/// Thread-safe ring buffer that bridges audio capture to transcription.
/// Receives buffers from mic and system audio, provides chunks for WhisperKit.
///
/// Audio mixing: mic and system audio are summed sample-by-sample (not concatenated).
/// Concatenating would give WhisperKit alternating windows of each source, making
/// it impossible to transcribe both speakers. Summing produces a single waveform
/// where both voices are simultaneously audible -- the correct input for Whisper.
final class AudioBufferManager {
    private let lock = NSLock()
    /// Serializes the actual `AVAudioFile.write` calls. The mic callback thread
    /// and the system-audio callback thread both write the mixed `audioFile`,
    /// and `AVAudioFile.write` is not safe for concurrent writers — without this
    /// the WAV gets corrupted (and can crash inside CoreAudio). Kept separate
    /// from `lock` (which guards the sample ring buffers) so disk I/O never
    /// blocks the transcription chunker, and acquired only after `lock` is
    /// released to avoid lock-ordering inversion.
    private let fileWriteLock = NSLock()

    /// Circular buffers: 30 seconds at 16kHz = 480,000 samples capacity.
    private var micSamples = CircularBuffer<Float>(capacity: 480_000, defaultValue: 0)
    private var systemSamples = CircularBuffer<Float>(capacity: 480_000, defaultValue: 0)
    /// During capture this holds the MIC stream only (continuous → its own
    /// timeline is the recording wall-clock); `finishRecording` overwrites it
    /// with the true mic+system mix once both timelines are aligned. Writing
    /// mic-only during capture keeps a usable file if the app dies mid-record.
    private var audioFile: AVAudioFile?
    /// System-audio-only file — input for diarization AND the energy "you"
    /// anchor, which both need it on the SAME timeline as the mixed file. System
    /// buffers arrive sparsely (only while remote audio plays), so they are
    /// silence-padded to their true wall-clock position rather than concatenated.
    private var systemAudioFile: AVAudioFile?
    private let sampleRate: Double = 16000

    // MARK: - Aligned-timeline writing
    //
    // The mixed and system WAVs MUST share a sample timeline (sample N = the same
    // wall-clock instant in both) or any cross-track work — the energy anchor,
    // offline diarization — reads misaligned audio. We position every buffer at
    // its real offset from a common t0 (first buffer's host time) and silence-pad
    // gaps, so both files run the full recording length and line up.
    private var mixedFileURL: URL?
    private var systemFileURL: URL?
    private var recordingStartHostTime: UInt64?
    private var samplesWrittenMic: Int = 0
    private var samplesWrittenSystem: Int = 0
    private let timebase: mach_timebase_info_data_t = {
        var t = mach_timebase_info_data_t()
        mach_timebase_info(&t)
        return t
    }()
    private func hostSeconds(_ host: UInt64) -> Double {
        Double(host) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }

    /// Canonical capture format that EVERY incoming buffer is converted to before
    /// it touches the sample buffers or the WAV files: 16 kHz mono Float32. Mic
    /// and system inputs arrive at arbitrary hardware rates — ScreenCaptureKit
    /// commonly delivers 44.1/48 kHz, and writing those straight into the 16 kHz
    /// file is what threw `kAudioFileUnspecifiedError` (CoreAudio 2003334207) on
    /// some machines. Converting at ingress makes capture robust to any device.
    private lazy var canonicalFormat: AVAudioFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false
    )!
    /// One stateful AVAudioConverter per distinct input format (mic vs system
    /// differ), so sample-rate conversion keeps phase continuity across buffers.
    private var converters: [String: AVAudioConverter] = [:]
    private let converterLock = NSLock()

    /// Convert any buffer to `canonicalFormat` (16 kHz mono Float32). Returns the
    /// input unchanged when it already matches, and nil — so the caller safely
    /// skips the buffer rather than crashing — when the format is degenerate
    /// (0 Hz / 0 ch, e.g. an un-granted mic) or a converter can't be built.
    private func canonicalize(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let inFmt = buffer.format
        if inFmt == canonicalFormat { return buffer }
        guard inFmt.sampleRate > 0, inFmt.channelCount > 0, buffer.frameLength > 0 else { return nil }

        let key = "\(inFmt.sampleRate)|\(inFmt.channelCount)|\(inFmt.commonFormat.rawValue)|\(inFmt.isInterleaved)"
        converterLock.lock()
        let converter: AVAudioConverter?
        if let cached = converters[key] {
            converter = cached
        } else if let made = AVAudioConverter(from: inFmt, to: canonicalFormat) {
            converters[key] = made
            converter = made
        } else {
            converter = nil
        }
        converterLock.unlock()
        guard let converter else { return nil }

        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * canonicalFormat.sampleRate / inFmt.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: canonicalFormat, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inStatus in
            if consumed { inStatus.pointee = .noDataNow; return nil }
            consumed = true
            inStatus.pointee = .haveData
            return buffer
        }
        if status == .error || out.frameLength == 0 { return nil }
        return out
    }

    /// Maximum recording duration in seconds. Prevents unbounded memory growth
    /// from accidental multi-hour recordings. 2 hours = 7200s.
    /// At 16kHz mono Float32, 2 hours ~ 460 MB per source buffer.
    let maxRecordingDurationSeconds: TimeInterval = 7200

    /// Maximum sample count per source buffer, derived from maxRecordingDurationSeconds.
    private var maxSampleCount: Int { Int(maxRecordingDurationSeconds * sampleRate) }

    /// True when either buffer has hit the max duration limit.
    private(set) var isAtCapacity = false

    /// Duration of audio chunks provided to the transcriber (seconds).
    /// Whisper is designed for 30-second windows -- shorter chunks destroy context
    /// and produce [BLANK_AUDIO] / [inaudible] output.
    let chunkDuration: TimeInterval = 30.0

    /// Overlap between consecutive chunks (seconds).
    /// 5s overlap ensures no speech is lost at chunk boundaries.
    let chunkOverlap: TimeInterval = 5.0

    private var chunkSampleCount: Int { Int(chunkDuration * sampleRate) }
    private var overlapSampleCount: Int { Int(chunkOverlap * sampleRate) }

    /// The longer of the two source buffers determines when a chunk is ready.
    private var maxBufferCount: Int {
        max(micSamples.count, systemSamples.count)
    }

    // MARK: - Error Handling (Task 4)

    /// Called when a file write error occurs. Wire this to surface errors to the UI.
    var onWriteError: ((Error) -> Void)?

    /// Number of consecutive write failures. Auto-stops after 5.
    private var consecutiveWriteFailures: Int = 0
    private let maxConsecutiveWriteFailures = 5

    // MARK: - Memory Pressure Monitoring (Task 12)

    /// Called on critical memory pressure so the caller (e.g. AppState) can auto-stop.
    var onMemoryPressure: (() -> Void)?

    private var memoryPressureSource: DispatchSourceMemoryPressure?

    /// Begin monitoring system memory pressure.
    func startMemoryPressureMonitoring() {
        // Cancel any existing source first — `prepareForRecording` can be called
        // again (e.g. a start-failure retry) without an intervening
        // `finishRecording`, which would otherwise leak the prior source and
        // leave two handlers mutating the buffers under pressure.
        memoryPressureSource?.cancel()
        memoryPressureSource = nil
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let event = source.data
            if event.contains(.critical) {
                // Critical: flush everything and notify caller to auto-stop
                self.lock.lock()
                self.micSamples.removeAll()
                self.systemSamples.removeAll()
                self.lock.unlock()
                self.onMemoryPressure?()
            } else if event.contains(.warning) {
                // Warning: flush older buffers (keep only overlap worth of samples)
                self.lock.lock()
                let keepCount = self.overlapSampleCount
                if self.micSamples.count > keepCount {
                    self.micSamples.removeFirst(self.micSamples.count - keepCount)
                }
                if self.systemSamples.count > keepCount {
                    self.systemSamples.removeFirst(self.systemSamples.count - keepCount)
                }
                self.lock.unlock()
            }
        }
        source.resume()
        memoryPressureSource = source
    }

    /// Total samples appended (for capacity tracking, since circular buffer wraps).
    private var totalMicSamplesAppended: Int = 0
    private var totalSystemSamplesAppended: Int = 0

    func prepareForRecording(outputURL: URL) throws {
        // Create the recording file robustly. The mixed file is required; its
        // creation throwing a raw AVFoundation error
        // (com.apple.coreaudio.avfaudio 2003334207 / kAudioFileUnspecifiedError)
        // is the most likely reason recording fails on a machine the build
        // wasn't tested on. We try the canonical Float32 WAV first (what the
        // write path produces) and fall back to a universally-supported 16-bit
        // PCM WAV if a given macOS rejects IEEE-float WAV. Either way the file's
        // processingFormat is 16 kHz mono Float32, so the converted buffers
        // still match on write.
        guard let file = Self.makeAudioFile(at: outputURL, primary: canonicalFormat.settings) else {
            throw AudioCaptureError.captureSetupFailed(
                "Couldn't create the recording file at \(outputURL.lastPathComponent). The disk may be full or the location unwritable."
            )
        }
        audioFile = file
        mixedFileURL = outputURL

        // System-only file is best-effort (used for diarization). Same fallback.
        let systemURL = Self.systemAudioURL(for: outputURL)
        systemAudioFile = Self.makeAudioFile(at: systemURL, primary: canonicalFormat.settings)
        systemFileURL = systemAudioFile != nil ? systemURL : nil

        recordingStartHostTime = nil
        samplesWrittenMic = 0
        samplesWrittenSystem = 0
        consecutiveWriteFailures = 0
        startMemoryPressureMonitoring()
    }

    /// Create an AVAudioFile for writing, trying the preferred (Float32) settings
    /// then a maximally-compatible 16-bit PCM WAV fallback. Returns nil only if
    /// both fail (disk/permission). Both produce a 16 kHz mono file whose
    /// processingFormat is Float32, matching the canonical write buffers.
    private static func makeAudioFile(at url: URL, primary: [String: Any]) -> AVAudioFile? {
        if let f = try? AVAudioFile(forWriting: url, settings: primary) { return f }
        let pcm16: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        return try? AVAudioFile(forWriting: url, settings: pcm16)
    }

    /// Returns the system-audio-only WAV URL derived from the mixed audio URL.
    /// e.g. `.../abc123.wav` → `.../abc123_system.wav`
    static func systemAudioURL(for mixedURL: URL) -> URL {
        let stem = mixedURL.deletingPathExtension().lastPathComponent
        return mixedURL.deletingLastPathComponent()
            .appendingPathComponent("\(stem)_system.wav")
    }

    func appendMicBuffer(_ rawBuffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        // Convert to 16 kHz mono Float32 first; skip the buffer if it can't be
        // converted (degenerate device format) rather than writing a mismatch.
        guard let buffer = canonicalize(rawBuffer) else { return }
        guard let channelData = buffer.floatChannelData else { return }
        let samples = Array(UnsafeBufferPointer(
            start: channelData[0],
            count: Int(buffer.frameLength)
        ))

        lock.lock()
        totalMicSamplesAppended += samples.count
        if totalMicSamplesAppended < maxSampleCount {
            micSamples.append(contentsOf: samples)
        } else {
            isAtCapacity = true
        }
        lock.unlock()

        writePositioned(buffer, at: time, isMic: true)
    }

    func appendSystemBuffer(_ rawBuffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        // ScreenCaptureKit usually delivers 44.1/48 kHz; convert to the canonical
        // 16 kHz so it matches the file format AND the 16 kHz mic samples it gets
        // mixed with for transcription. Skip if it can't be converted.
        guard let buffer = canonicalize(rawBuffer) else { return }
        guard let channelData = buffer.floatChannelData else { return }
        let samples = Array(UnsafeBufferPointer(
            start: channelData[0],
            count: Int(buffer.frameLength)
        ))

        lock.lock()
        totalSystemSamplesAppended += samples.count
        if totalSystemSamplesAppended < maxSampleCount {
            systemSamples.append(contentsOf: samples)
        } else {
            isAtCapacity = true
        }
        lock.unlock()

        writePositioned(buffer, at: time, isMic: false)
    }

    /// Returns the next mixed audio chunk for transcription, or nil if not enough data.
    ///
    /// Mixing strategy: sum mic and system samples at each position, then scale by 0.5
    /// to prevent clipping. If one source is shorter (still buffering), treat missing
    /// samples as silence (zero). This means early chunks may be mic-only or system-only
    /// until both streams are in sync -- that's correct behaviour.
    func nextChunk() -> AudioChunk? {
        lock.lock()
        defer { lock.unlock() }

        guard maxBufferCount >= chunkSampleCount else { return nil }

        let count = chunkSampleCount
        var mixed = [Float](repeating: 0, count: count)

        // Sum mic samples (zero-padded if shorter than chunk)
        for i in 0..<count {
            let mic: Float = i < micSamples.count ? micSamples[i] : 0
            let sys: Float = i < systemSamples.count ? systemSamples[i] : 0
            // Scale by 0.5 to prevent clipping when both sources are loud
            mixed[i] = (mic + sys) * 0.5
        }

        // Determine primary source for metadata
        let hasMic = micSamples.count >= count
        let hasSys = systemSamples.count >= count
        let source: AudioSource = (hasMic && hasSys) ? .microphone : (hasMic ? .microphone : .system)

        // Remove consumed samples from each buffer, keeping the overlap window
        let removeCount = chunkSampleCount - overlapSampleCount
        if micSamples.count >= removeCount { micSamples.removeFirst(removeCount) }
        if systemSamples.count >= removeCount { systemSamples.removeFirst(removeCount) }

        return AudioChunk(
            samples: mixed,
            source: source,
            timestamp: Date()
        )
    }

    /// Returns true if there's enough audio from either source for a transcription chunk.
    var hasChunkReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return maxBufferCount >= chunkSampleCount
    }

    func finishRecording() {
        converterLock.lock()
        converters.removeAll()
        converterLock.unlock()

        // Close the capture files first (releasing the AVAudioFile flushes it),
        // guarding against any in-flight positioned write, THEN merge mic+system
        // into the aligned mix on disk. Callers stop both capture streams before
        // calling finishRecording, so no further appends arrive here.
        fileWriteLock.lock()
        lock.lock()
        audioFile = nil
        systemAudioFile = nil
        lock.unlock()
        fileWriteLock.unlock()

        mergeMixIntoFile()

        lock.lock()
        micSamples.removeAll()
        systemSamples.removeAll()
        totalMicSamplesAppended = 0
        totalSystemSamplesAppended = 0
        consecutiveWriteFailures = 0
        mixedFileURL = nil
        systemFileURL = nil
        recordingStartHostTime = nil
        samplesWrittenMic = 0
        samplesWrittenSystem = 0
        // Reset capacity flag — the same AudioBufferManager instance is reused
        // across recordings, so a stale `true` from a 2-hour-cap hit would
        // immediately auto-stop the next recording.
        isAtCapacity = false
        lock.unlock()

        memoryPressureSource?.cancel()
        memoryPressureSource = nil
    }

    // MARK: - Private — aligned-timeline writing

    /// Write a canonicalized (16 kHz mono) buffer to its stream's file at its true
    /// wall-clock position, silence-padding any gap since the last write so the
    /// mic and system files stay on one shared timeline. `isMic` selects the file
    /// and the per-stream written-sample counter; both are anchored to the same
    /// `recordingStartHostTime`. Called on the mic and system capture threads.
    private func writePositioned(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime, isMic: Bool) {
        let host = time.isHostTimeValid ? time.hostTime : mach_absolute_time()

        lock.lock()
        if recordingStartHostTime == nil { recordingStartHostTime = host }
        let t0 = recordingStartHostTime ?? host
        let file = isMic ? audioFile : systemAudioFile
        let written = isMic ? samplesWrittenMic : samplesWrittenSystem
        lock.unlock()

        guard let file else { return }

        // Target sample offset of this buffer from t0 on the 16 kHz timeline.
        let offsetSec = max(0, hostSeconds(host) - hostSeconds(t0))
        let target = Int(offsetSec * sampleRate)

        var writeError: Error?
        fileWriteLock.lock()
        do {
            if target > written {
                try writeSilence(to: file, frames: target - written)
            }
            try file.write(from: buffer)
        } catch {
            writeError = error
        }
        fileWriteLock.unlock()

        let advanced = max(written, target) + Int(buffer.frameLength)
        lock.lock()
        if isMic { samplesWrittenMic = advanced } else { samplesWrittenSystem = advanced }
        lock.unlock()

        // Write-failure accounting only auto-stops on the required mixed (mic) file.
        guard let writeError else {
            if isMic { lock.lock(); consecutiveWriteFailures = 0; lock.unlock() }
            return
        }
        guard isMic else { return }
        lock.lock()
        consecutiveWriteFailures += 1
        let failures = consecutiveWriteFailures
        lock.unlock()
        onWriteError?(writeError)
        if failures >= maxConsecutiveWriteFailures {
            lock.lock(); audioFile = nil; lock.unlock()
        }
    }

    /// Append `frames` of silence to an open file, in bounded chunks so a long
    /// system gap (minutes of no remote audio) doesn't allocate one huge buffer.
    private func writeSilence(to file: AVAudioFile, frames: Int) throws {
        guard frames > 0 else { return }
        let chunk = 16_000
        guard let zero = AVAudioPCMBuffer(pcmFormat: canonicalFormat, frameCapacity: AVAudioFrameCount(chunk)) else { return }
        var remaining = frames
        while remaining > 0 {
            let n = min(chunk, remaining)
            zero.frameLength = AVAudioFrameCount(n)
            if let ch = zero.floatChannelData?[0] { for i in 0..<n { ch[i] = 0 } }
            try file.write(from: zero)
            remaining -= n
        }
    }

    /// Produce the true mic+system mix on disk. During capture `mixedFileURL`
    /// holds mic-only and `systemFileURL` holds the positioned system track —
    /// both on the shared timeline — so summing them frame-for-frame yields an
    /// aligned mix. Writes to a temp file then atomically replaces the mixed
    /// file. On any failure the mic-only file is left in place (degraded but
    /// valid), never a broken file. Must run AFTER the capture files are closed.
    private func mergeMixIntoFile() {
        guard let mixedURL = mixedFileURL else { return }
        guard let systemURL = systemFileURL,
              let micIn = try? AVAudioFile(forReading: mixedURL),
              let sysIn = try? AVAudioFile(forReading: systemURL) else {
            return  // no system track → mic-only mixed file is already correct
        }
        let tmpURL = mixedURL.deletingPathExtension().appendingPathExtension("mixing.wav")
        try? FileManager.default.removeItem(at: tmpURL)
        guard let out = Self.makeAudioFile(at: tmpURL, primary: canonicalFormat.settings) else { return }

        let block = 32_000
        guard let micBuf = AVAudioPCMBuffer(pcmFormat: micIn.processingFormat, frameCapacity: AVAudioFrameCount(block)),
              let sysBuf = AVAudioPCMBuffer(pcmFormat: sysIn.processingFormat, frameCapacity: AVAudioFrameCount(block)),
              let outBuf = AVAudioPCMBuffer(pcmFormat: canonicalFormat, frameCapacity: AVAudioFrameCount(block)) else { return }

        do {
            while true {
                micBuf.frameLength = 0; sysBuf.frameLength = 0
                try? micIn.read(into: micBuf, frameCount: AVAudioFrameCount(block))
                try? sysIn.read(into: sysBuf, frameCount: AVAudioFrameCount(block))
                let n = Int(max(micBuf.frameLength, sysBuf.frameLength))
                if n == 0 { break }
                let m = micBuf.floatChannelData?[0]
                let s = sysBuf.floatChannelData?[0]
                guard let o = outBuf.floatChannelData?[0] else { break }
                let mc = Int(micBuf.frameLength), sc = Int(sysBuf.frameLength)
                for i in 0..<n {
                    let mv = i < mc ? (m?[i] ?? 0) : 0
                    let sv = i < sc ? (s?[i] ?? 0) : 0
                    o[i] = (mv + sv) * 0.5
                }
                outBuf.frameLength = AVAudioFrameCount(n)
                try out.write(from: outBuf)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmpURL)
            return  // leave mic-only file untouched
        }

        // Replace the mic-only file with the mixed temp. Prefer the atomic
        // replaceItemAt; fall back to remove+move if it throws.
        do {
            _ = try FileManager.default.replaceItemAt(mixedURL, withItemAt: tmpURL)
        } catch {
            try? FileManager.default.removeItem(at: mixedURL)
            try? FileManager.default.moveItem(at: tmpURL, to: mixedURL)
        }
    }
}

// MARK: - Supporting Types

enum AudioSource {
    case microphone
    case system
}

struct AudioChunk {
    let samples: [Float]
    let source: AudioSource
    let timestamp: Date
}

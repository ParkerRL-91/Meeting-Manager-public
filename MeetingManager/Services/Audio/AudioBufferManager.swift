import AVFoundation
import Dispatch
import Foundation

// MARK: - AudioBufferManager

/// Thread-safe disk writer that bridges audio capture to post-meeting batch
/// transcription. Receives buffers from mic and system audio, converts them
/// to the canonical 16 kHz mono format, and writes them to per-source WAVs
/// positioned at their true wall-clock offsets. (Live in-meeting chunking was
/// removed with live transcription in v4.0 — transcription is batch-only,
/// reading the finished files.)
///
/// Audio mixing: at stop, mic and system audio are summed sample-by-sample
/// into the mixed file (not concatenated). Concatenating would give
/// WhisperKit alternating windows of each source, making it impossible to
/// transcribe both speakers. Summing produces a single waveform where both
/// voices are simultaneously audible -- the correct input for Whisper.
///
/// @unchecked Sendable: every mutable property is guarded by `lock` /
/// `fileWriteLock` / `converterLock` — the class is already accessed
/// concurrently from the mic and system-audio callback threads by design.
final class AudioBufferManager: @unchecked Sendable {
    private let lock = NSLock()
    /// Serializes the actual `AVAudioFile.write` calls. The mic callback thread
    /// and the system-audio callback thread both write the mixed `audioFile`,
    /// and `AVAudioFile.write` is not safe for concurrent writers — without this
    /// the WAV gets corrupted (and can crash inside CoreAudio). Kept separate
    /// from `lock` (which guards the capacity counters), and acquired only
    /// after `lock` is released to avoid lock-ordering inversion.
    private let fileWriteLock = NSLock()

    /// All positioned file writes run here, not on the capture callback
    /// threads — a long silence gap can require seconds of catch-up padding,
    /// and stalling the SCK delegate queue (or the engine tap queue) on disk
    /// I/O delays subsequent buffers. Serial, so write order is preserved.
    /// `finishRecording` drains it synchronously before closing the files.
    private let writeQueue = DispatchQueue(label: "com.meetingmanager.audiowrite", qos: .userInitiated)

    // MARK: - Live catch-up ring (TASK-053)
    //
    // A 3-minute wall-clock-indexed SUMMING ring of the canonical 16 kHz
    // mono stream: mic and system are separate sparse positioned streams,
    // so each chunk adds into slot (absoluteSample % N) — naive appending
    // would interleave them (review M1). All access is on `writeQueue`
    // (single-writer), so no extra locking. ~11.5 MB while recording,
    // freed on finish. Read via `liveRingSnapshot` (writeQueue.sync).
    private let ringSeconds = 180
    private var liveRing: [Float] = []
    private var ringLatestAbs: Int = -1

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
    /// Duration cap, NOT a memory cap: capture memory is bounded by the fixed
    /// 30 s ring buffers regardless of meeting length (audio streams to disk).
    /// The cap exists so a forgotten recording auto-stops at 2 hours.
    let maxRecordingDurationSeconds: TimeInterval = 7200

    /// Maximum sample count per source buffer, derived from maxRecordingDurationSeconds.
    private var maxSampleCount: Int { Int(maxRecordingDurationSeconds * sampleRate) }

    /// True when either buffer has hit the max duration limit. Backing store
    /// is written under `lock` from the audio callback threads; the public
    /// read takes the same lock (it's polled from the main thread).
    private var _isAtCapacity = false
    var isAtCapacity: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isAtCapacity
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
            // Capture memory is bounded (audio streams straight to disk), so
            // there is nothing to flush here — but CRITICAL pressure still
            // means the machine is in trouble; let the owner auto-stop the
            // recording cleanly while the files are intact.
            if source.data.contains(.critical) {
                self.onMemoryPressure?()
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
        let made = Self.makeAudioFile(at: outputURL, primary: canonicalFormat.settings)
        guard let file = made.file else {
            // Surface the full path and the real OS error — the previous generic
            // "disk may be full" guess was undiagnosable in the field.
            let detail = made.error.map { ": \($0.localizedDescription)" } ?? "."
            throw AudioCaptureError.captureSetupFailed(
                "Couldn't create the recording file at \(outputURL.path)\(detail) Change the recording location in Settings → General → Recordings."
            )
        }
        audioFile = file
        mixedFileURL = outputURL

        // System-only file is best-effort (used for diarization). Same fallback.
        let systemURL = Self.systemAudioURL(for: outputURL)
        systemAudioFile = Self.makeAudioFile(at: systemURL, primary: canonicalFormat.settings).file
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
    private static func makeAudioFile(at url: URL, primary: [String: Any]) -> (file: AVAudioFile?, error: Error?) {
        do { return (try AVAudioFile(forWriting: url, settings: primary), nil) }
        catch {
            let pcm16: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
            do { return (try AVAudioFile(forWriting: url, settings: pcm16), nil) }
            catch { return (nil, error) }
        }
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

        lock.lock()
        totalMicSamplesAppended += Int(buffer.frameLength)
        if totalMicSamplesAppended >= maxSampleCount {
            _isAtCapacity = true
        }
        lock.unlock()

        writeQueue.async { [weak self] in
            self?.writePositioned(buffer, at: time, isMic: true)
        }
    }

    func appendSystemBuffer(_ rawBuffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        // ScreenCaptureKit usually delivers 44.1/48 kHz; convert to the canonical
        // 16 kHz so it matches the file format AND the 16 kHz mic samples it gets
        // summed with at stop. Skip if it can't be converted.
        guard let buffer = canonicalize(rawBuffer) else { return }

        lock.lock()
        totalSystemSamplesAppended += Int(buffer.frameLength)
        if totalSystemSamplesAppended >= maxSampleCount {
            _isAtCapacity = true
        }
        lock.unlock()

        writeQueue.async { [weak self] in
            self?.writePositioned(buffer, at: time, isMic: false)
        }
    }

    func finishRecording() {
        converterLock.lock()
        converters.removeAll()
        converterLock.unlock()

        // Drain queued positioned writes BEFORE closing the files — callers
        // stopped both capture streams already, so this barrier guarantees
        // every delivered buffer reaches disk.
        writeQueue.sync {
            // Free the catch-up ring with the recording (TASK-053).
            liveRing = []
            ringLatestAbs = -1
        }

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
        _isAtCapacity = false
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

        // Invariant: each stream is single-writer — the mic thread owns
        // `audioFile`+`samplesWrittenMic`, the system thread owns
        // `systemAudioFile`+`samplesWrittenSystem`. They never touch each other's
        // file or counter, so reading `written` under `lock` then appending under
        // `fileWriteLock` is consistent without holding one lock across the other.
        lock.lock()
        // Anchor the shared timeline to the MIC stream only. The system tap is
        // started BEFORE the mic (AudioCaptureService) and emits ONLY while remote
        // audio plays, so letting it define t0 would anchor a meeting that is
        // silent at the start to the first remote utterance and misalign mic
        // against system. Mic is continuous from recording start, so it is the
        // correct origin. System buffers that arrive before the first mic buffer
        // (t0 unknown) are written at the current position (≈ sample 0), bounded
        // by the few-ms tap-start lead.
        if isMic && recordingStartHostTime == nil { recordingStartHostTime = host }
        let t0 = recordingStartHostTime
        let file = isMic ? audioFile : systemAudioFile
        let written = isMic ? samplesWrittenMic : samplesWrittenSystem
        lock.unlock()

        guard let file else { return }

        // Bound the file writer by the same 2-hour cap as the capacity
        // counters, so a long silence gap can't silence-pad the file
        // unboundedly.
        guard written < maxSampleCount else { return }

        // Target sample offset from t0 on the 16 kHz timeline. Before the first
        // mic buffer t0 is nil → append at the current position. Clamp to the cap.
        let target: Int
        if let t0 {
            let offsetSec = max(0, hostSeconds(host) - hostSeconds(t0))
            target = min(Int(offsetSec * sampleRate), maxSampleCount)
        } else {
            target = written
        }

        mixIntoRing(buffer, at: target)

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

    /// Sum a canonical 16 kHz mono chunk into the catch-up ring at its
    /// absolute timeline position. writeQueue-only.
    private func mixIntoRing(_ buffer: AVAudioPCMBuffer, at startIndex: Int) {
        guard let data = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }
        let N = ringSeconds * Int(sampleRate)
        if liveRing.count != N { liveRing = [Float](repeating: 0, count: N); ringLatestAbs = -1 }
        let end = startIndex + n

        // Advance the head: zero slots the new region laps over. A gap
        // larger than the whole window just resets the ring.
        if end > ringLatestAbs + 1 {
            let gapStart = ringLatestAbs + 1
            if ringLatestAbs < 0 || end - gapStart >= N {
                for i in 0..<N { liveRing[i] = 0 }
            } else {
                var z = max(gapStart, end - N)
                while z < end { liveRing[z % N] = 0; z += 1 }
            }
            ringLatestAbs = end - 1
        }

        // Sum, dropping anything older than the window (late system audio).
        let minAbs = max(0, ringLatestAbs + 1 - N)
        var i = max(startIndex, minAbs)
        var src = i - startIndex
        while i < end {
            liveRing[i % N] += data[src]
            i += 1; src += 1
        }
    }

    /// Ordered copy of the last `lastSeconds` of the catch-up ring.
    /// Synchronous hop onto writeQueue — bounded by one memcpy-scale loop.
    func liveRingSnapshot(lastSeconds: Double) -> [Float] {
        var out: [Float] = []
        writeQueue.sync {
            let N = liveRing.count
            guard N > 0, ringLatestAbs >= 0 else { return }
            let n = min(Int(lastSeconds * sampleRate), min(N, ringLatestAbs + 1))
            guard n > 0 else { return }
            out.reserveCapacity(n)
            let start = ringLatestAbs + 1 - n
            for i in start...ringLatestAbs { out.append(liveRing[i % N]) }
        }
        return out
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
        guard let out = Self.makeAudioFile(at: tmpURL, primary: canonicalFormat.settings).file else { return }

        let block = 32_000
        guard let micBuf = AVAudioPCMBuffer(pcmFormat: micIn.processingFormat, frameCapacity: AVAudioFrameCount(block)),
              let sysBuf = AVAudioPCMBuffer(pcmFormat: sysIn.processingFormat, frameCapacity: AVAudioFrameCount(block)),
              let outBuf = AVAudioPCMBuffer(pcmFormat: canonicalFormat, frameCapacity: AVAudioFrameCount(block)) else { return }

        // Streaming merge that is resilient to short reads AND different file
        // lengths: each file refills its buffer only when fully consumed and we
        // mix by absolute frame position. A short read just yields a smaller batch
        // this round; the rest comes on the next refill (no permanent desync, the
        // bug a naive "read both, mix max, repeat" loop has). EOF on one side →
        // zero-fill that side for the remaining tail.
        var micIdx = 0, sysIdx = 0      // frames consumed within the current buffer
        var micLen = 0, sysLen = 0      // valid frames in the current buffer
        var micEOF = false, sysEOF = false
        // Read at most the frames REMAINING in the file. Calling
        // read(into:frameCount:) with the full block when fewer frames remain (or
        // none) throws `nilError` at/near EOF — that throw previously bailed the
        // whole merge and left the raw mic-only file on disk. Bounding by
        // (length - framePosition) and skipping a zero-remaining read avoids it.
        func readBlock(_ f: AVAudioFile, _ b: AVAudioPCMBuffer) throws -> Int {
            let remaining = f.length - f.framePosition
            guard remaining > 0 else { return 0 }
            b.frameLength = 0
            try f.read(into: b, frameCount: min(AVAudioFrameCount(block), AVAudioFrameCount(remaining)))
            return Int(b.frameLength)
        }
        do {
            while true {
                if micIdx >= micLen && !micEOF {
                    micLen = try readBlock(micIn, micBuf); micIdx = 0
                    if micLen == 0 { micEOF = true }
                }
                if sysIdx >= sysLen && !sysEOF {
                    sysLen = try readBlock(sysIn, sysBuf); sysIdx = 0
                    if sysLen == 0 { sysEOF = true }
                }
                let micAvail = micLen - micIdx
                let sysAvail = sysLen - sysIdx
                if micAvail == 0 && sysAvail == 0 { break }
                let n = (micAvail > 0 && sysAvail > 0) ? min(micAvail, sysAvail) : max(micAvail, sysAvail)
                let m = micBuf.floatChannelData?[0]
                let s = sysBuf.floatChannelData?[0]
                guard let o = outBuf.floatChannelData?[0] else { break }
                for i in 0..<n {
                    let mv = micAvail > 0 ? (m?[micIdx + i] ?? 0) : 0
                    let sv = sysAvail > 0 ? (s?[sysIdx + i] ?? 0) : 0
                    o[i] = (mv + sv) * 0.5
                }
                outBuf.frameLength = AVAudioFrameCount(n)
                try out.write(from: outBuf)
                if micAvail > 0 { micIdx += n }
                if sysAvail > 0 { sysIdx += n }
            }
        } catch {
            try? FileManager.default.removeItem(at: tmpURL)
            return  // leave mic-only file untouched
        }

        // Replace the mic-only file with the mixed temp. Prefer the atomic
        // replaceItemAt. The fallback NEVER leaves zero valid files: move the
        // existing file aside, move the temp in, then drop the backup; on any
        // failure restore the backup.
        do {
            _ = try FileManager.default.replaceItemAt(mixedURL, withItemAt: tmpURL)
        } catch {
            let bakURL = mixedURL.deletingPathExtension().appendingPathExtension("bak.wav")
            try? FileManager.default.removeItem(at: bakURL)
            do {
                try FileManager.default.moveItem(at: mixedURL, to: bakURL)
                try FileManager.default.moveItem(at: tmpURL, to: mixedURL)
                try? FileManager.default.removeItem(at: bakURL)
            } catch {
                try? FileManager.default.moveItem(at: bakURL, to: mixedURL)
                try? FileManager.default.removeItem(at: tmpURL)
            }
        }
    }
}


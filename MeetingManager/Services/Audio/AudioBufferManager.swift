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

    /// Circular buffers: 30 seconds at 16kHz = 480,000 samples capacity.
    private var micSamples = CircularBuffer<Float>(capacity: 480_000, defaultValue: 0)
    private var systemSamples = CircularBuffer<Float>(capacity: 480_000, defaultValue: 0)
    private var audioFile: AVAudioFile?
    /// Separate file capturing only system audio — used as input for speaker diarization.
    private var systemAudioFile: AVAudioFile?
    private let sampleRate: Double = 16000

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
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!

        audioFile = try AVAudioFile(
            forWriting: outputURL,
            settings: format.settings
        )

        // Write system-only audio alongside the mixed file for speaker diarization.
        let systemURL = Self.systemAudioURL(for: outputURL)
        systemAudioFile = try? AVAudioFile(
            forWriting: systemURL,
            settings: format.settings
        )

        consecutiveWriteFailures = 0
        startMemoryPressureMonitoring()
    }

    /// Returns the system-audio-only WAV URL derived from the mixed audio URL.
    /// e.g. `.../abc123.wav` → `.../abc123_system.wav`
    static func systemAudioURL(for mixedURL: URL) -> URL {
        let stem = mixedURL.deletingPathExtension().lastPathComponent
        return mixedURL.deletingLastPathComponent()
            .appendingPathComponent("\(stem)_system.wav")
    }

    func appendMicBuffer(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
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

        writeToFile(buffer)
    }

    func appendSystemBuffer(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
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

        writeToFile(buffer)
        writeSystemToFile(buffer)
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
        lock.lock()
        audioFile = nil
        systemAudioFile = nil
        micSamples.removeAll()
        systemSamples.removeAll()
        totalMicSamplesAppended = 0
        totalSystemSamplesAppended = 0
        consecutiveWriteFailures = 0
        // Reset capacity flag — the same AudioBufferManager instance is reused
        // across recordings, so a stale `true` from a 2-hour-cap hit would
        // immediately auto-stop the next recording.
        isAtCapacity = false
        lock.unlock()

        memoryPressureSource?.cancel()
        memoryPressureSource = nil
    }

    // MARK: - Private

    private func writeSystemToFile(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let file = systemAudioFile
        lock.unlock()
        guard let file else { return }
        try? file.write(from: buffer)
    }

    private func writeToFile(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let file = audioFile
        lock.unlock()

        guard let file else { return }
        do {
            try file.write(from: buffer)
            lock.lock()
            consecutiveWriteFailures = 0
            lock.unlock()
        } catch {
            lock.lock()
            consecutiveWriteFailures += 1
            let failures = consecutiveWriteFailures
            lock.unlock()

            onWriteError?(error)

            if failures >= maxConsecutiveWriteFailures {
                // Auto-stop writing to prevent repeated failures
                lock.lock()
                audioFile = nil
                lock.unlock()
            }
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

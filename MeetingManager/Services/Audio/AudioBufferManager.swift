import AVFoundation
import Foundation

/// Thread-safe ring buffer that bridges audio capture to transcription.
/// Receives buffers from mic and system audio, provides chunks for WhisperKit.
///
/// Audio mixing: mic and system audio are summed sample-by-sample (not concatenated).
/// Concatenating would give WhisperKit alternating windows of each source, making
/// it impossible to transcribe both speakers. Summing produces a single waveform
/// where both voices are simultaneously audible — the correct input for Whisper.
final class AudioBufferManager {
    private let lock = NSLock()
    private var micSamples: [Float] = []
    private var systemSamples: [Float] = []
    private var audioFile: AVAudioFile?
    private let sampleRate: Double = 16000

    /// Duration of audio chunks provided to the transcriber (seconds).
    /// Whisper is designed for 30-second windows — shorter chunks destroy context
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
    }

    func appendMicBuffer(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        guard let channelData = buffer.floatChannelData else { return }
        let samples = Array(UnsafeBufferPointer(
            start: channelData[0],
            count: Int(buffer.frameLength)
        ))

        lock.lock()
        micSamples.append(contentsOf: samples)
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
        systemSamples.append(contentsOf: samples)
        lock.unlock()

        writeToFile(buffer)
    }

    /// Returns the next mixed audio chunk for transcription, or nil if not enough data.
    ///
    /// Mixing strategy: sum mic and system samples at each position, then scale by 0.5
    /// to prevent clipping. If one source is shorter (still buffering), treat missing
    /// samples as silence (zero). This means early chunks may be mic-only or system-only
    /// until both streams are in sync — that's correct behaviour.
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
        micSamples.removeAll()
        systemSamples.removeAll()
        lock.unlock()
    }

    // MARK: - Private

    private func writeToFile(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let file = audioFile
        lock.unlock()

        guard let file else { return }
        do {
            try file.write(from: buffer)
        } catch {
            print("Failed to write audio to file: \(error)")
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

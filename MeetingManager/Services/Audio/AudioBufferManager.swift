import AVFoundation
import Foundation

/// Thread-safe ring buffer that bridges audio capture to transcription.
/// Receives buffers from mic and system audio, provides chunks for WhisperKit.
final class AudioBufferManager {
    private let lock = NSLock()
    private var micSamples: [Float] = []
    private var systemSamples: [Float] = []
    private var combinedSamples: [Float] = []
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
        combinedSamples.append(contentsOf: samples)
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
        combinedSamples.append(contentsOf: samples)
        lock.unlock()

        writeToFile(buffer)
    }

    /// Returns the next chunk of audio for transcription, or nil if not enough data
    func nextChunk() -> AudioChunk? {
        lock.lock()
        defer { lock.unlock() }

        guard combinedSamples.count >= chunkSampleCount else { return nil }

        let chunk = Array(combinedSamples.prefix(chunkSampleCount))

        // Determine source based on which buffer contributed more
        let micCount = micSamples.count
        let systemCount = systemSamples.count
        let source: AudioSource = micCount > systemCount ? .microphone : .system

        // Remove consumed samples, keeping overlap
        let removeCount = chunkSampleCount - overlapSampleCount
        if combinedSamples.count > removeCount {
            combinedSamples.removeFirst(removeCount)
        }

        // Trim source-specific buffers proportionally
        let micRemove = min(micSamples.count, removeCount / 2)
        let sysRemove = min(systemSamples.count, removeCount / 2)
        if micRemove > 0 { micSamples.removeFirst(micRemove) }
        if sysRemove > 0 { systemSamples.removeFirst(sysRemove) }

        return AudioChunk(
            samples: chunk,
            source: source,
            timestamp: Date()
        )
    }

    /// Returns true if there's enough audio for a transcription chunk
    var hasChunkReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return combinedSamples.count >= chunkSampleCount
    }

    func finishRecording() {
        lock.lock()
        audioFile = nil
        micSamples.removeAll()
        systemSamples.removeAll()
        combinedSamples.removeAll()
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

import Foundation
import SpeakerKit
import AVFoundation
import os

/// Wraps the SpeakerKit Pyannote pipeline to perform on-device speaker diarization
/// on the system-audio-only WAV file recorded alongside each meeting.
///
/// Flow:
///   1. `diarize(systemAudioURL:participantCount:)` — loads models lazily, runs
///      the full segmenter → embedder → clustering pipeline on the system audio.
///   2. `alignToTranscripts(_:result:)` — maps each Transcript row (which has a
///      start/end time) to the best-matching diarization segment, returning a
///      dictionary of transcriptId → "Speaker N" label.
///
/// Failure at any stage is non-fatal: callers get an empty result and existing
/// "system" labels are left intact. The LLM attribution layer runs after this,
/// mapping cluster IDs to real attendee names.
@MainActor
final class SpeakerDiarizationService {
    static let shared = SpeakerDiarizationService()

    private var speakerKit: SpeakerKit?
    private(set) var modelState: ModelState = .unloaded
    private(set) var downloadProgress: Double = 0

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.meetingmanager",
                                category: "SpeakerDiarization")

    private init() {}

    // MARK: - Model Management

    enum ModelState {
        case unloaded, downloading, loaded, failed
    }

    /// In-flight load, shared by concurrent callers. Without it, a second
    /// caller arriving while the state is `.downloading` started a parallel
    /// download/compile — double bandwidth and model memory, last writer wins.
    private var loadTask: Task<Void, Error>?

    /// Load (and download if needed) the SpeakerKit CoreML models.
    /// Safe to call multiple times — no-ops if already loaded; concurrent
    /// callers await the same in-flight load.
    /// Wrapped in a 5-minute timeout race because the Pyannote model download
    /// can hang indefinitely on a bad network or corrupt cache. (The timeout
    /// is best-effort: the download phase cancels cleanly; a hang inside the
    /// CoreML compile is not cancellation-responsive and outlives the timer.)
    func loadModels() async throws {
        guard modelState != .loaded else { return }

        if let existing = loadTask {
            try await existing.value
            return
        }

        modelState = .downloading
        logger.info("Loading SpeakerKit models...")

        let task = Task<Void, Error> {
            let config = PyannoteConfig(
                download: true,
                load: true,
                verbose: false
            )
            let kit = try await withThrowingTaskGroup(of: SpeakerKit.self) { group in
                group.addTask {
                    return try await SpeakerKit(config)
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(300))
                    throw DiarizationError.modelLoadTimeout
                }
                let loaded = try await group.next()!
                group.cancelAll()
                return loaded
            }
            self.speakerKit = kit
            self.modelState = .loaded
            self.logger.info("SpeakerKit models ready.")
        }
        loadTask = task
        defer { loadTask = nil }

        do {
            try await task.value
        } catch {
            modelState = .failed
            logger.error("SpeakerKit model load failed: \(error.localizedDescription)")
            throw error
        }
    }

    func unloadModels() async {
        await speakerKit?.unloadModels()
        speakerKit = nil
        modelState = .unloaded
    }

    // MARK: - Diarization

    /// Diarize a system-audio WAV file.
    ///
    /// - Parameters:
    ///   - systemAudioURL: Path to the `{meetingId}_system.wav` file.
    ///   - participantCount: Known number of remote speakers (from calendar attendees).
    ///     Passed as a hint to the clusterer; nil lets the model decide.
    /// - Returns: `DiarizationResult` with per-speaker segments (start/end in seconds).
    func diarize(
        systemAudioURL: URL,
        participantCount: Int?
    ) async throws -> DiarizationResult {
        guard FileManager.default.fileExists(atPath: systemAudioURL.path) else {
            throw DiarizationError.audioFileNotFound(systemAudioURL.path)
        }

        let samples = try loadAsSamples(url: systemAudioURL)
        logger.info("Diarizing \(systemAudioURL.lastPathComponent), speakers hint: \(participantCount.map(String.init) ?? "auto")")
        return try await diarize(audioArray: samples, participantCount: participantCount)
    }

    /// Diarize an already-loaded sample buffer. Use this when the caller has
    /// the audio in memory and wants to avoid re-reading the WAV from disk
    /// (e.g. batchTranscribe, which already loaded the file for WhisperKit).
    ///
    /// - Parameters:
    ///   - audioArray: 16 kHz mono Float32 samples.
    ///   - participantCount: Speaker-count hint for the clusterer; nil lets the model decide.
    func diarize(
        audioArray: [Float],
        participantCount: Int?
    ) async throws -> DiarizationResult {
        guard !audioArray.isEmpty else {
            throw DiarizationError.emptyAudio
        }

        if modelState != .loaded {
            try await loadModels()
        }

        guard let kit = speakerKit else {
            throw DiarizationError.modelNotLoaded
        }

        let options = PyannoteDiarizationOptions(
            numberOfSpeakers: participantCount,
            minActiveOffset: 0.5,
            useExclusiveReconciliation: true
        )

        let result = try await kit.diarize(
            audioArray: audioArray,
            options: options
        )

        logger.info("Diarization complete: \(result.speakerCount) speakers, \(result.segments.count) segments")
        return result
    }

    // MARK: - Alignment

    /// Map transcript rows to diarization segments by time overlap.
    ///
    /// Returns a dictionary `[transcriptId: "Speaker N"]` for rows where a
    /// confident match was found. Rows with no matching diarization segment
    /// are omitted — callers leave their existing label intact.
    func alignToTranscripts(
        _ transcripts: [Transcript],
        result: DiarizationResult
    ) -> [Int64: String] {
        var mapping: [Int64: String] = [:]

        for transcript in transcripts {
            // Legacy "system" bucket plus anonymous "Speaker N"/"Speaker" rows
            // are re-alignable; resolved names and "mic" are never re-labelled.
            let label = (transcript.speakerLabel ?? "").lowercased().trimmingCharacters(in: .whitespaces)
            guard let id = transcript.id,
                  label == "system" || label == "speaker" || label.hasPrefix("speaker ") else { continue }

            let txStart = Float(transcript.startTime)
            let txEnd   = Float(transcript.endTime)
            let txLen   = txEnd - txStart
            guard txLen > 0 else { continue }

            // Find the diarization segment with the greatest overlap.
            var bestSegment: SpeakerSegment? = nil
            var bestOverlap: Float = 0

            for segment in result.segments {
                let overlapStart = max(txStart, segment.startTime)
                let overlapEnd   = min(txEnd,   segment.endTime)
                let overlap      = max(0, overlapEnd - overlapStart)
                if overlap > bestOverlap {
                    bestOverlap = overlap
                    bestSegment = segment
                }
            }

            // Require at least 25% overlap with the transcript segment.
            guard let seg = bestSegment,
                  bestOverlap / txLen >= 0.25,
                  let speakerId = seg.speaker.speakerId else { continue }

            // 1-based, matching the batch path's "Speaker N" convention —
            // 0-based labels would collide with batch labels under one name
            // and leak "Speaker 0" to the UI. parseSpeakerId subtracts 1.
            mapping[id] = "Speaker \(speakerId + 1)"
        }

        return mapping
    }

    // MARK: - Private

    /// Read a 16kHz mono Float32 WAV into a plain [Float] array.
    /// Validates the format instead of "converting": `AVAudioFile.read(into:)`
    /// performs NO sample-rate conversion (mismatched formats just error),
    /// so a non-16k file must be rejected loudly — diarizing it would produce
    /// time-warped garbage segments.
    private func loadAsSamples(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let fmt = file.processingFormat
        guard fmt.sampleRate == 16000, fmt.channelCount == 1 else {
            throw DiarizationError.unsupportedFormat(
                sampleRate: fmt.sampleRate, channels: Int(fmt.channelCount))
        }

        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frameCount) else {
            return []
        }
        try file.read(into: buffer)

        guard let channelData = buffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))
    }
}

// MARK: - Errors

enum DiarizationError: LocalizedError {
    case modelNotLoaded
    case modelLoadTimeout
    case audioFileNotFound(String)
    case emptyAudio
    case insufficientDiskSpace(freeMB: Int64)
    case unsupportedFormat(sampleRate: Double, channels: Int)

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "Speaker diarization model is not loaded."
        case .modelLoadTimeout:
            return "Speaker diarization model load timed out after 5 minutes."
        case .audioFileNotFound(let path):
            return "System audio file not found at \(path)."
        case .emptyAudio:
            return "System audio file is empty — nothing to diarize."
        case .insufficientDiskSpace(let freeMB):
            return "Not enough disk space to download the speaker diarization models. Only \(freeMB) MB free — free up space and try again."
        case .unsupportedFormat(let sampleRate, let channels):
            return "Audio file is \(Int(sampleRate)) Hz / \(channels)ch — diarization requires 16 kHz mono."
        }
    }
}

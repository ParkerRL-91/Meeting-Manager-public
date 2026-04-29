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

    /// Load (and download if needed) the SpeakerKit CoreML models.
    /// Safe to call multiple times — no-ops if already loaded.
    func loadModels() async throws {
        guard modelState != .loaded else { return }

        modelState = .downloading
        logger.info("Loading SpeakerKit models...")

        do {
            let config = PyannoteConfig(
                download: true,
                load: true,
                verbose: false
            )
            speakerKit = try await SpeakerKit(config)
            modelState = .loaded
            logger.info("SpeakerKit models ready.")
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

        if modelState != .loaded {
            try await loadModels()
        }

        guard let kit = speakerKit else {
            throw DiarizationError.modelNotLoaded
        }

        logger.info("Diarizing \(systemAudioURL.lastPathComponent), speakers hint: \(participantCount.map(String.init) ?? "auto")")

        let samples = try loadAsSamples(url: systemAudioURL)
        guard !samples.isEmpty else {
            throw DiarizationError.emptyAudio
        }

        let options = PyannoteDiarizationOptions(
            numberOfSpeakers: participantCount,
            minActiveOffset: 0.5,
            useExclusiveReconciliation: true
        )

        let result = try await kit.diarize(
            audioArray: samples,
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
            guard let id = transcript.id,
                  (transcript.speakerLabel ?? "").lowercased() == "system" else { continue }

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

            mapping[id] = "Speaker \(speakerId)"
        }

        return mapping
    }

    // MARK: - Private

    /// Read a 16kHz mono Float32 WAV into a plain [Float] array.
    private func loadAsSamples(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!

        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return []
        }

        // Re-read with the explicit 16kHz mono format to handle any mismatch.
        let readFile = try AVAudioFile(forReading: url)
        try readFile.read(into: buffer)

        guard let channelData = buffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))
    }
}

// MARK: - Errors

enum DiarizationError: LocalizedError {
    case modelNotLoaded
    case audioFileNotFound(String)
    case emptyAudio

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "Speaker diarization model is not loaded."
        case .audioFileNotFound(let path):
            return "System audio file not found at \(path)."
        case .emptyAudio:
            return "System audio file is empty — nothing to diarize."
        }
    }
}

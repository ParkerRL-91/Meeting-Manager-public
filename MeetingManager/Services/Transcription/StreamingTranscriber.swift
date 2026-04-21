import Foundation
import os

/// Bridges the audio capture pipeline to the transcription engine.
/// Continuously pulls chunks from `AudioBufferManager`, feeds them to
/// `TranscriptionService`, and persists the resulting transcript segments
/// to the database via `TranscriptRepository`.
@Observable
final class StreamingTranscriber {
    // MARK: - Published State

    /// True while the transcription loop is running.
    private(set) var isActive = false

    /// Accumulated transcript segments for the current session.
    private(set) var segments: [Transcript] = []

    /// Running count of segments produced.
    private(set) var segmentCount: Int = 0

    /// The last error encountered during streaming transcription.
    private(set) var lastError: Error?

    // MARK: - Private

    private var processingTask: Task<Void, Never>?
    private let transcriptionService: TranscriptionService

    /// Interval between polls when no chunk is ready (seconds).
    private let pollInterval: Duration = .milliseconds(500)

    /// Maximum number of transcript segments kept in the in-memory array.
    /// Older segments are already persisted to the database via TranscriptRepository.
    private let maxInMemorySegments = 500

    // MARK: - Init

    init(transcriptionService: TranscriptionService) {
        self.transcriptionService = transcriptionService
    }

    // MARK: - Lifecycle

    /// Start the streaming transcription loop.
    ///
    /// Continuously polls `bufferManager` for audio chunks, transcribes them,
    /// maps results to `Transcript` records tagged with the correct speaker
    /// source, and persists them through `repository`.
    ///
    /// - Parameters:
    ///   - meetingId: The meeting these transcripts belong to.
    ///   - bufferManager: Source of audio chunks.
    ///   - repository: Database layer for persisting transcripts.
    @MainActor func start(
        meetingId: String,
        bufferManager: AudioBufferManager,
        repository: TranscriptRepository
    ) {
        AppFileLogger.shared.log("[StreamingTranscriber] start() called — isActive=\(isActive), modelLoaded=\(transcriptionService.isModelLoaded)")

        guard !isActive else {
            Logger.transcription.warning("StreamingTranscriber.start called while already active")
            return
        }
        guard transcriptionService.isModelLoaded else {
            Logger.transcription.error("Cannot start streaming: no model loaded")
            return
        }

        isActive = true
        segments = []
        segmentCount = 0
        lastError = nil

        processingTask = Task { [weak self] in
            guard let self else { return }

            Logger.transcription.info("Streaming transcription started for meeting \(meetingId)")

            var elapsedChunks = 0

            while !Task.isCancelled {
                // Wait for a chunk to become available
                guard bufferManager.hasChunkReady else {
                    try? await Task.sleep(for: self.pollInterval)
                    continue
                }

                guard let chunk = bufferManager.nextChunk() else {
                    try? await Task.sleep(for: self.pollInterval)
                    continue
                }

                // VAD gate: skip chunks that are mostly silence
                let rmsEnergy = Self.rmsEnergy(of: chunk.samples)
                if rmsEnergy < self.transcriptionService.configuration.vadEnergyThreshold {
                    Logger.transcription.debug(
                        "Skipping silent chunk (RMS: \(rmsEnergy, format: .fixed(precision: 4)))"
                    )
                    elapsedChunks += 1
                    continue
                }

                // Calculate time offsets for this chunk
                let chunkDuration = bufferManager.chunkDuration
                let chunkStartSeconds = Double(elapsedChunks) * (chunkDuration - bufferManager.chunkOverlap)
                elapsedChunks += 1

                // Transcribe
                do {
                    let txSegments = try await self.transcriptionService.transcribe(
                        samples: chunk.samples
                    )

                    guard !txSegments.isEmpty else { continue }

                    // Map to Transcript records, filtering out noise and hallucinations
                    let speakerLabel = Self.speakerLabel(for: chunk.source)
                    let transcripts = txSegments.compactMap { seg -> Transcript? in
                        let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)

                        // Filter out WhisperKit noise tokens
                        let noisePatterns = [
                            "[BLANK_AUDIO]", "[INAUDIBLE]", "[inaudible]", "[INAAUDIBLE]",
                            "[Music]", "[MUSIC]", "[ Inaudible ]", "[inautible]",
                            "(chuckles)", "(mumbles)", "[no audio]", "[audio cuts out]",
                            "[ Pause ]", "[", ">>", ""
                        ]
                        if noisePatterns.contains(where: { text.caseInsensitiveCompare($0) == .orderedSame })
                            || text.count <= 1
                            || text.hasPrefix("[") && text.hasSuffix("]")
                            || text.hasPrefix("(") && text.hasSuffix(")") {
                            return nil
                        }

                        // Filter out Whisper hallucinations
                        if text.hasPrefix(">> ") { return nil }  // fake "other speaker"

                        // Detect repetitive hallucinations: "1 2 2 2 2 2..." or "same 1, 10, s. same 1, 10, s."
                        // If the text is longer than 50 chars, check if any 5-char substring repeats 5+ times
                        if text.count > 50 {
                            let words = text.components(separatedBy: .whitespaces)
                            if words.count > 10 {
                                let uniqueWords = Set(words)
                                // If <20% of words are unique, it's repetitive hallucination
                                if Double(uniqueWords.count) / Double(words.count) < 0.2 {
                                    return nil
                                }
                            }
                        }

                        return Transcript(
                            meetingId: meetingId,
                            speakerLabel: speakerLabel,
                            text: text,
                            startTime: chunkStartSeconds + seg.startTime,
                            endTime: chunkStartSeconds + seg.endTime,
                            confidence: seg.confidence
                        )
                    }

                    // Deduplicate hallucinations without dropping legitimate repeats.
                    //
                    // WhisperKit occasionally emits the same segment text multiple times at
                    // the SAME time window (classic repetition artefact). Dropping those is
                    // the goal. But a speaker can also legitimately say "thank you" at 00:01,
                    // 00:15, and 00:30 — the old text-only dedup would delete all three as
                    // hallucinations. Group by (text, startTime-rounded-to-0.5s) instead:
                    // hallucinations share a bucket, legitimate repeats do not.
                    func dedupKey(for t: Transcript) -> String {
                        let bucket = Int((t.startTime * 2).rounded())
                        return "\(bucket)\u{1F}\(t.text)"  // \u{1F} is an ASCII unit separator
                    }
                    let keyCounts = Dictionary(grouping: transcripts, by: dedupKey).mapValues { $0.count }
                    let filteredTranscripts = transcripts.filter { (keyCounts[dedupKey(for: $0)] ?? 0) < 3 }

                    guard !filteredTranscripts.isEmpty else { continue }

                    // Persist to database
                    try await repository.saveBatch(filteredTranscripts)

                    // Batch all @Observable property updates in a single MainActor
                    // dispatch to avoid triggering multiple SwiftUI render passes.
                    let maxSegments = self.maxInMemorySegments
                    await MainActor.run {
                        self.segments.append(contentsOf: filteredTranscripts)
                        // Cap in-memory segments to prevent unbounded growth
                        // during long meetings. Older segments are already persisted
                        // to the database via TranscriptRepository.
                        if self.segments.count > maxSegments {
                            self.segments.removeFirst(self.segments.count - maxSegments)
                        }
                        self.segmentCount += filteredTranscripts.count
                    }

                    Logger.transcription.info(
                        "Saved \(filteredTranscripts.count) segment(s) at offset \(chunkStartSeconds, format: .fixed(precision: 1))s"
                    )
                } catch {
                    Logger.transcription.error(
                        "Transcription error: \(error.localizedDescription)"
                    )
                    await MainActor.run {
                        self.lastError = error
                    }
                    // Continue processing; transient errors should not kill the loop
                }
            }

            Logger.transcription.info("Streaming transcription ended for meeting \(meetingId). Total segments: \(self.segmentCount)")

            await MainActor.run {
                self.isActive = false
            }
        }
    }

    /// Stop the transcription loop. Cancels the task and waits for cleanup.
    func stop() async {
        guard isActive else { return }
        Logger.transcription.info("Stopping streaming transcription")
        processingTask?.cancel()
        await processingTask?.value
        processingTask = nil
        isActive = false
    }

    // MARK: - Helpers

    /// Map an `AudioSource` to the speaker label stored in the database.
    private static func speakerLabel(for source: AudioSource) -> String {
        switch source {
        case .microphone: return "mic"
        case .system: return "system"
        }
    }

    /// Compute the RMS energy of a sample buffer for VAD gating.
    private static func rmsEnergy(of samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sumOfSquares: Float = 0
        for sample in samples {
            sumOfSquares += sample * sample
        }
        return sqrtf(sumOfSquares / Float(samples.count))
    }
}

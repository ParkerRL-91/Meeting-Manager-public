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

                    // Map to Transcript records
                    let speakerLabel = Self.speakerLabel(for: chunk.source)
                    let transcripts = txSegments.map { seg in
                        Transcript(
                            meetingId: meetingId,
                            speakerLabel: speakerLabel,
                            text: seg.text,
                            startTime: chunkStartSeconds + seg.startTime,
                            endTime: chunkStartSeconds + seg.endTime,
                            confidence: seg.confidence
                        )
                    }

                    // Persist to database
                    try await repository.saveBatch(transcripts)

                    // Update local state on the main actor
                    await MainActor.run {
                        self.segments.append(contentsOf: transcripts)
                        self.segmentCount = self.segments.count
                    }

                    Logger.transcription.info(
                        "Saved \(transcripts.count) segment(s) at offset \(chunkStartSeconds, format: .fixed(precision: 1))s"
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

import Foundation

// MARK: - Whisper Model

/// The only supported WhisperKit model. Large v3 provides the best accuracy
/// and is the only model Meeting Manager ships with.
enum WhisperModel: String, CaseIterable, Identifiable, Codable {
    case largev3 = "openai_whisper-large-v3"

    var id: String { rawValue }

    var displayName: String { "Large v3" }

    /// Estimated peak memory usage in megabytes.
    var estimatedMemoryMB: Int { 3_000 }

    /// Human-readable download size.
    var downloadSizeDescription: String { "~1.5 GB" }
}

// MARK: - Transcription Mode

/// Indicates which transcription engine is active.
enum TranscriptionMode: String, Codable, Sendable {
    /// WhisperKit on-device model (preferred, highest accuracy).
    case whisperKit
    /// Apple SFSpeechRecognizer fallback (used when WhisperKit fails to load).
    case appleSpeech
    /// No transcription engine available.
    case none
}

// MARK: - Transcription Configuration

/// User-configurable settings for the transcription pipeline.
struct TranscriptionConfiguration: Codable, Equatable {

    // MARK: Model

    /// The WhisperKit model to use -- always large-v3.
    var model: WhisperModel = .largev3

    // MARK: Language

    /// BCP-47 language code. WhisperKit uses this as a hint.
    var language: String = "en"

    // MARK: Decoding -- accuracy controls

    /// Greedy decoding at temperature 0 is most accurate and deterministic.
    /// Falls back to sampling only when model confidence is very low.
    var temperature: Float = 0.0

    /// Number of times to retry with higher temperature before giving up.
    var temperatureFallbackCount: Int = 3

    // MARK: Decoding -- hallucination guards

    /// Suppress the blank token. Eliminates long stretches of empty output.
    var suppressBlank: Bool = true

    /// Discard segments where the probability of silence exceeds this threshold.
    /// Prevents the model from hallucinating speech during quiet passages.
    var noSpeechThreshold: Float = 0.6

    /// Discard segments whose average log-probability is below this value.
    /// Filters out low-confidence output before it reaches the transcript.
    var logProbThreshold: Float = -1.0

    /// If output compression ratio exceeds this, the segment is looping/repetitive.
    /// Discard and retry.
    var compressionRatioThreshold: Float = 2.4

    // MARK: Features

    /// Emit word-level timestamps. Required for future speaker attribution.
    var wordTimestamps: Bool = true

    // MARK: VAD

    /// Voice Activity Detection energy threshold (0.0 -- 1.0).
    /// Chunks whose RMS energy is below this value are skipped before
    /// hitting the model, saving inference time.
    var vadEnergyThreshold: Float = 0.001

    // MARK: Post-processing

    /// Minimum per-segment confidence to keep (0.0 -- 1.0).
    var minimumConfidence: Double = 0.3

    // MARK: Defaults

    static let `default` = TranscriptionConfiguration()
}

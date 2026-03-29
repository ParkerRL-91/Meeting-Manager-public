import Foundation

// MARK: - Whisper Model Selection

/// Available WhisperKit model variants.
/// Ordered from smallest/fastest to largest/most accurate.
/// For Meeting Manager, accuracy is the only priority — use large-v3.
enum WhisperModel: String, CaseIterable, Identifiable, Codable {
    case tinyEn    = "openai_whisper-tiny.en"
    case baseEn    = "openai_whisper-base.en"
    case smallEn   = "openai_whisper-small.en"
    case largev3   = "openai_whisper-large-v3"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .tinyEn:  return "Tiny (English)"
        case .baseEn:  return "Base (English)"
        case .smallEn: return "Small (English)"
        case .largev3: return "Large v3 (Most Accurate)"
        }
    }

    /// Estimated peak memory usage in megabytes.
    var estimatedMemoryMB: Int {
        switch self {
        case .tinyEn:  return 75
        case .baseEn:  return 150
        case .smallEn: return 500
        case .largev3: return 3_000
        }
    }

    /// Human-readable download size.
    var downloadSizeDescription: String {
        switch self {
        case .tinyEn:  return "~40 MB"
        case .baseEn:  return "~80 MB"
        case .smallEn: return "~250 MB"
        case .largev3: return "~1.5 GB"
        }
    }

    var memoryWarning: String? {
        switch self {
        case .smallEn:
            return "The Small model requires ~500 MB of memory. "
                + "On 8 GB machines this may cause slowdowns during recording."
        case .largev3:
            return "The Large v3 model requires ~3 GB of memory and ~1.5 GB of disk. "
                + "It provides the highest accuracy available."
        default:
            return nil
        }
    }
}

// MARK: - Transcription Configuration

/// User-configurable settings for the transcription pipeline.
struct TranscriptionConfiguration: Codable, Equatable {

    // MARK: Model

    /// The WhisperKit model to use. large-v3 gives the best accuracy.
    var model: WhisperModel = .largev3

    // MARK: Language

    /// BCP-47 language code. WhisperKit uses this as a hint.
    var language: String = "en"

    // MARK: Decoding — accuracy controls

    /// Greedy decoding at temperature 0 is most accurate and deterministic.
    /// Falls back to sampling only when model confidence is very low.
    var temperature: Float = 0.0

    /// Number of times to retry with higher temperature before giving up.
    var temperatureFallbackCount: Int = 3

    // MARK: Decoding — hallucination guards

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

    /// Voice Activity Detection energy threshold (0.0 – 1.0).
    /// Chunks whose RMS energy is below this value are skipped before
    /// hitting the model, saving inference time.
    var vadEnergyThreshold: Float = 0.001

    // MARK: Post-processing

    /// Minimum per-segment confidence to keep (0.0 – 1.0).
    var minimumConfidence: Double = 0.3

    // MARK: Defaults

    static let `default` = TranscriptionConfiguration()
}

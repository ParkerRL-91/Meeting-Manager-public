import Foundation

// MARK: - Whisper Model Selection

/// Available WhisperKit model variants optimized for on-device transcription.
enum WhisperModel: String, CaseIterable, Identifiable, Codable {
    case tinyEn = "openai_whisper-tiny.en"
    case baseEn = "openai_whisper-base.en"
    case smallEn = "openai_whisper-small.en"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .tinyEn: return "Tiny (English)"
        case .baseEn: return "Base (English)"
        case .smallEn: return "Small (English)"
        }
    }

    /// Estimated peak memory usage in megabytes.
    var estimatedMemoryMB: Int {
        switch self {
        case .tinyEn: return 75
        case .baseEn: return 150
        case .smallEn: return 500
        }
    }

    /// Human-readable download size.
    var downloadSizeDescription: String {
        switch self {
        case .tinyEn: return "~40 MB"
        case .baseEn: return "~80 MB"
        case .smallEn: return "~250 MB"
        }
    }

    /// Warning message for machines with limited memory, or nil if safe.
    var memoryWarning: String? {
        guard self == .smallEn else { return nil }
        return "The Small model requires ~500 MB of memory. "
            + "On 8 GB machines this may cause slowdowns during recording."
    }
}

// MARK: - Transcription Configuration

/// User-configurable settings for the transcription pipeline.
struct TranscriptionConfiguration: Codable, Equatable {
    /// The WhisperKit model to use.
    var model: WhisperModel = .tinyEn

    /// Language code for transcription (BCP-47). WhisperKit uses this as a hint.
    var language: String = "en"

    /// When true, segments that are blank or contain only silence are suppressed.
    var suppressBlank: Bool = true

    /// Voice Activity Detection energy threshold (0.0 – 1.0).
    /// Chunks whose RMS energy is below this value are skipped.
    var vadEnergyThreshold: Float = 0.001

    /// Minimum segment confidence to keep (0.0 – 1.0).
    /// Segments below this are discarded as low-quality.
    var minimumConfidence: Double = 0.3

    /// Temperature for WhisperKit decoding. Lower values produce more deterministic output.
    var temperature: Float = 0.0

    // MARK: - Defaults

    static let `default` = TranscriptionConfiguration()
}

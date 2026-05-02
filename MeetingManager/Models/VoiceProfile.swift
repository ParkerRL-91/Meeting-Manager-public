import Foundation
import GRDB

/// Persisted per-person voice fingerprint, built from MFCC features averaged
/// over confirmed speaker segments. Used by VoiceProfileService to recognise
/// known participants in future meetings before the LLM attribution step runs.
///
/// A new profile is created or merged after every meeting where a speaker is
/// successfully identified (either via LLM attribution or manual rename).
struct VoiceProfile: Codable, Identifiable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    /// Canonical display name of the person (e.g. "Alex Chen").
    var personName: String
    /// Stable identity FK — links this profile to a Person row so the profile
    /// survives renames and email-format drift. Populated by PersonRepository
    /// when a Person record is resolved for this name.
    var personId: String?
    /// Serialised [Float32] MFCC embedding, 40 dimensions, little-endian.
    var embeddingData: Data
    /// Number of meeting-level samples that contributed to this embedding.
    /// Used for exponential moving-average merging: newer meetings weight more.
    var sampleCount: Int
    /// v3.10 source-quality split. Profiles built only from LLM attributions
    /// (manualSampleCount == 0) are matched at a stricter threshold to avoid
    /// drift; manually confirmed profiles are matched aggressively.
    var manualSampleCount: Int = 0
    var llmSampleCount: Int = 0
    var lastUpdatedAt: Date

    static let databaseTableName = "voiceProfile"

    enum CodingKeys: String, CodingKey {
        case id, personName, personId, embeddingData, sampleCount, manualSampleCount, llmSampleCount, lastUpdatedAt
    }

    enum Columns {
        static let id                 = Column(CodingKeys.id)
        static let personName         = Column(CodingKeys.personName)
        static let personId           = Column(CodingKeys.personId)
        static let embeddingData      = Column(CodingKeys.embeddingData)
        static let sampleCount        = Column(CodingKeys.sampleCount)
        static let manualSampleCount  = Column(CodingKeys.manualSampleCount)
        static let llmSampleCount     = Column(CodingKeys.llmSampleCount)
        static let lastUpdatedAt      = Column(CodingKeys.lastUpdatedAt)
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    // MARK: - Embedding helpers

    var embedding: [Float] {
        get {
            embeddingData.withUnsafeBytes { ptr in
                guard let base = ptr.baseAddress else { return [] }
                let count = embeddingData.count / MemoryLayout<Float>.size
                return Array(UnsafeBufferPointer(
                    start: base.assumingMemoryBound(to: Float.self),
                    count: count
                ))
            }
        }
        set {
            embeddingData = newValue.withUnsafeBytes { Data($0) }
        }
    }

    static func makeEmpty(personName: String, personId: String? = nil) -> VoiceProfile {
        VoiceProfile(
            id: nil,
            personName: personName,
            personId: personId,
            embeddingData: Data(),
            sampleCount: 0,
            manualSampleCount: 0,
            llmSampleCount: 0,
            lastUpdatedAt: Date()
        )
    }

    /// Match threshold tuned to profile quality. Profiles whose only evidence
    /// comes from LLM attributions are matched stricter to avoid drift onto
    /// the wrong person. Profiles with at least one manual or voice-match
    /// confirmation use the standard threshold.
    var dynamicMatchThreshold: Float {
        if manualSampleCount == 0 && sampleCount > 0 {
            return 0.87
        }
        return 0.82
    }
}

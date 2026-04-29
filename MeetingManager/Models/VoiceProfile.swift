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
    /// Serialised [Float32] MFCC embedding, 40 dimensions, little-endian.
    var embeddingData: Data
    /// Number of meeting-level samples that contributed to this embedding.
    /// Used for exponential moving-average merging: newer meetings weight more.
    var sampleCount: Int
    var lastUpdatedAt: Date

    static let databaseTableName = "voiceProfile"

    enum CodingKeys: String, CodingKey {
        case id, personName, embeddingData, sampleCount, lastUpdatedAt
    }

    enum Columns {
        static let id            = Column(CodingKeys.id)
        static let personName    = Column(CodingKeys.personName)
        static let embeddingData = Column(CodingKeys.embeddingData)
        static let sampleCount   = Column(CodingKeys.sampleCount)
        static let lastUpdatedAt = Column(CodingKeys.lastUpdatedAt)
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

    static func makeEmpty(personName: String) -> VoiceProfile {
        VoiceProfile(
            id: nil,
            personName: personName,
            embeddingData: Data(),
            sampleCount: 0,
            lastUpdatedAt: Date()
        )
    }
}

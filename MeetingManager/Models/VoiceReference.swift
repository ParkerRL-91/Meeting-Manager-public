import Foundation
import GRDB

/// Per-person FluidAudio voice reference for cross-meeting speaker identity.
///
/// Unlike the v26 mel-spectrum `VoiceProfile` (40-dim, matched in-app via cosine
/// similarity), a `VoiceReference` holds a 256-dim wespeaker embedding that is
/// fed back to FluidAudio's clusterer via `DiarizerManager.initializeKnownSpeakers`.
/// FluidAudio then matches meeting clusters against the enrolled embeddings
/// internally and returns the reference's id on matching segments — so the
/// matching happens inside the diarizer, not in our code.
///
/// One row per `Person`. The reference is (re)built by `SpeakerEnrollmentService`
/// from that person's highest-confidence segment embeddings each time an
/// attribution is confirmed, so it improves over time. The stored `personId` is
/// also used as the FluidAudio `Speaker.id`, which is how a matched cluster is
/// mapped back to a Person (and thus a name).
struct VoiceReference: Codable, FetchableRecord, PersistableRecord {
    /// FK to the Person this voice belongs to. Primary key — one reference per
    /// person. Also used verbatim as the FluidAudio `Speaker.id` on enrollment.
    var personId: String
    /// Canonical display name at the time the reference was last built. Used for
    /// the FluidAudio `Speaker.name` and for logging; the live name is always
    /// re-resolved from the Person row before display.
    var personName: String
    /// Serialised [Float32] wespeaker embedding, 256 dimensions, little-endian.
    /// L2-normalized (FluidAudio normalizes on `Speaker` init regardless).
    var embeddingData: Data
    /// How many confirmed segments were aggregated into this embedding. Higher
    /// counts mean a more stable reference.
    var segmentCount: Int
    var updatedAt: Date

    static let databaseTableName = "voiceReference"

    enum CodingKeys: String, CodingKey {
        case personId, personName, embeddingData, segmentCount, updatedAt
    }

    enum Columns {
        static let personId      = Column(CodingKeys.personId)
        static let personName     = Column(CodingKeys.personName)
        static let embeddingData  = Column(CodingKeys.embeddingData)
        static let segmentCount   = Column(CodingKeys.segmentCount)
        static let updatedAt      = Column(CodingKeys.updatedAt)
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
}

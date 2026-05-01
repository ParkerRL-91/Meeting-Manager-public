import Foundation
import GRDB

/// A single per-utterance voice embedding captured during a meeting.
/// Unlike VoiceProfile (which stores one EMA centroid per person), VoiceSample
/// keeps individual fingerprints so we can:
///   - roll back bad attributions (delete samples from a specific meeting)
///   - detect anomalous samples that may indicate a contaminated profile
///   - rebuild the EMA centroid from scratch using only verified samples
struct VoiceSample: Codable, Identifiable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    /// FK to person.id — the confirmed identity for this sample.
    var personId: String
    /// Source meeting for provenance / rollback.
    var meetingId: String
    /// Transcript row boundaries this sample was extracted from (seconds).
    var startTime: Double
    var endTime: Double
    /// 40-dim mel-spectrum embedding matching VoiceProfile.embeddingData format.
    var embeddingData: Data
    /// Confidence of the attribution that confirmed this sample.
    /// "manual" = user renamed; "voice_match" = cosine sim; "llm" = LLM attribution.
    var source: String
    var createdAt: Date

    static let databaseTableName = "voiceSample"

    enum CodingKeys: String, CodingKey {
        case id, personId, meetingId, startTime, endTime, embeddingData, source, createdAt
    }

    enum Columns {
        static let id            = Column(CodingKeys.id)
        static let personId      = Column(CodingKeys.personId)
        static let meetingId     = Column(CodingKeys.meetingId)
        static let startTime     = Column(CodingKeys.startTime)
        static let endTime       = Column(CodingKeys.endTime)
        static let embeddingData = Column(CodingKeys.embeddingData)
        static let source        = Column(CodingKeys.source)
        static let createdAt     = Column(CodingKeys.createdAt)
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    // MARK: - Helpers

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
        set { embeddingData = newValue.withUnsafeBytes { Data($0) } }
    }
}

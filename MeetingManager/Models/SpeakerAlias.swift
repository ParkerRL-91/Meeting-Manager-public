import Foundation
import GRDB

/// User-confirmed speaker rename, scoped to a meeting series. Created when
/// the user clicks a speaker label in `FullTranscriptView` and picks a real
/// name; consumed by `SpeakerAttributionService` to pre-seed the LLM prompt
/// for the next meeting in the same series so accuracy compounds.
///
/// Uniqueness enforced at the DB layer on `(seriesKey, clusterId)` — see
/// migration v25-speaker-alias. The repository handles upsert semantics by
/// deleting any colliding row before insert.
struct SpeakerAlias: Codable, Identifiable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var seriesKey: String
    var clusterId: String
    var resolvedName: String
    var createdAt: Date

    static let databaseTableName = "speakerAlias"

    enum CodingKeys: String, CodingKey {
        case id, seriesKey, clusterId, resolvedName, createdAt
    }

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let seriesKey = Column(CodingKeys.seriesKey)
        static let clusterId = Column(CodingKeys.clusterId)
        static let resolvedName = Column(CodingKeys.resolvedName)
        static let createdAt = Column(CodingKeys.createdAt)
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

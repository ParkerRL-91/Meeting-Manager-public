import Foundation
import GRDB

struct Transcript: Identifiable, Codable, Equatable {
    var id: Int64?
    var meetingId: String
    var speakerLabel: String?
    var text: String
    var startTime: Double
    var endTime: Double
    var confidence: Double?
    var createdAt: Date

    init(
        id: Int64? = nil,
        meetingId: String,
        speakerLabel: String? = nil,
        text: String,
        startTime: Double,
        endTime: Double,
        confidence: Double? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.meetingId = meetingId
        self.speakerLabel = speakerLabel
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.confidence = confidence
        self.createdAt = createdAt
    }

    var isMicrophone: Bool {
        speakerLabel == "mic"
    }

    var formattedTimestamp: String {
        let minutes = Int(startTime / 60)
        let seconds = Int(startTime.truncatingRemainder(dividingBy: 60))
        return String(format: "%02d:%02d", minutes, seconds)
    }

    var speakerDisplayName: String {
        switch speakerLabel {
        case "mic": return "You"
        case "system": return "Them"
        default: return speakerLabel ?? "Unknown"
        }
    }
}

// MARK: - GRDB

extension Transcript: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "transcript"

    enum Columns: String, ColumnExpression {
        case id, meetingId, speakerLabel, text, startTime, endTime, confidence, createdAt
    }

    /// WhisperKit occasionally re-emits the same segment at the same timestamps
    /// across chunk boundaries. With the unique index idx_transcript_unique_time
    /// (added in v21 migration), a second INSERT of the same (meetingId, startTime,
    /// endTime) triple would throw a constraint violation and break the batch.
    /// Use INSERT OR IGNORE so duplicates are silently dropped at the DB layer —
    /// the caller's batch save cannot be aborted by a single duplicate.
    static let persistenceConflictPolicy = PersistenceConflictPolicy(insert: .ignore)

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

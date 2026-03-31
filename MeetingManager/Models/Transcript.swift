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

extension Transcript: FetchableRecord, PersistableRecord {
    static let databaseTableName = "transcript"

    enum Columns: String, ColumnExpression {
        case id, meetingId, speakerLabel, text, startTime, endTime, confidence, createdAt
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

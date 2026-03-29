import Foundation
import GRDB

struct Meeting: Identifiable, Codable, Equatable {
    var id: String
    var title: String
    var startDate: Date?
    var endDate: Date?
    var scheduledStartDate: Date?
    var scheduledEndDate: Date?
    var status: MeetingStatus
    var calendarEventId: String?
    var audioFilePath: String?
    /// Comma-separated list of participant names/emails detected from calendar or speaker diarization.
    var participants: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: String = UUID().uuidString,
        title: String,
        startDate: Date? = nil,
        endDate: Date? = nil,
        scheduledStartDate: Date? = nil,
        scheduledEndDate: Date? = nil,
        status: MeetingStatus = .scheduled,
        calendarEventId: String? = nil,
        audioFilePath: String? = nil,
        participants: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.scheduledStartDate = scheduledStartDate
        self.scheduledEndDate = scheduledEndDate
        self.status = status
        self.calendarEventId = calendarEventId
        self.audioFilePath = audioFilePath
        self.participants = participants
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Parsed list of participant names.
    var participantList: [String] {
        participants?.components(separatedBy: ", ").filter { !$0.isEmpty } ?? []
    }

    var duration: TimeInterval? {
        guard let start = startDate, let end = endDate else { return nil }
        return end.timeIntervalSince(start)
    }

    var formattedDuration: String {
        guard let duration else { return "--" }
        let minutes = Int(duration / 60)
        if minutes < 60 {
            return "\(minutes) min"
        }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        return "\(hours)h \(remainingMinutes)m"
    }

    var effectiveDate: Date {
        scheduledStartDate ?? startDate ?? createdAt
    }
}

// MARK: - GRDB

extension Meeting: FetchableRecord, PersistableRecord {
    static let databaseTableName = "meeting"

    enum Columns: String, ColumnExpression {
        case id, title, startDate, endDate, scheduledStartDate, scheduledEndDate
        case status, calendarEventId, audioFilePath, participants, createdAt, updatedAt
    }

    mutating func willUpdate(_ db: Database) throws {
        updatedAt = Date()
    }
}

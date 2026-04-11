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
    /// All audio files recorded for this meeting. Each reopen session appends a new file.
    var audioFilePaths: [String]
    /// True for all-day calendar events — reopen and recording CTAs are suppressed.
    var isAllDay: Bool
    /// Comma-separated list of participant names/emails detected from calendar or speaker diarization.
    var participants: String?
    /// JSON cache of related past meetings (populated by contextEnrichment task).
    var contextJSON: String?
    /// Video call URL from Google Calendar (hangoutLink or conferenceData).
    var meetLink: String?
    /// Optional reference to a MeetingTemplate to pre-populate the notepad.
    var templateId: String?
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
        audioFilePaths: [String] = [],
        isAllDay: Bool = false,
        participants: String? = nil,
        contextJSON: String? = nil,
        meetLink: String? = nil,
        templateId: String? = nil,
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
        self.audioFilePaths = audioFilePaths
        self.isAllDay = isAllDay
        self.participants = participants
        self.contextJSON = contextJSON
        self.meetLink = meetLink
        self.templateId = templateId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // MARK: - Backward Compat

    /// First recorded audio file path. Nil if no recording exists yet.
    var audioFilePath: String? { audioFilePaths.first }

    // MARK: - Reopen Logic

    /// Whether this meeting can be re-opened to append more audio.
    ///
    /// True when:
    /// - status is `.complete` or `.cancelled` (crash recovery)
    /// - not an all-day meeting
    /// - current time is within the scheduled window OR within 60 min after scheduled end
    /// - cancelled meetings with a scheduled window still active are always reopenable
    var isReopenable: Bool {
        guard !isAllDay else { return false }
        guard status == .complete || status == .cancelled else { return false }
        let now = Date()
        // Cancelled meetings from a crash — if within scheduled window, always allow
        if status == .cancelled {
            if let start = scheduledStartDate, let end = scheduledEndDate {
                return now >= start && now <= end.addingTimeInterval(3600)
            }
            // Cancelled with no schedule — allow within 2 hours of creation (generous for crash recovery)
            return now <= createdAt.addingTimeInterval(7200)
        }
        if let start = scheduledStartDate, let end = scheduledEndDate {
            return now >= start && now <= end.addingTimeInterval(3600)
        }
        // No scheduled times — allow within 60 min of actual end
        if let end = endDate {
            return now <= end.addingTimeInterval(3600)
        }
        return false
    }

    // MARK: - Derived

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

    /// For completed/recorded meetings, prefer the actual start time over
    /// the calendar-scheduled time (which may be midnight for all-day events).
    var effectiveDate: Date {
        switch status {
        case .recording, .transcribing, .summarizing, .complete, .archived:
            return startDate ?? scheduledStartDate ?? createdAt
        default:
            return scheduledStartDate ?? startDate ?? createdAt
        }
    }
}

// MARK: - GRDB

extension Meeting: FetchableRecord, PersistableRecord {
    static let databaseTableName = "meeting"

    enum Columns: String, ColumnExpression {
        case id, title, startDate, endDate, scheduledStartDate, scheduledEndDate
        case status, calendarEventId, audioFilePaths, isAllDay, participants, contextJSON, meetLink, templateId, createdAt, updatedAt
    }

    mutating func willUpdate(_ db: Database) throws {
        updatedAt = Date()
    }
}

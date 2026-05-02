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
    /// JSON-encoded `[clusterId: name]` dictionary persisted by Layer 2
    /// speaker attribution (e.g. `{"Speaker 1": "Alex Chen"}`). NULL when no
    /// attribution ran or attribution returned empty. Used by Layer 3 to
    /// pre-seed the LLM prompt for recurring meetings.
    var speakerMap: String?
    /// v3.10 RSVP gate: comma-separated list of attendee names who explicitly
    /// declined the calendar invite. Filtered out of the attribution candidate
    /// pool and excluded from the diarization speaker-count hint.
    var declinedAttendees: String?
    /// v3.10 confidence scores: JSON `[clusterId: confidence]` for each
    /// attribution decision. Lets the UI badge low-confidence labels for
    /// review without retraining the user to interpret them.
    var speakerConfidenceMap: String?
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
        speakerMap: String? = nil,
        declinedAttendees: String? = nil,
        speakerConfidenceMap: String? = nil,
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
        self.speakerMap = speakerMap
        self.declinedAttendees = declinedAttendees
        self.speakerConfidenceMap = speakerConfidenceMap
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // MARK: - Speaker Map (v3.1 Layer 2)

    /// Decoded cluster -> name dictionary. Returns an empty dict when the
    /// column is NULL or contains non-JSON garbage; callers should treat
    /// empty as "no attribution available".
    var speakerMapDictionary: [String: String] {
        guard let json = speakerMap?.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: String].self, from: json) else {
            return [:]
        }
        return decoded
    }

    /// Persist a cluster -> name mapping. Empty dict clears the column to
    /// NULL so future reads see "no attribution" rather than an empty JSON
    /// object.
    mutating func setSpeakerMap(_ map: [String: String]) {
        if map.isEmpty {
            speakerMap = nil
        } else if let data = try? JSONEncoder().encode(map),
                  let str = String(data: data, encoding: .utf8) {
            speakerMap = str
        }
    }

    // MARK: - Confidence Map (v3.10)

    /// Decoded `[clusterId: confidence]` dict. Confidence is a float in [0, 1]
    /// where higher is more trustworthy. Empty when no attribution has run or
    /// the column is NULL.
    var speakerConfidenceMapDictionary: [String: Float] {
        guard let json = speakerConfidenceMap?.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: Float].self, from: json) else {
            return [:]
        }
        return decoded
    }

    /// Persist a per-cluster confidence map. Empty dict clears the column.
    mutating func setSpeakerConfidenceMap(_ map: [String: Float]) {
        if map.isEmpty {
            speakerConfidenceMap = nil
        } else if let data = try? JSONEncoder().encode(map),
                  let str = String(data: data, encoding: .utf8) {
            speakerConfidenceMap = str
        }
    }

    // MARK: - RSVP Gate (v3.10)

    /// Parsed list of attendee names who declined the calendar invite.
    var declinedAttendeeList: [String] {
        declinedAttendees?.components(separatedBy: ", ").filter { !$0.isEmpty } ?? []
    }

    /// `participantList` minus anyone who declined the invite. This is the
    /// "real" candidate pool for speaker attribution and the speaker-count
    /// hint passed to diarization. We use case-insensitive substring matching
    /// because raw participant strings may be email-suffixed while the
    /// declined list is name-only (or vice versa).
    var acceptedParticipantList: [String] {
        let declined = declinedAttendeeList.map { $0.lowercased() }
        guard !declined.isEmpty else { return participantList }
        return participantList.filter { name in
            let lower = name.lowercased()
            return !declined.contains(where: { d in
                lower.contains(d) || d.contains(lower)
            })
        }
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
        case status, calendarEventId, audioFilePaths, isAllDay, participants, contextJSON, meetLink, templateId, speakerMap, declinedAttendees, speakerConfidenceMap, createdAt, updatedAt
    }

    mutating func willUpdate(_ db: Database) throws {
        updatedAt = Date()
    }
}

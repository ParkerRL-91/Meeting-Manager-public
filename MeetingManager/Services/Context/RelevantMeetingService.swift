import Foundation
import GRDB

/// Finds past meetings related to a given meeting based on participant overlap or title similarity.
/// Results are cached as JSON in `Meeting.contextJSON`.
final class RelevantMeetingService {
    private let database: AppDatabase

    init(database: AppDatabase = .shared) {
        self.database = database
    }

    // MARK: - Public

    /// Find and cache relevant past meetings for the given meeting.
    /// Writes results to `meeting.contextJSON` in the database.
    func enrichContext(meetingId: String) async throws {
        // Load the target meeting
        guard let meeting = try await database.writer.read({ db in
            try Meeting.fetchOne(db, key: meetingId)
        }) else { return }

        // Skip if context already cached
        if meeting.contextJSON != nil && !meeting.contextJSON!.isEmpty { return }

        let related = try await findRelated(for: meeting)

        // Serialize and save
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let jsonData = try encoder.encode(related)
        let jsonString = String(data: jsonData, encoding: .utf8)

        try await database.writer.write { db in
            var m = try Meeting.fetchOne(db, key: meetingId)
            m?.contextJSON = jsonString
            try m?.update(db)
        }
    }

    /// Parse cached context JSON back into `RelevantMeeting` array.
    static func parseContext(from jsonString: String?) -> [RelevantMeeting] {
        guard let jsonString, !jsonString.isEmpty,
              let data = jsonString.data(using: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([RelevantMeeting].self, from: data)) ?? []
    }

    // MARK: - Private

    private func findRelated(for meeting: Meeting) async throws -> [RelevantMeeting] {
        let participants = meeting.participantList
        let titleWords = meeting.title
            .components(separatedBy: .alphanumerics.inverted)
            .filter { $0.count >= 3 }
            .map { $0.lowercased() }

        // Fetch all completed past meetings (excluding self)
        let pastMeetings: [Meeting] = try await database.writer.read { db in
            try Meeting
                .filter(Meeting.Columns.id != meeting.id)
                .filter(Meeting.Columns.status == MeetingStatus.complete.rawValue)
                .order(Meeting.Columns.startDate.desc)
                .limit(200)
                .fetchAll(db)
        }

        // Fetch summaries for these meetings (batch)
        let meetingIds = pastMeetings.map(\.id)
        let summaries: [String: String] = try await database.writer.read { db in
            var result: [String: String] = [:]
            for id in meetingIds {
                if let summary = try MeetingSummary
                    .filter(Column("meetingId") == id)
                    .order(Column("createdAt").desc)
                    .fetchOne(db) {
                    result[id] = summary.summaryText
                }
            }
            return result
        }

        // Score each past meeting by relevance
        var scored: [(meeting: Meeting, score: Int)] = []

        for past in pastMeetings {
            var score = 0
            let pastParticipants = past.participantList

            // Participant overlap (3 points per shared participant)
            let overlap = Set(participants).intersection(Set(pastParticipants)).count
            score += overlap * 3

            // Title word overlap (1 point per shared word)
            let pastTitleWords = past.title
                .components(separatedBy: .alphanumerics.inverted)
                .filter { $0.count >= 3 }
                .map { $0.lowercased() }
            let wordOverlap = Set(titleWords).intersection(Set(pastTitleWords)).count
            score += wordOverlap

            if score > 0 {
                scored.append((past, score))
            }
        }

        // Sort by score descending, then recency
        scored.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            return (a.meeting.startDate ?? a.meeting.createdAt) > (b.meeting.startDate ?? b.meeting.createdAt)
        }

        // Take top 5 and build result
        return Array(scored.prefix(5)).map { item in
            let summaryText = summaries[item.meeting.id]
            let excerpt = Self.extractExcerpt(from: summaryText)
            return RelevantMeeting(
                meetingId: item.meeting.id,
                title: item.meeting.title,
                date: item.meeting.effectiveDate,
                summaryExcerpt: excerpt
            )
        }
    }

    /// Extract first 2 sentences from a summary as an excerpt.
    private static func extractExcerpt(from text: String?) -> String {
        guard let text, !text.isEmpty else { return "No summary available" }

        // Split by sentence-ending punctuation
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var sentences: [String] = []
        var current = ""
        for char in clean {
            current.append(char)
            if char == "." || char == "!" || char == "?" {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    sentences.append(trimmed)
                }
                current = ""
                if sentences.count >= 2 { break }
            }
        }
        // If no sentence-ending punctuation found, just take first 150 chars
        if sentences.isEmpty {
            return String(clean.prefix(150)) + (clean.count > 150 ? "..." : "")
        }
        return sentences.joined(separator: " ")
    }
}

// MARK: - Model

struct RelevantMeeting: Codable, Identifiable {
    var id: String { meetingId }
    let meetingId: String
    let title: String
    let date: Date
    let summaryExcerpt: String
}

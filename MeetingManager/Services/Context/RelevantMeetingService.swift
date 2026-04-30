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
        let participants = Set(meeting.participantList)
        let titleWords = Self.keywords(from: meeting.title)
        let now = Date()

        // Fetch all completed past meetings (excluding self)
        let pastMeetings: [Meeting] = try await database.writer.read { db in
            try Meeting
                .filter(Meeting.Columns.id != meeting.id)
                .filter(Meeting.Columns.status == MeetingStatus.complete.rawValue)
                .order(Meeting.Columns.startDate.desc)
                .limit(200)
                .fetchAll(db)
        }

        let meetingIds = pastMeetings.map(\.id)

        // Batch-fetch summaries, notes, and FTS-matching transcript meeting IDs in
        // three reads so we don't issue 200+ queries per enrichment.
        let summaries: [String: String] = try await database.writer.read { db in
            var result: [String: String] = [:]
            for id in meetingIds {
                if let summary = try MeetingSummary
                    .filter(Column("meetingId") == id)
                    .order(Column("generatedAt").desc)
                    .fetchOne(db) {
                    result[id] = summary.summaryText
                }
            }
            return result
        }

        let notesByMeeting: [String: String] = try await database.writer.read { db in
            var result: [String: String] = [:]
            for id in meetingIds {
                let combined = try MeetingNote
                    .filter(Column("meetingId") == id)
                    .fetchAll(db)
                    .map(\.content)
                    .joined(separator: " ")
                if !combined.isEmpty { result[id] = combined.lowercased() }
            }
            return result
        }

        // FTS lookup: which past meetings have transcripts mentioning the title words?
        // Returns a set of meeting IDs whose transcripts hit at least one title token.
        let transcriptHits: Set<String> = await Self.transcriptHits(
            meetingIds: meetingIds,
            keywords: titleWords,
            in: database
        )

        // Score each past meeting
        var scored: [(meeting: Meeting, score: Double)] = []

        for past in pastMeetings {
            var score: Double = 0
            let pastParticipants = Set(past.participantList)

            // Participant overlap (3 pts per shared person)
            let participantOverlap = participants.intersection(pastParticipants).count
            score += Double(participantOverlap) * 3.0

            // Title word overlap (1 pt per shared keyword)
            let pastTitleWords = Self.keywords(from: past.title)
            let titleOverlap = titleWords.intersection(pastTitleWords).count
            score += Double(titleOverlap)

            // Notes content match (0.5 pt per matching keyword, capped at 3 pts)
            if let notes = notesByMeeting[past.id], !titleWords.isEmpty {
                let noteHits = titleWords.filter { notes.contains($0) }.count
                score += min(Double(noteHits) * 0.5, 3.0)
            }

            // Transcript FTS hit (2 pt flat — past meeting actually discussed the topic)
            if transcriptHits.contains(past.id) { score += 2.0 }

            // Recency decay: full weight ≤ 30 days, half at 90, quarter at 180,
            // floor 0.1 beyond 1 year. Multiplies the relevance score so a stale
            // exact match doesn't outrank a recent fuzzy match.
            let pastDate = past.startDate ?? past.scheduledStartDate ?? past.createdAt
            let ageDays = max(0, now.timeIntervalSince(pastDate) / 86_400)
            let recency: Double
            switch ageDays {
            case ..<30:    recency = 1.0
            case ..<90:    recency = 0.7
            case ..<180:   recency = 0.5
            case ..<365:   recency = 0.3
            default:       recency = 0.1
            }
            score *= recency

            if score > 0 {
                scored.append((past, score))
            }
        }

        // Sort by score descending, then recency
        scored.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            return (a.meeting.startDate ?? a.meeting.createdAt) > (b.meeting.startDate ?? b.meeting.createdAt)
        }

        return Array(scored.prefix(5)).map { item in
            let excerpt = Self.extractExcerpt(from: summaries[item.meeting.id])
            return RelevantMeeting(
                meetingId: item.meeting.id,
                title: item.meeting.title,
                date: item.meeting.effectiveDate,
                summaryExcerpt: excerpt
            )
        }
    }

    /// Tokenise free text into a deduped set of lowercase keywords ≥ 3 chars,
    /// minus a small stoplist of words that produce noise in the overlap score.
    private static func keywords(from text: String) -> Set<String> {
        let stopwords: Set<String> = [
            "the", "and", "for", "with", "from", "this", "that", "into",
            "about", "after", "before", "meeting", "call", "sync", "discussion",
            "weekly", "monthly", "daily", "team", "review"
        ]
        return Set(
            text.components(separatedBy: .alphanumerics.inverted)
                .filter { $0.count >= 3 }
                .map { $0.lowercased() }
                .filter { !stopwords.contains($0) }
        )
    }

    /// Find meeting IDs whose transcripts match any of the given keywords via FTS5.
    /// Returns an empty set on empty keywords or query failure (FTS is best-effort).
    private static func transcriptHits(
        meetingIds: [String],
        keywords: Set<String>,
        in database: AppDatabase
    ) async -> Set<String> {
        guard !meetingIds.isEmpty, !keywords.isEmpty else { return [] }
        let pattern = keywords
            .map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"" }
            .joined(separator: " OR ")
        guard let result: Set<String> = try? await database.writer.read({ db in
            let placeholders = meetingIds.map { _ in "?" }.joined(separator: ",")
            let sql = """
                SELECT DISTINCT transcript.meetingId FROM transcript
                JOIN transcript_fts ON transcript.rowid = transcript_fts.rowid
                WHERE transcript_fts MATCH ? AND transcript.meetingId IN (\(placeholders))
                """
            var args: [DatabaseValueConvertible] = [pattern]
            args.append(contentsOf: meetingIds)
            let rows = try String.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            return Set(rows)
        }) else { return [] }
        return result
    }

    /// Extract the most substantive excerpt from a summary. Prefers the TL;DR
    /// section if present; otherwise falls back to the first 2 sentences.
    /// Strips Markdown headings and bullet markers.
    private static func extractExcerpt(from text: String?) -> String {
        guard let text, !text.isEmpty else { return "No summary available" }

        // If the summary uses our TL;DR convention, lift that section verbatim —
        // it's the single best one-shot context for a prep card.
        if let tldr = Self.section(named: "TL;DR", in: text) ?? Self.section(named: "Summary", in: text) {
            return Self.truncate(tldr, max: 280)
        }

        // Otherwise, take the first 2 prose sentences from the body.
        let clean = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"^#+\s.*$"#, with: "", options: [.regularExpression])
            .replacingOccurrences(of: #"^[\-\*]\s"#, with: "", options: [.regularExpression])

        var sentences: [String] = []
        var current = ""
        for char in clean {
            current.append(char)
            if char == "." || char == "!" || char == "?" {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { sentences.append(trimmed) }
                current = ""
                if sentences.count >= 2 { break }
            }
        }
        if sentences.isEmpty {
            return Self.truncate(clean, max: 200)
        }
        return Self.truncate(sentences.joined(separator: " "), max: 280)
    }

    /// Lift a Markdown section by heading name, returning the body text up to
    /// the next heading. Case-insensitive on the heading title.
    private static func section(named name: String, in text: String) -> String? {
        let lines = text.components(separatedBy: .newlines)
        var capture = false
        var collected: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isHeading = trimmed.hasPrefix("#")
            if isHeading {
                if capture { break }
                let stripped = trimmed
                    .replacingOccurrences(of: #"^#+\s*"#, with: "", options: [.regularExpression])
                if stripped.lowercased() == name.lowercased() { capture = true; continue }
            } else if capture, !trimmed.isEmpty {
                collected.append(trimmed)
            }
        }
        guard !collected.isEmpty else { return nil }
        return collected.joined(separator: " ")
    }

    private static func truncate(_ s: String, max: Int) -> String {
        s.count <= max ? s : String(s.prefix(max)) + "…"
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

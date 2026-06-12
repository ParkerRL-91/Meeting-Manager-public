import Foundation
import GRDB

// MARK: - MeetingIntent (TASK-065, migration v53)

/// What the user needs from a meeting, jotted beforehand; scored against
/// the summary afterward. The score answers "did you get what you came
/// for" — never who's to blame (plan risk note on tone).
struct MeetingIntent: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "meetingIntent"

    var meetingId: String
    var intent: String
    var outcomeScore: String?      // met | partial | not | unclear
    var outcomeNote: String?
    var createdAt: Date
    var scoredAt: Date?

    var id: String { meetingId }
}

final class MeetingIntentRepository {
    private let database: AppDatabase
    init(database: AppDatabase) { self.database = database }

    func find(meetingId: String) async throws -> MeetingIntent? {
        try await database.writer.read { db in
            try MeetingIntent.fetchOne(db, key: meetingId)
        }
    }

    func save(_ intent: MeetingIntent) async throws {
        try await database.writer.write { db in try intent.save(db) }
    }

    func delete(meetingId: String) async throws {
        _ = try await database.writer.write { db in
            try MeetingIntent.deleteOne(db, key: meetingId)
        }
    }

    func intents(meetingIds: [String]) async throws -> [MeetingIntent] {
        guard !meetingIds.isEmpty else { return [] }
        return try await database.writer.read { db in
            try MeetingIntent.filter(keys: meetingIds).fetchAll(db)
        }
    }
}

// MARK: - Scoring

enum IntentScoring {

    static let schemaJSON = """
    {"type":"object","properties":{"score":{"type":"string","enum":["met","partial","not","unclear"]},"note":{"type":"string"}},"required":["score","note"]}
    """

    static let systemPrompt = """
    Before this meeting the user wrote down what they needed from it. \
    Compare that intent against the meeting summary and answer ONE \
    question: did the user get what they came for? Score "met" when the \
    summary shows the need was addressed, "partial" when some of it was, \
    "not" when the summary shows it wasn't touched, and "unclear" when \
    the summary doesn't say either way. The note is ONE sentence, \
    factual and neutral — describe what happened to the need, never \
    assign blame or judge anyone's performance. Return ONLY JSON \
    matching the requested shape.
    """

    static func userPrompt(intent: String, summary: String) -> String {
        "What the user needed:\n\(intent)\n\nMeeting summary:\n\(String(summary.prefix(6000)))"
    }

    struct Payload: Decodable { let score: String; let note: String }

    static func parse(_ response: String) -> Payload? {
        guard let start = response.firstIndex(of: "{"),
              let end = response.lastIndex(of: "}") else { return nil }
        let payload = try? JSONDecoder().decode(Payload.self,
                                                from: Data(String(response[start...end]).utf8))
        guard let payload,
              ["met", "partial", "not", "unclear"].contains(payload.score) else { return nil }
        return payload
    }

    /// Display strings — "did you get what you came for" framing.
    static func label(for score: String) -> String {
        switch score {
        case "met": return "Got it"
        case "partial": return "Partly"
        case "not": return "Not this time"
        default: return "Unclear"
        }
    }
}

// MARK: - Folder ROI stats (TASK-065, pure)

enum MeetingROI {

    struct FolderStats: Equatable {
        let decisionCount: Int
        let totalHours: Double
        let intentsSet: Int
        let intentsMet: Int       // met
        let intentsPartial: Int

        /// nil when under an hour of recorded time — a rate over minutes
        /// is noise, not signal.
        var decisionsPerHour: Double? {
            totalHours >= 1.0 ? Double(decisionCount) / totalHours : nil
        }
        var hitRate: Double? {
            intentsSet > 0 ? Double(intentsMet) / Double(intentsSet) : nil
        }
    }

    static func folderStats(meetings: [Meeting],
                            decisionFacts: [EntityFact],
                            intents: [MeetingIntent]) -> FolderStats {
        let ids = Set(meetings.map(\.id))
        let decisions = Set(decisionFacts
            .filter { $0.kind == "decision" && ids.contains($0.meetingId) }
            .map { "\($0.meetingId)|\($0.text)" })
        let hours = meetings.compactMap(\.duration).reduce(0, +) / 3600
        let scored = intents.filter { ids.contains($0.meetingId) && $0.outcomeScore != nil }
        return FolderStats(
            decisionCount: decisions.count,
            totalHours: hours,
            intentsSet: scored.count,
            intentsMet: scored.filter { $0.outcomeScore == "met" }.count,
            intentsPartial: scored.filter { $0.outcomeScore == "partial" }.count)
    }
}

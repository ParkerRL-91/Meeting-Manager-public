import Foundation
import GRDB

// MARK: - MeetingSentiment (TASK-079, migration v57)

/// A coarse, neutral tone read for a meeting or one speaker. Deterministic
/// lexicon baseline (no model, no network); an optional local-LLM pass may
/// refine the label later. Presented as an observation, never a judgment
/// (the RelationshipHealth precedent). Derived data — regeneration
/// replaces a meeting's rows.
struct MeetingSentiment: Codable, FetchableRecord, MutablePersistableRecord, Identifiable {
    static let databaseTableName = "meetingSentiment"

    var id: Int64?
    var meetingId: String
    var scope: String        // "meeting" | "speaker"
    var speakerKey: String?
    var label: String        // positive | neutral | negative | mixed
    var polarity: Double     // [-1, +1]
    var magnitude: Double    // 0...1 coverage/confidence
    var method: String       // "lexicon" | "llm"
    var note: String?
    var computedAt: Date

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    /// Neutral display label — "did this read positive/negative", never a
    /// verdict on a person.
    var displayLabel: String {
        switch label {
        case "positive": return "Leaned positive"
        case "negative": return "Leaned negative"
        case "mixed": return "Mixed"
        default: return "Neutral"
        }
    }

    var icon: String {
        switch label {
        case "positive": return "face.smiling"
        case "negative": return "cloud"
        case "mixed": return "circle.lefthalf.filled"
        default: return "minus.circle"
        }
    }
}

final class SentimentRepository {
    private let database: AppDatabase
    init(database: AppDatabase) { self.database = database }

    func sentiment(meetingId: String) async throws -> [MeetingSentiment] {
        try await database.writer.read { db in
            try MeetingSentiment.filter(Column("meetingId") == meetingId).fetchAll(db)
        }
    }

    func replaceForMeeting(_ meetingId: String, with rows: [MeetingSentiment]) async throws {
        try await database.writer.write { db in
            try db.execute(sql: "DELETE FROM meetingSentiment WHERE meetingId = ?", arguments: [meetingId])
            for var r in rows { try r.insert(db) }
        }
    }

    func unprocessedMeetingIds() async throws -> [String] {
        try await database.writer.read { db in
            try String.fetchAll(db, sql: """
                SELECT DISTINCT meetingId FROM transcript
                WHERE meetingId NOT IN (SELECT DISTINCT meetingId FROM meetingSentiment)
                """)
        }
    }
}

// MARK: - Lexicon scorer (pure, tested)

/// Coarse polarity from a small AFINN-style lexicon with negation +
/// intensifier handling. English only; non-English text yields low
/// magnitude → neutral (the honest fallback). Deterministic and offline.
enum SentimentLexicon {

    /// Dead-zone: |polarity| below this is neutral, so near-zero scores
    /// don't flip-flop between meetings.
    static let neutralBand = 0.15

    static let positiveWords: [String: Double] = [
        "great": 2, "good": 1, "excellent": 3, "agree": 2, "agreed": 2, "yes": 1,
        "love": 3, "happy": 2, "glad": 2, "win": 2, "wins": 2, "success": 2,
        "successful": 2, "excited": 2, "perfect": 3, "thanks": 1, "thank": 1,
        "appreciate": 2, "wonderful": 3, "nice": 1, "helpful": 2, "resolved": 2,
        "solved": 2, "progress": 1, "confident": 2, "strong": 1, "clear": 1,
        "aligned": 2, "support": 1, "approve": 2, "approved": 2, "fantastic": 3,
    ]
    static let negativeWords: [String: Double] = [
        "bad": -2, "terrible": -3, "awful": -3, "no": -1, "disagree": -2,
        "concern": -2, "concerned": -2, "worried": -2, "worry": -2, "problem": -2,
        "problems": -2, "issue": -1, "issues": -1, "blocked": -2, "blocker": -2,
        "fail": -2, "failed": -2, "failure": -2, "risk": -1, "risks": -1,
        "confused": -2, "confusing": -2, "frustrated": -3, "frustrating": -3,
        "angry": -3, "delay": -2, "delayed": -2, "wrong": -2, "broken": -2,
        "unclear": -1, "difficult": -1, "hard": -1, "stuck": -2, "disappointed": -3,
        "unfortunately": -1, "cannot": -1, "won't": -1, "doesn't": -1,
    ]
    static let negators: Set<String> = ["not", "no", "never", "n't", "without", "hardly", "barely"]
    static let intensifiers: Set<String> = ["very", "really", "extremely", "so", "totally", "absolutely", "incredibly"]

    struct Score: Equatable {
        let polarity: Double     // [-1, +1]
        let magnitude: Double    // 0...1 (fraction of tokens that carried valence)
        let label: String
    }

    static func score(_ text: String) -> Score {
        let tokens = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return Score(polarity: 0, magnitude: 0, label: "neutral") }

        var sum = 0.0
        var hits = 0
        for (i, tok) in tokens.enumerated() {
            var v = positiveWords[tok] ?? negativeWords[tok] ?? 0
            guard v != 0 else { continue }
            // Look back up to two tokens for a negator / intensifier.
            let prev = i > 0 ? tokens[i - 1] : ""
            let prev2 = i > 1 ? tokens[i - 2] : ""
            if negators.contains(prev) || negators.contains(prev2) { v = -v }
            if intensifiers.contains(prev) { v *= 1.5 }
            sum += v
            hits += 1
        }
        guard hits > 0 else { return Score(polarity: 0, magnitude: 0, label: "neutral") }

        // Normalize: average valence per scoring token, squashed to [-1,1].
        let avg = sum / Double(hits)
        let polarity = max(-1, min(1, avg / 3.0))
        let magnitude = min(1, Double(hits) / Double(max(tokens.count, 1)) * 8)
        let label: String = abs(polarity) < neutralBand ? "neutral" : (polarity > 0 ? "positive" : "negative")
        return Score(polarity: polarity, magnitude: magnitude, label: label)
    }

    /// Meeting label from per-speaker scores: "mixed" when speakers
    /// genuinely diverge (one clearly positive, another clearly negative).
    static func meetingLabel(speakerPolarities: [Double], overall: String) -> String {
        let hasPos = speakerPolarities.contains { $0 > neutralBand }
        let hasNeg = speakerPolarities.contains { $0 < -neutralBand }
        return (hasPos && hasNeg) ? "mixed" : overall
    }
}

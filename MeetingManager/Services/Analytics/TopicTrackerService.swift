import Foundation
import GRDB

// MARK: - Models (TASK-081, migration v58)

/// A user-defined topic counted across meetings. `hiddenAt` is a delete
/// tombstone (like glossaryTerm) so a removed tracker is never re-mined.
struct TopicTracker: Codable, FetchableRecord, MutablePersistableRecord, Identifiable {
    static let databaseTableName = "topicTracker"

    var id: Int64?
    var name: String
    var keywords: String        // JSON array of phrases
    var semanticSeed: String?
    var createdAt: Date
    var hiddenAt: Date?

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    var keywordList: [String] {
        (try? JSONDecoder().decode([String].self, from: Data(keywords.utf8))) ?? []
    }
    static func encode(keywords: [String]) -> String {
        (try? String(data: JSONEncoder().encode(keywords), encoding: .utf8)) ?? "[]"
    }
}

/// One occurrence of a tracked topic in a meeting (one per meeting, by
/// default — the meeting is the unit of "came up").
struct TopicTrackerHit: Codable, FetchableRecord, MutablePersistableRecord, Identifiable {
    static let databaseTableName = "topicTrackerHit"

    var id: Int64?
    var trackerId: Int64
    var meetingId: String
    var atSeconds: Double?
    var snippet: String
    var matchType: String       // "keyword" | "semantic"
    var createdAt: Date

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

final class TopicTrackerRepository {
    private let database: AppDatabase
    init(database: AppDatabase) { self.database = database }

    func activeTrackers() async throws -> [TopicTracker] {
        try await database.writer.read { db in
            try TopicTracker.filter(Column("hiddenAt") == nil)
                .order(Column("createdAt").desc).fetchAll(db)
        }
    }

    @discardableResult
    func save(_ tracker: TopicTracker) async throws -> TopicTracker {
        var c = tracker
        return try await database.writer.write { db in try c.saved(db) }
    }

    /// Delete = tombstone + drop its hits (so counts vanish, but a backfill
    /// won't resurrect it).
    func hide(id: Int64) async throws {
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE topicTracker SET hiddenAt = ? WHERE id = ?", arguments: [Date(), id])
            try db.execute(sql: "DELETE FROM topicTrackerHit WHERE trackerId = ?", arguments: [id])
        }
    }

    /// Edit keywords: clear prior hits so a re-scan reflects the new terms.
    func updateKeywords(id: Int64, name: String, keywords: [String], semanticSeed: String?) async throws {
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE topicTracker SET name = ?, keywords = ?, semanticSeed = ? WHERE id = ?",
                           arguments: [name, TopicTracker.encode(keywords: keywords), semanticSeed, id])
            try db.execute(sql: "DELETE FROM topicTrackerHit WHERE trackerId = ?", arguments: [id])
        }
    }

    // Hits
    func hits(trackerId: Int64, limit: Int = 50) async throws -> [TopicTrackerHit] {
        try await database.writer.read { db in
            try TopicTrackerHit.filter(Column("trackerId") == trackerId)
                .order(Column("createdAt").desc).limit(limit).fetchAll(db)
        }
    }

    func hitCount(trackerId: Int64) async throws -> Int {
        try await database.writer.read { db in
            try TopicTrackerHit.filter(Column("trackerId") == trackerId).fetchCount(db)
        }
    }

    func recentHitCount(trackerId: Int64, since: Date) async throws -> Int {
        try await database.writer.read { db in
            try TopicTrackerHit.filter(Column("trackerId") == trackerId && Column("createdAt") >= since).fetchCount(db)
        }
    }

    func hasHit(trackerId: Int64, meetingId: String) async throws -> Bool {
        try await database.writer.read { db in
            try TopicTrackerHit.filter(Column("trackerId") == trackerId && Column("meetingId") == meetingId).fetchCount(db) > 0
        }
    }

    func saveHit(_ hit: TopicTrackerHit) async throws {
        var c = hit
        _ = try await database.writer.write { db in try c.saved(db) }
    }
}

// MARK: - Pure keyword matcher (unit-tested)

enum TopicMatcher {
    static let snippetCap = 160

    struct Match: Equatable {
        let atSeconds: Double
        let snippet: String
    }

    /// First transcript segment containing any of the tracker's keywords
    /// (case-insensitive substring). One match per meeting — the meeting is
    /// the unit of "came up". nil when nothing matches. Pure.
    ///
    /// Short, all-alphanumeric needles ("AI", "ML", "QA") require a word
    /// boundary so they don't match inside "again"/"html"/"squad". Longer or
    /// punctuated needles keep the plain substring contract.
    static func firstMatch(keywords: [String], in segments: [Transcript]) -> Match? {
        let needles = keywords
            .map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !needles.isEmpty else { return nil }
        for seg in segments.sorted(by: { $0.startTime < $1.startTime }) {
            let hay = seg.text.lowercased()
            if needles.contains(where: { matches($0, in: hay) }) {
                let snip = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return Match(atSeconds: seg.startTime,
                             snippet: snip.count <= snippetCap ? snip : String(snip.prefix(snippetCap)) + "…")
            }
        }
        return nil
    }

    private static func matches(_ needle: String, in hay: String) -> Bool {
        let isShort = needle.count <= 3
        let isAlnum = needle.allSatisfy { $0.isLetter || $0.isNumber }
        guard isShort, isAlnum else { return hay.contains(needle) }
        let pattern = "\\b" + NSRegularExpression.escapedPattern(for: needle) + "\\b"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return hay.contains(needle)   // never silently drop a keyword
        }
        return re.firstMatch(in: hay, range: NSRange(hay.startIndex..., in: hay)) != nil
    }

    /// Validity for a new tracker: at least one non-blank keyword OR a seed.
    static func isValid(keywords: [String], semanticSeed: String?) -> Bool {
        let hasKeyword = keywords.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let hasSeed = !(semanticSeed ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasKeyword || hasSeed
    }
}

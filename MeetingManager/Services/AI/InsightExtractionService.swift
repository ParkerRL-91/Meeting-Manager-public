import Foundation
import GRDB
import os

// MARK: - EntityFact (TASK-047, migration v49)

/// One durable fact extracted from a meeting, keyed to an entity so the
/// People/Company/Folder pages can show an auto-maintained dossier.
/// Facts are derived data: regeneration deletes a meeting's rows first
/// (review M9), and meeting deletion cleans them up.
struct EntityFact: Codable, FetchableRecord, MutablePersistableRecord, Identifiable {
    static let databaseTableName = "entityFact"

    var id: Int64?
    var entityType: String     // "person" | "company" | "series"
    var entityKey: String      // canonicalKey / email domain / folder key
    var meetingId: String
    var kind: String           // "decision" | "commitment" | "question" | "status"
    var text: String
    var owner: String?
    var dueDate: Date?
    var extractedAt: Date

    enum Columns {
        static let entityType = Column(CodingKeys.entityType)
        static let entityKey = Column(CodingKeys.entityKey)
        static let meetingId = Column(CodingKeys.meetingId)
        static let extractedAt = Column(CodingKeys.extractedAt)
    }

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

final class EntityFactRepository {
    private let database: AppDatabase
    init(database: AppDatabase) { self.database = database }

    func replaceForMeeting(_ meetingId: String, with facts: [EntityFact]) async throws {
        try await database.writer.write { db in
            try db.execute(sql: "DELETE FROM entityFact WHERE meetingId = ?", arguments: [meetingId])
            for var f in facts { try f.save(db) }
        }
    }

    func facts(entityType: String, entityKey: String, limit: Int = 40) async throws -> [EntityFact] {
        try await database.writer.read { db in
            try EntityFact
                .filter(EntityFact.Columns.entityType == entityType
                        && EntityFact.Columns.entityKey == entityKey)
                .order(EntityFact.Columns.extractedAt.desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    func factsForMeetings(_ meetingIds: [String], kinds: [String]? = nil) async throws -> [EntityFact] {
        try await database.writer.read { db in
            var request = EntityFact.filter(meetingIds.contains(EntityFact.Columns.meetingId))
            if let kinds { request = request.filter(kinds.contains(Column("kind"))) }
            return try request.order(EntityFact.Columns.extractedAt.desc).fetchAll(db)
        }
    }
}

// MARK: - Extraction

/// Post-summary structured-insight extraction (TASK-047): one
/// schema-constrained local call returning decisions/commitments/questions/
/// status updates, fanned out to person (canonical key), company (email
/// domain), and series (folder key) dossiers.
enum InsightExtraction {

    static let schemaJSON = """
    {"type":"object","properties":{
      "decisions":{"type":"array","items":{"type":"object","properties":{"text":{"type":"string"},"owner":{"type":["string","null"]}},"required":["text"]}},
      "commitments":{"type":"array","items":{"type":"object","properties":{"text":{"type":"string"},"owner":{"type":["string","null"]},"due":{"type":["string","null"]}},"required":["text"]}},
      "questions":{"type":"array","items":{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}},
      "statusUpdates":{"type":"array","items":{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}}
    },"required":["decisions","commitments","questions","statusUpdates"]}
    """

    static let systemPrompt = """
    You extract durable facts from a meeting summary. Return ONLY JSON \
    matching the requested shape. Rules: a decision is something the group \
    settled ("we will ship Friday"); a commitment is one named person \
    agreeing to do something; a question is explicitly unresolved; a status \
    update reports concrete progress or a change in state. Use only names \
    that appear in the text. Empty arrays are correct when a category has \
    nothing — never invent content. Dates in due fields use yyyy-MM-dd.
    """

    struct Payload: Decodable {
        struct Item: Decodable { let text: String; let owner: String?; let due: String? }
        struct Plain: Decodable { let text: String }
        let decisions: [Item]
        let commitments: [Item]
        let questions: [Plain]
        let statusUpdates: [Plain]
    }

    /// Map the parsed payload to entity facts. Pure — unit-testable.
    static func facts(from payload: Payload, meeting: Meeting,
                      participantDomains: [String], now: Date = Date()) -> [EntityFact] {
        let folderKey = MeetingFolder.normaliseTitle(meeting.title)
        let personKeys = meeting.participantList.map { VocativeMiningService.canonicalKey(for: $0) }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")

        var out: [EntityFact] = []
        func add(kind: String, text: String, owner: String?, due: Date?) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            // Series dossier always gets the fact.
            out.append(EntityFact(id: nil, entityType: "series", entityKey: folderKey,
                                  meetingId: meeting.id, kind: kind, text: trimmed,
                                  owner: owner, dueDate: due, extractedAt: now))
            // Owner-specific facts land on the owner's person dossier; the
            // rest land on every participant (it's their meeting's record).
            if let owner, !owner.isEmpty {
                out.append(EntityFact(id: nil, entityType: "person",
                                      entityKey: VocativeMiningService.canonicalKey(for: owner),
                                      meetingId: meeting.id, kind: kind, text: trimmed,
                                      owner: owner, dueDate: due, extractedAt: now))
            } else {
                for key in personKeys where !key.isEmpty {
                    out.append(EntityFact(id: nil, entityType: "person", entityKey: key,
                                          meetingId: meeting.id, kind: kind, text: trimmed,
                                          owner: nil, dueDate: due, extractedAt: now))
                }
            }
            for domain in Set(participantDomains) where !CompanyGroupingService.isConsumerDomain(domain) {
                out.append(EntityFact(id: nil, entityType: "company", entityKey: domain,
                                      meetingId: meeting.id, kind: kind, text: trimmed,
                                      owner: owner, dueDate: due, extractedAt: now))
            }
        }
        for d in payload.decisions { add(kind: "decision", text: d.text, owner: d.owner, due: nil) }
        for c in payload.commitments { add(kind: "commitment", text: c.text, owner: c.owner, due: c.due.flatMap { df.date(from: $0) }) }
        for q in payload.questions { add(kind: "question", text: q.text, owner: nil, due: nil) }
        for u in payload.statusUpdates { add(kind: "status", text: u.text, owner: nil, due: nil) }
        return out
    }

    static func parse(_ response: String) -> Payload? {
        // Tolerate fenced or prefixed output even though the schema makes it
        // unlikely: take the substring from the first "{" to the last "}".
        guard let start = response.firstIndex(of: "{"),
              let end = response.lastIndex(of: "}") else { return nil }
        let json = String(response[start...end])
        return try? JSONDecoder().decode(Payload.self, from: Data(json.utf8))
    }
}

// MARK: - Series running thread (TASK-049, migration v49)

struct SeriesThread: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "seriesThread"
    var folderKey: String      // MeetingFolder.normaliseTitle — pinned (review M6)
    var content: String
    var updatedAt: Date
}

final class SeriesThreadRepository {
    private let database: AppDatabase
    init(database: AppDatabase) { self.database = database }

    func thread(folderKey: String) async throws -> SeriesThread? {
        try await database.writer.read { db in
            try SeriesThread.fetchOne(db, key: folderKey)
        }
    }

    func save(_ thread: SeriesThread) async throws {
        try await database.writer.write { db in
            try thread.save(db)
        }
    }
}

enum SeriesThreadPrompts {
    static let system = """
    You maintain the running thread document for a recurring meeting \
    series. Merge the previous thread with the newest session's summary \
    and facts into an updated document with EXACTLY these Markdown \
    sections: "## Where things stand" (3-5 sentences), "## Decisions" \
    (dated bullets, newest first, keep prior entries), "## Open questions" \
    (drop ones the new session resolved), "## Carried items" (unfinished \
    commitments with owners). Stay under 500 words. Use only information \
    from the inputs — never invent.
    """
}

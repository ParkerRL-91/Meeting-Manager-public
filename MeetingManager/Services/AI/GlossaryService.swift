import Foundation
import GRDB

// MARK: - GlossaryTerm (TASK-064, migration v50)

/// One team-vocabulary term defined from how it's actually used.
/// `hiddenAt` is a user-delete tombstone — the miner never re-adds a
/// hidden term (plan risk: junk terms get a permanent delete).
struct GlossaryTerm: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "glossaryTerm"

    var term: String
    var definition: String
    var exampleMeetingId: String?
    var hiddenAt: Date?
    var updatedAt: Date

    var id: String { term }
}

final class GlossaryRepository {
    private let database: AppDatabase
    init(database: AppDatabase) { self.database = database }

    func visibleTerms() async throws -> [GlossaryTerm] {
        try await database.writer.read { db in
            try GlossaryTerm
                .filter(Column("hiddenAt") == nil)
                .order(Column("term").asc)
                .fetchAll(db)
        }
    }

    /// Every term ever stored, hidden included — the miner's exclusion set.
    func allTermStrings() async throws -> Set<String> {
        try await database.writer.read { db in
            Set(try String.fetchAll(db, sql: "SELECT term FROM glossaryTerm"))
        }
    }

    func save(_ term: GlossaryTerm) async throws {
        try await database.writer.write { db in try term.save(db) }
    }

    /// User delete: tombstone, never a row delete — the miner respects it.
    func hide(term: String) async throws {
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE glossaryTerm SET hiddenAt = ? WHERE term = ?",
                           arguments: [Date(), term])
        }
    }
}

// MARK: - Miner (TASK-064)

/// Nightly background batch: mine transcripts for recurring jargon
/// (ALL-CAPS and camelCase tokens that aren't dictionary words, used in
/// ≥3 meetings), infer definitions from usage contexts with ONE
/// schema-constrained call, store in `glossaryTerm`.
enum GlossaryMiner {

    /// Frequency floor: a term must appear in at least this many
    /// DIFFERENT meetings (plan risk note: junk terms).
    static let meetingFloor = 3
    /// Hard cap of new terms defined per nightly run (review M8).
    static let termCapPerRun = 12
    static let contextsPerTerm = 3
    static let contextClip = 160

    struct Candidate: Equatable {
        let term: String
        let contexts: [String]
        let exampleMeetingId: String
    }

    /// Tokens shaped like jargon: SCREAMING (2–6 caps, optional trailing
    /// s) or camelCase/PascalCase with an interior capital.
    static func jargonTokens(in text: String) -> Set<String> {
        var out = Set<String>()
        let patterns = [
            "\\b[A-Z]{2,6}s?\\b",                       // MTB, ACMG, APIs
            "\\b[A-Z][a-z]+(?:[A-Z][a-zA-Z]*)+\\b",    // Acme, TaskQueue
            "\\b[a-z]+(?:[A-Z][a-zA-Z]*)+\\b",         // camelCase
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range) {
                if let r = Range(match.range, in: text) {
                    out.insert(String(text[r]))
                }
            }
        }
        return out
    }

    /// Pure candidate selection. `dictionary` is lowercase common words
    /// (the runner loads /usr/share/dict/words); `excluded` is every term
    /// already stored, hidden tombstones included.
    static func candidates(transcriptsByMeeting: [String: String],
                           dictionary: Set<String>,
                           excluded: Set<String>,
                           floor: Int = meetingFloor,
                           cap: Int = termCapPerRun) -> [Candidate] {
        var meetingsPerTerm: [String: Set<String>] = [:]
        for (meetingId, text) in transcriptsByMeeting {
            for token in jargonTokens(in: text) {
                guard token.count >= 2, !excluded.contains(token) else { continue }
                // Dictionary words (and their plural stems) aren't jargon.
                let lower = token.lowercased()
                if dictionary.contains(lower) { continue }
                if lower.hasSuffix("s"), dictionary.contains(String(lower.dropLast())) { continue }
                meetingsPerTerm[token, default: []].insert(meetingId)
            }
        }

        let frequent = meetingsPerTerm
            .filter { $0.value.count >= floor }
            .sorted { $0.value.count == $1.value.count ? $0.key < $1.key : $0.value.count > $1.value.count }
            .prefix(cap)

        return frequent.compactMap { term, meetingIds in
            var contexts: [String] = []
            var bestMeeting = (id: "", hits: 0)
            for meetingId in meetingIds.sorted() {
                guard let text = transcriptsByMeeting[meetingId] else { continue }
                let lines = text.components(separatedBy: .newlines)
                    .filter { $0.contains(term) }
                if lines.count > bestMeeting.hits { bestMeeting = (meetingId, lines.count) }
                if contexts.count < contextsPerTerm, let line = lines.first {
                    let t = line.trimmingCharacters(in: .whitespaces)
                    contexts.append(t.count <= contextClip ? t : String(t.prefix(contextClip)) + "…")
                }
            }
            guard !contexts.isEmpty else { return nil }
            return Candidate(term: term, contexts: contexts, exampleMeetingId: bestMeeting.id)
        }
    }

    // MARK: Definition inference

    static let defineSchemaJSON = """
    {"type":"object","properties":{"definitions":{"type":"array","items":{"type":"object","properties":{"term":{"type":"string"},"definition":{"type":"string"}},"required":["term","definition"]}}},"required":["definitions"]}
    """

    static let defineSystemPrompt = """
    You define a team's internal vocabulary from how it is actually used \
    in their meetings. For each term, write a one-sentence definition \
    (under 25 words) grounded ONLY in the usage excerpts provided — the \
    reader is a new team member. If the excerpts don't reveal what a term \
    means, use the exact string "unknown" as its definition. Never guess \
    from the term's letters alone. Return ONLY JSON matching the \
    requested shape.
    """

    static func defineUserPrompt(candidates: [Candidate]) -> String {
        candidates.map { c in
            "Term: \(c.term)\n" + c.contexts.map { "  usage: \($0)" }.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    struct DefinePayload: Decodable {
        struct Entry: Decodable { let term: String; let definition: String }
        let definitions: [Entry]
    }

    static func parseDefinitions(_ response: String) -> DefinePayload? {
        guard let start = response.firstIndex(of: "{"),
              let end = response.lastIndex(of: "}") else { return nil }
        return try? JSONDecoder().decode(DefinePayload.self,
                                         from: Data(String(response[start...end]).utf8))
    }

    /// Markdown for the KB write-back ("Glossary.md").
    static func markdown(terms: [GlossaryTerm]) -> String {
        var lines = ["# Team Glossary", "",
                     "Definitions inferred from meeting usage. Maintained automatically; remove junk terms from the app's search results.", ""]
        for t in terms {
            lines.append("- **\(t.term)** — \(t.definition)")
        }
        return lines.joined(separator: "\n")
    }
}

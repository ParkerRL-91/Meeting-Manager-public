import Foundation
import GRDB

// MARK: - GeneratedDoc (TASK-062, migration v53)

/// A generated artifact anchored to a string key — handover briefs today
/// (kind "handover", anchorKey = folder key). Rows accumulate; the
/// newest per (kind, anchorKey) is the live one and older rows are the
/// regeneration history.
struct GeneratedDoc: Codable, FetchableRecord, MutablePersistableRecord, Identifiable {
    static let databaseTableName = "generatedDoc"

    var id: Int64?
    var kind: String
    var anchorKey: String
    var content: String
    var createdAt: Date

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

final class GeneratedDocRepository {
    private let database: AppDatabase
    init(database: AppDatabase) { self.database = database }

    func latest(kind: String, anchorKey: String) async throws -> GeneratedDoc? {
        try await database.writer.read { db in
            try GeneratedDoc
                .filter(Column("kind") == kind && Column("anchorKey") == anchorKey)
                .order(Column("createdAt").desc)
                .fetchOne(db)
        }
    }

    func save(_ doc: GeneratedDoc) async throws {
        var copy = doc
        _ = try await database.writer.write { db in try copy.save(db) }
    }
}

// MARK: - Handover brief assembly (TASK-062)

/// Builds the one-shot handover prompt from the series record: running
/// thread + facts + recent summaries + participants. Pure — the views
/// fetch, this formats.
enum HandoverDoc {

    static let systemPrompt = """
    You write a handover brief for someone taking over a recurring \
    meeting series. Output Markdown with EXACTLY these sections: \
    "## What this is" (2-3 sentences: purpose and rhythm of the series), \
    "## Where things stand" (current state, 3-5 sentences), \
    "## Key decisions" (dated bullets, newest first), \
    "## Open items" (unfinished commitments and questions, with owners), \
    "## Who's who" (one line per person: their role as evidenced by the \
    record), "## Watch out for" (risks, objections, and unresolved \
    tensions the record shows). Use ONLY the provided record — never \
    invent names, dates, or commitments. Skip a section with "Nothing \
    recorded." when the record has nothing for it. Stay under 700 words.
    """

    static func userPrompt(folderName: String,
                           participants: [String],
                           threadContent: String?,
                           facts: [EntityFact],
                           summaries: [(title: String, date: Date, excerpt: String)]) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"

        var sections: [String] = ["Series: \(folderName)"]
        if !participants.isEmpty {
            sections.append("Participants: \(participants.joined(separator: ", "))")
        }
        if let threadContent, !threadContent.isEmpty {
            sections.append("Running thread:\n\(String(threadContent.prefix(3000)))")
        }
        let factLines = facts.prefix(40).map { f in
            let owner = f.owner.map { " (\($0))" } ?? ""
            return "- [\(f.kind)] \(df.string(from: f.extractedAt))\(owner): \(f.text)"
        }
        if !factLines.isEmpty {
            sections.append("Facts:\n\(factLines.joined(separator: "\n"))")
        }
        for s in summaries.prefix(3) {
            sections.append("Session \(df.string(from: s.date)) — \(s.title):\n\(String(s.excerpt.prefix(2000)))")
        }
        return sections.joined(separator: "\n\n")
    }
}

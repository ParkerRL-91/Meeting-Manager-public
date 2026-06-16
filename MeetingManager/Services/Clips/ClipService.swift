import Foundation
import GRDB

// MARK: - Clip (TASK-078, migration v56)

/// A saved moment from a meeting: a time range, the verbatim quote text
/// that spanned it, and who said it. Clips are a search/keep/listen
/// surface — deliberately NO sharing or export (per scope). The quote
/// text is a SNAPSHOT (survives later transcript edits); the time range
/// is the playback anchor (`AudioPlaybackService.playRange`).
struct Clip: Codable, FetchableRecord, MutablePersistableRecord, Identifiable {
    static let databaseTableName = "clip"

    var id: Int64?
    var meetingId: String
    var startTime: Double
    var endTime: Double
    var quoteText: String
    var speakerLabels: String?
    var note: String?
    var createdAt: Date

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    /// `MM:SS` / `H:MM:SS` for the clip's start.
    var timestampLabel: String {
        let total = max(0, Int(startTime))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

final class ClipRepository {
    private let database: AppDatabase
    init(database: AppDatabase) { self.database = database }

    func clips(meetingId: String) async throws -> [Clip] {
        try await database.writer.read { db in
            try Clip.filter(Column("meetingId") == meetingId)
                .order(Column("startTime").asc)
                .fetchAll(db)
        }
    }

    func allClips(limit: Int = 500) async throws -> [Clip] {
        try await database.writer.read { db in
            try Clip.order(Column("createdAt").desc).limit(limit).fetchAll(db)
        }
    }

    @discardableResult
    func save(_ clip: Clip) async throws -> Clip {
        var copy = clip
        return try await database.writer.write { db in try copy.saved(db) }
    }

    func delete(id: Int64) async throws {
        _ = try await database.writer.write { db in try Clip.deleteOne(db, key: id) }
    }

    func updateNote(id: Int64, note: String?) async throws {
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE clip SET note = ? WHERE id = ?",
                           arguments: [note, id])
        }
    }
}

// MARK: - Pure builder (unit-tested)

enum ClipBuilder {
    /// Maximum stored quote length — the time range is unbounded, but a
    /// runaway selection shouldn't bloat the row.
    static let maxQuoteChars = 4000

    /// Build a clip from a contiguous run of transcript segments. Returns
    /// nil for an empty selection or an all-blank quote. Pure.
    static func fromSegments(_ segments: [Transcript], meetingId: String, now: Date = Date()) -> Clip? {
        let ordered = segments.sorted { $0.startTime < $1.startTime }
        guard let first = ordered.first, let last = ordered.last else { return nil }
        let start = first.startTime
        let end = max(last.endTime, first.startTime)
        guard end > start else { return nil }

        var quote = ordered.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !quote.isEmpty else { return nil }
        if quote.count > maxQuoteChars { quote = String(quote.prefix(maxQuoteChars)) + "…" }

        var seenLabels = Set<String>()
        let speakers = ordered.compactMap { seg -> String? in
            guard let l = seg.speakerLabel, !l.isEmpty, seenLabels.insert(l).inserted else { return nil }
            return l
        }.joined(separator: ", ")

        return Clip(id: nil, meetingId: meetingId, startTime: start, endTime: end,
                    quoteText: quote, speakerLabels: speakers.isEmpty ? nil : speakers,
                    note: nil, createdAt: now)
    }
}

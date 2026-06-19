import Foundation
import GRDB
import os

final class TranscriptRepository {
    private let database: AppDatabase

    init(database: AppDatabase) {
        self.database = database
    }

    func save(_ transcript: inout Transcript) async throws {
        // Return the saved record so the auto-assigned rowid propagates back
        // (see TaskRepository.save).
        let input = transcript
        transcript = try await database.writer.write { db in
            var copy = input
            try copy.save(db)
            return copy
        }
    }

    func saveBatch(_ transcripts: [Transcript]) async throws {
        try await database.writer.write { db in
            for var transcript in transcripts {
                try transcript.save(db)
            }
        }
    }

    func transcriptsForMeeting(_ meetingId: String, limit: Int = 200, offset: Int = 0) async throws -> [Transcript] {
        try await database.writer.read { db in
            try Transcript
                .filter(Transcript.Columns.meetingId == meetingId)
                .order(Transcript.Columns.startTime.asc)
                .limit(limit, offset: offset)
                .fetchAll(db)
        }
    }

    func fullText(meetingId: String) async throws -> String {
        try await database.writer.read { db in
            var result = ""
            let cursor = try Transcript
                .filter(Transcript.Columns.meetingId == meetingId)
                .order(Transcript.Columns.startTime.asc)
                .fetchCursor(db)
            while let segment = try cursor.next() {
                if !result.isEmpty { result += "\n" }
                result += "[\(segment.formattedTimestamp)] \(segment.speakerDisplayName): \(segment.text)"
            }
            return result
        }
    }

    /// Cross-meeting full-text search for the global search sheet
    /// (TASK-039). Returns at most one hit per meeting (the best-ranked
    /// snippet) so one chatty meeting can't crowd out the rest.
    func searchAllMeetings(query: String, limit: Int = 8) async throws -> [(meetingId: String, snippet: String)] {
        try await database.writer.read { db in
            let pattern = FTS5Pattern(matchingAllTokensIn: query)?.rawPattern ?? query
            let rows = try Row.fetchAll(db, sql: """
                SELECT transcript.meetingId AS meetingId,
                       snippet(transcript_fts, 0, '', '', '…', 12) AS snip,
                       MIN(rank) AS best
                FROM transcript
                JOIN transcript_fts ON transcript.rowid = transcript_fts.rowid
                WHERE transcript_fts MATCH ?
                GROUP BY transcript.meetingId
                ORDER BY best
                LIMIT ?
                """, arguments: [pattern, limit])
            return rows.map { ($0["meetingId"] as String, $0["snip"] as String? ?? "") }
        }
    }

    /// TASK-066: the best-matching segment for a fact's text within one
    /// meeting — the "receipt" anchor. OR over the fact's tokens ranked by
    /// BM25; nil when nothing matches (anchoring is best-effort, facts ship
    /// without receipts rather than with wrong ones).
    func bestAnchor(meetingId: String, factText: String) async throws -> (transcriptId: Int64, startTime: Double)? {
        guard let pattern = FTS5Pattern(matchingAnyTokenIn: factText) else { return nil }
        return try await database.writer.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT transcript.id AS tid, transcript.startTime AS st
                FROM transcript
                JOIN transcript_fts ON transcript.rowid = transcript_fts.rowid
                WHERE transcript_fts MATCH ? AND transcript.meetingId = ?
                ORDER BY rank
                LIMIT 1
                """, arguments: [pattern, meetingId])
            guard let row, let tid = row["tid"] as Int64? else { return nil }
            return (tid, row["st"] as Double? ?? 0)
        }
    }

    /// TASK-066: speaker labels for a set of anchor segments, keyed by id.
    func speakerLabels(for ids: [Int64]) async throws -> [Int64: String] {
        guard !ids.isEmpty else { return [:] }
        return try await database.writer.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT id, speakerLabel FROM transcript WHERE id IN (\(ids.map { _ in "?" }.joined(separator: ",")))",
                arguments: StatementArguments(ids)
            )
            var out: [Int64: String] = [:]
            for row in rows {
                if let id = row["id"] as Int64?, let label = row["speakerLabel"] as String? {
                    out[id] = label
                }
            }
            return out
        }
    }

    func search(meetingId: String, query: String) async throws -> [Transcript] {
        try await database.writer.read { db in
            let sql = """
                SELECT transcript.* FROM transcript
                JOIN transcript_fts ON transcript.rowid = transcript_fts.rowid
                WHERE transcript_fts MATCH ? AND transcript.meetingId = ?
                ORDER BY transcript.startTime
                """
            let pattern = FTS5Pattern(matchingAllTokensIn: query)?.rawPattern ?? query
            return try Transcript.fetchAll(db, sql: sql, arguments: [pattern, meetingId])
        }
    }

    /// Bulk-rename every transcript in a meeting whose `speakerLabel` matches
    /// `oldLabel`. Used by v3.1 Layer 3 when the user reassigns a cluster
    /// ("Speaker 1" → "Alex Chen") so all of that cluster's turns flip in one
    /// write rather than per-row updates from the UI.
    func updateSpeakerLabel(meetingId: String, from oldLabel: String, to newLabel: String) async throws {
        guard oldLabel != newLabel else { return }
        try await database.writer.write { db in
            try Transcript
                .filter(Transcript.Columns.meetingId == meetingId)
                .filter(Transcript.Columns.speakerLabel == oldLabel)
                .updateAll(db, Transcript.Columns.speakerLabel.set(to: newLabel))
        }
    }

    /// Bulk-update speaker labels from a diarization alignment pass.
    /// Only rows present in the mapping are written; all others are untouched.
    func updateSpeakerLabels(_ mapping: [Int64: String]) async throws {
        guard !mapping.isEmpty else { return }
        try await database.writer.write { db in
            for (transcriptId, label) in mapping {
                try db.execute(
                    sql: "UPDATE transcript SET speakerLabel = ? WHERE id = ?",
                    arguments: [label, transcriptId]
                )
            }
        }
    }

    func deleteForMeeting(_ meetingId: String) async throws {
        try await database.writer.write { db in
            _ = try Transcript
                .filter(Transcript.Columns.meetingId == meetingId)
                .deleteAll(db)
        }
    }

    /// Observe transcript for real-time UI updates during recording
    func observeTranscripts(
        meetingId: String,
        onChange: @escaping ([Transcript]) -> Void
    ) -> DatabaseCancellable {
        ValueObservation
            .tracking { db in
                try Transcript
                    .filter(Transcript.Columns.meetingId == meetingId)
                    .order(Transcript.Columns.startTime.asc)
                    .fetchAll(db)
            }
            .start(in: database.writer, onError: { error in
                Logger.database.error("Transcript observation error: \(error.localizedDescription, privacy: .public)")
            }, onChange: onChange)
    }
}

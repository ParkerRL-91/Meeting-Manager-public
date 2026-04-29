import Foundation
import GRDB
import os

final class TranscriptRepository {
    private let database: AppDatabase

    init(database: AppDatabase) {
        self.database = database
    }

    func save(_ transcript: inout Transcript) async throws {
        var copy = transcript
        try await database.writer.write { db in
            try copy.save(db)
        }
        transcript = copy
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

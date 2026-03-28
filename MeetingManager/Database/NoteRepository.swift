import Foundation
import GRDB

final class NoteRepository {
    private let database: AppDatabase

    init(database: AppDatabase) {
        self.database = database
    }

    func save(_ note: inout MeetingNote) async throws {
        try await database.writer.write { db in
            try note.save(db)
        }
    }

    func notesForMeeting(_ meetingId: String) async throws -> [MeetingNote] {
        try await database.writer.read { db in
            try MeetingNote
                .filter(MeetingNote.Columns.meetingId == meetingId)
                .order(MeetingNote.Columns.createdAt.asc)
                .fetchAll(db)
        }
    }

    func latestNote(meetingId: String) async throws -> MeetingNote? {
        try await database.writer.read { db in
            try MeetingNote
                .filter(MeetingNote.Columns.meetingId == meetingId)
                .order(MeetingNote.Columns.createdAt.desc)
                .fetchOne(db)
        }
    }

    func combinedNotes(meetingId: String) async throws -> String {
        let notes = try await notesForMeeting(meetingId)
        return notes.map(\.content).joined(separator: "\n\n")
    }

    func delete(_ note: MeetingNote) async throws {
        try await database.writer.write { db in
            _ = try note.delete(db)
        }
    }
}

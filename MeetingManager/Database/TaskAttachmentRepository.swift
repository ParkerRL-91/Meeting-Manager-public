import Foundation
import GRDB

/// Repository for task attachments (rows only). File bytes live on disk; see the
/// path helpers below. The actual copy/thumbnail/delete-on-disk lives in
/// `TaskAttachmentService` (PRJ-013 Phase 4); this type owns the DB rows and the
/// canonical on-disk locations.
final class TaskAttachmentRepository {
    private let database: AppDatabase

    init(database: AppDatabase = .shared) {
        self.database = database
    }

    func attachments(forTask taskId: Int64) async throws -> [TaskAttachment] {
        try await database.writer.read { db in
            try TaskAttachment
                .filter(TaskAttachment.Columns.taskId == taskId)
                .order(TaskAttachment.Columns.addedAt.asc)
                .fetchAll(db)
        }
    }

    func save(_ attachment: inout TaskAttachment) async throws {
        let input = attachment
        attachment = try await database.writer.write { db in
            var copy = input
            try copy.save(db)
            return copy
        }
    }

    func delete(id: Int64) async throws {
        try await database.writer.write { db in
            _ = try TaskAttachment.deleteOne(db, key: id)
        }
    }

    // MARK: - On-disk locations

    /// `~/Library/Application Support/MeetingManager`.
    static func meetingManagerDirectory() -> URL {
        let appSupport = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false))
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport.appendingPathComponent("MeetingManager", isDirectory: true)
    }

    /// `…/MeetingManager/TaskAttachments/<taskId>`.
    static func attachmentsDirectory(forTask taskId: Int64) -> URL {
        meetingManagerDirectory()
            .appendingPathComponent("TaskAttachments/\(taskId)", isDirectory: true)
    }

    /// Resolves a stored relative path (e.g. `TaskAttachments/12/uuid.png`) to its
    /// absolute on-disk URL.
    static func absoluteURL(forRelativePath relativePath: String) -> URL {
        meetingManagerDirectory().appendingPathComponent(relativePath)
    }
}

import Foundation
import GRDB

enum TaskAttachmentKind: String, Codable, CaseIterable {
    case image
    case file
}

/// A file or image attached to a task. Bytes live on disk under
/// `Application Support/MeetingManager/TaskAttachments/<taskId>/<uuid>.<ext>`;
/// this row holds the reference. The DB cascade removes the ROW when its task is
/// hard-deleted; the on-disk file is removed by `TaskRepository.purgeDeleted`.
struct TaskAttachment: Identifiable, Codable, Equatable {
    var id: Int64?
    var taskId: Int64
    var kind: TaskAttachmentKind
    var originalName: String
    /// Path relative to the Application Support `MeetingManager` directory.
    var relativePath: String
    var byteSize: Int64
    var addedAt: Date

    init(
        id: Int64? = nil,
        taskId: Int64,
        kind: TaskAttachmentKind,
        originalName: String,
        relativePath: String,
        byteSize: Int64 = 0,
        addedAt: Date = Date()
    ) {
        self.id = id
        self.taskId = taskId
        self.kind = kind
        self.originalName = originalName
        self.relativePath = relativePath
        self.byteSize = byteSize
        self.addedAt = addedAt
    }
}

// MARK: - GRDB

extension TaskAttachment: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "taskAttachment"

    enum Columns: String, ColumnExpression {
        case id, taskId, kind, originalName, relativePath, byteSize, addedAt
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

import Foundation
import GRDB

/// Triage state for a task. AI-extracted items start in `.inbox` (the review
/// queue); manually-created tasks default to `.accepted` (live on the board).
/// `.dismissed` is a rejected-but-recoverable suggestion.
enum TaskTriageState: String, Codable, CaseIterable {
    case inbox
    case accepted
    case dismissed
}

/// The unified task record. Backed by the `actionItem` table (name kept for
/// migration safety; the Swift type rename to `TaskItem` is deferred to a later
/// cleanup — see PRJ-013). An action item IS a task: extracted from a meeting or
/// created by hand, optionally a subtask of another, living in a Kanban stage.
struct ActionItem: Identifiable, Codable, Equatable {
    var id: Int64?
    /// Source meeting. Optional: manually-created/standalone tasks have none, and
    /// deleting a meeting nulls this (FK ON DELETE SET NULL) rather than deleting
    /// the task.
    var meetingId: String?
    /// Parent task for a subtask (one level). Enforced in app code (no DB FK to
    /// avoid a self-reference during the table recreate).
    var parentTaskId: Int64?
    /// Kanban column. Nil while the item sits in the inbox / has no stage.
    var stageId: Int64?
    /// Optional project grouping (PRJ-013 Phase 7). Cleared (not cascaded) when the
    /// project is deleted — the ALTER-added column carries no DB ON DELETE action.
    var projectId: Int64?
    var title: String
    var assignee: String?
    /// Optional link to a `Person.id` for richer assignment; `assignee` stays as
    /// the display fallback.
    var assigneePersonId: String?
    var dueDate: Date?
    /// Explicit alert time; when nil the per-task notification fires at `dueDate`.
    var reminderAt: Date?
    var isCompleted: Bool
    var completedAt: Date?
    var triageState: TaskTriageState
    /// 0 none · 1 low · 2 medium · 3 high · 4 urgent.
    var priority: Int
    /// Markdown body.
    var notes: String?
    /// JSON-encoded `[String]` of tags (mirrors `Person.aliasesJSON`).
    var tagsJSON: String?
    /// Fractional rank within a stage for manual ordering.
    var sortOrder: Double
    /// JSON-encoded recurrence rule (advanced; nil = one-off).
    var recurrenceRuleJSON: String?
    /// Origin: "meeting" | "manual" | "chat" | "import".
    var source: String?
    var extractedAt: Date
    var createdAt: Date
    var updatedAt: Date
    var archivedAt: Date?
    /// Soft delete: set on delete, files purged later; nil = live.
    var deletedAt: Date?

    init(
        id: Int64? = nil,
        meetingId: String? = nil,
        parentTaskId: Int64? = nil,
        stageId: Int64? = nil,
        projectId: Int64? = nil,
        title: String,
        assignee: String? = nil,
        assigneePersonId: String? = nil,
        dueDate: Date? = nil,
        reminderAt: Date? = nil,
        isCompleted: Bool = false,
        completedAt: Date? = nil,
        triageState: TaskTriageState = .accepted,
        priority: Int = 0,
        notes: String? = nil,
        tagsJSON: String? = nil,
        sortOrder: Double = 0,
        recurrenceRuleJSON: String? = nil,
        source: String? = nil,
        extractedAt: Date = Date(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        archivedAt: Date? = nil,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.meetingId = meetingId
        self.parentTaskId = parentTaskId
        self.stageId = stageId
        self.projectId = projectId
        self.title = title
        self.assignee = assignee
        self.assigneePersonId = assigneePersonId
        self.dueDate = dueDate
        self.reminderAt = reminderAt
        self.isCompleted = isCompleted
        self.completedAt = completedAt
        self.triageState = triageState
        self.priority = priority
        self.notes = notes
        self.tagsJSON = tagsJSON
        self.sortOrder = sortOrder
        self.recurrenceRuleJSON = recurrenceRuleJSON
        self.source = source
        self.extractedAt = extractedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.archivedAt = archivedAt
        self.deletedAt = deletedAt
    }

    /// Convenience accessor over `tagsJSON`. Not a stored column.
    var tags: [String] {
        get {
            guard let tagsJSON, let data = tagsJSON.data(using: .utf8) else { return [] }
            return (try? JSONDecoder().decode([String].self, from: data)) ?? []
        }
        set {
            tagsJSON = (try? JSONEncoder().encode(newValue))
                .flatMap { String(data: $0, encoding: .utf8) }
        }
    }

    /// True when the item is a live, accepted task (not inbox/dismissed/deleted).
    var isLiveTask: Bool { triageState == .accepted && deletedAt == nil }
}

// MARK: - GRDB

extension ActionItem: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "actionItem"

    enum Columns: String, ColumnExpression {
        case id, meetingId, parentTaskId, stageId, projectId, title, assignee, assigneePersonId,
             dueDate, reminderAt, isCompleted, completedAt, triageState, priority,
             notes, tagsJSON, sortOrder, recurrenceRuleJSON, source,
             extractedAt, createdAt, updatedAt, archivedAt, deletedAt
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

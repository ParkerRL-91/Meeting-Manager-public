import Foundation
import GRDB

/// Recurrence rule for a task (PRJ-013 Phase 7). Stored as JSON in
/// `TaskItem.recurrenceRuleJSON`. A nil rule means the task is one-off.
struct TaskRecurrenceRule: Codable, Equatable {
    enum Frequency: String, Codable, CaseIterable, Identifiable {
        case daily, weekly, monthly, yearly
        var id: String { rawValue }
        var label: String {
            switch self {
            case .daily: return "Daily"
            case .weekly: return "Weekly"
            case .monthly: return "Monthly"
            case .yearly: return "Yearly"
            }
        }
    }

    var frequency: Frequency
    /// Every N periods (1 = every period). Clamped to ≥ 1 when applied.
    var interval: Int
    /// Stop spawning once the next due date would fall after this. Nil = no end.
    var endDate: Date?

    init(frequency: Frequency, interval: Int = 1, endDate: Date? = nil) {
        self.frequency = frequency
        self.interval = interval
        self.endDate = endDate
    }

    /// The Calendar.Component + step the interval drives.
    private var component: Calendar.Component {
        switch frequency {
        case .daily: return .day
        case .weekly: return .weekOfYear
        case .monthly: return .month
        case .yearly: return .year
        }
    }

    /// The next due date after `from`, or nil if past the rule's end.
    func nextDate(after from: Date, calendar: Calendar = .current) -> Date? {
        let step = max(interval, 1)
        guard let next = calendar.date(byAdding: component, value: step, to: from) else { return nil }
        if let endDate, next > endDate { return nil }
        return next
    }

    // MARK: - JSON

    func encoded() -> String? {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func decode(_ json: String?) -> TaskRecurrenceRule? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(TaskRecurrenceRule.self, from: data)
    }

    // MARK: - Human-readable summary (PRJ-015 / TASK-111)

    /// A plain-English one-liner for the AI-compose preview, e.g.
    /// "Repeats every 3 days until Sep 1" / "Repeats weekly, starting Mon, Jun 22".
    /// Built with its own lowercase/pluralized period nouns (not `Frequency.label`,
    /// which is capitalized) via an exhaustive switch. Start clause only when `dueDate`
    /// is non-nil; end clause only when `endDate` is non-nil; start before end. `now` /
    /// `calendar` are injected so the year-omission logic is deterministic in tests.
    func summary(dueDate: Date?, now: Date = Date(), calendar: Calendar = .current) -> String {
        let n = max(interval, 1)
        let period: String
        if n == 1 {
            switch frequency {
            case .daily: period = "daily"
            case .weekly: period = "weekly"
            case .monthly: period = "monthly"
            case .yearly: period = "yearly"
            }
        } else {
            let unit: String
            switch frequency {
            case .daily: unit = "day"
            case .weekly: unit = "week"
            case .monthly: unit = "month"
            case .yearly: unit = "year"
            }
            period = "every \(n) \(unit)s"
        }
        var result = "Repeats \(period)"
        if let dueDate {
            result += ", starting \(Self.formatDate(dueDate, now: now, calendar: calendar, weekday: true))"
        }
        if let endDate {
            // Comma only when a "starting …" clause precedes it, so a rule with
            // just an end date reads "Repeats every 3 days until Sep 1".
            let lead = dueDate == nil ? " " : ", "
            result += "\(lead)until \(Self.formatDate(endDate, now: now, calendar: calendar, weekday: false))"
        }
        return result
    }

    private static func formatDate(_ date: Date, now: Date, calendar: Calendar, weekday: Bool) -> String {
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        if weekday {
            df.dateFormat = sameYear ? "EEE, MMM d" : "EEE, MMM d, yyyy"
        } else {
            df.dateFormat = sameYear ? "MMM d" : "MMM d, yyyy"
        }
        return df.string(from: date)
    }
}

/// Spawns the next occurrence of a recurring task exactly once, on the
/// completion transition (PRJ-013 Phase 7). Invoked synchronously inside the
/// completion write transaction (`TaskRepository.applyCompletion`) so the
/// single-spawn guard and the completion write share one atomic context.
///
/// Single-spawn guarantee: only fires when a task moves incomplete → complete
/// (the caller passes `wasCompleted`), and only copies the **parent** task's
/// fields — never its subtasks or attachments. The spawned occurrence is itself
/// recurring, so it re-arms on its own completion; the chain advances one step per
/// completion and never loops within a single transaction.
enum TaskRecurrenceService {
    /// Called from inside the completion transaction when a task transitions to
    /// completed. If the task carries a recurrence rule and the rule has not ended,
    /// inserts the next occurrence as a fresh incomplete task in the default stage.
    static func spawnNextIfNeeded(
        for completed: TaskItem,
        wasCompleted: Bool,
        db: Database,
        calendar: Calendar = .current
    ) throws {
        // Only on the incomplete → complete transition; never for subtasks.
        guard !wasCompleted, completed.parentTaskId == nil else { return }
        guard let rule = TaskRecurrenceRule.decode(completed.recurrenceRuleJSON) else { return }

        // Base the next due off the current due date (or completion time if undated).
        let base = completed.dueDate ?? Date()
        guard let nextDue = rule.nextDate(after: base, calendar: calendar) else { return }

        let defaultStage = try TaskStage
            .filter(TaskStage.Columns.isDefault == true)
            .fetchOne(db)?.id

        let now = Date()
        var next = TaskItem(
            meetingId: completed.meetingId,
            stageId: defaultStage,
            projectId: completed.projectId,
            title: completed.title,
            assignee: completed.assignee,
            assigneePersonId: completed.assigneePersonId,
            dueDate: nextDue,
            reminderAt: nil,
            isCompleted: false,
            triageState: .accepted,
            priority: completed.priority,
            notes: completed.notes,
            tagsJSON: completed.tagsJSON,
            sortOrder: completed.sortOrder,
            recurrenceRuleJSON: completed.recurrenceRuleJSON,
            source: completed.source,
            extractedAt: now,
            createdAt: now,
            updatedAt: now
        )
        try next.insert(db)
    }
}

import EventKit
import Foundation
import os

/// One-time import of existing Apple Reminders into the task manager (PRJ-013
/// Phase 2). This is NOT an ongoing sync — the outbound Reminders push was
/// removed; this exists so a migrant's existing tasks come across once rather
/// than being stranded on an empty board.
///
/// Imported items are `triageState=.accepted` (they are real tasks, not AI
/// suggestions, so they must not drown the triage inbox) and `source="import"`.
/// Completion/stage routes through `ActionItemRepository.applyCompletion` (via
/// `insertImported`) — never a raw `isCompleted` write.
@MainActor
final class TaskImportService {
    struct Summary {
        let imported: Int
        let total: Int
        let skipped: Int

        var message: String {
            "\(imported) of \(total) imported, \(skipped) skipped"
        }
    }

    private let reminders = RemindersService.shared
    private let repo = ActionItemRepository()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.meetingmanager", category: "task-import")

    /// Requests access, reads every reminder, and creates accepted tasks for the
    /// ones not already imported. De-dupes on (lowercased title, due-date day) vs
    /// existing `source="import"` rows so a re-run is idempotent.
    func importFromReminders() async -> Summary {
        guard await reminders.requestAccess() else {
            logger.info("Reminders access denied; nothing imported")
            return Summary(imported: 0, total: 0, skipped: 0)
        }

        let fetched = await reminders.fetchReminders()
        let total = fetched.count
        guard total > 0 else { return Summary(imported: 0, total: 0, skipped: 0) }

        let existing = (try? await repo.itemsBySource("import")) ?? []
        var seen = Set(existing.map { dedupeKey(title: $0.title, dueDate: $0.dueDate) })

        let cal = Calendar.current
        var toInsert: [(item: ActionItem, completed: Bool)] = []

        for (reminder, listTitle) in fetched {
            let title = (reminder.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }

            let dueDate: Date? = reminder.dueDateComponents.flatMap { cal.date(from: $0) }
            let key = dedupeKey(title: title, dueDate: dueDate)
            guard !seen.contains(key) else { continue }
            seen.insert(key)

            var item = ActionItem(
                title: title,
                dueDate: dueDate,
                triageState: .accepted,
                notes: reminder.notes,
                source: "import"
            )
            item.tags = [listTitle]
            toInsert.append((item, reminder.isCompleted))
        }

        do {
            try await repo.insertImported(toInsert)
        } catch {
            logger.error("Reminders import insert failed: \(error.localizedDescription, privacy: .public)")
            return Summary(imported: 0, total: total, skipped: total)
        }

        let imported = toInsert.count
        logger.info("Imported \(imported, privacy: .public) of \(total, privacy: .public) reminders")
        return Summary(imported: imported, total: total, skipped: total - imported)
    }

    /// De-dupe key: lowercased title + due-date day (NULL due treated as a
    /// matchable value so a re-run skips a previously-imported undated task).
    private func dedupeKey(title: String, dueDate: Date?) -> String {
        let day: String
        if let dueDate {
            let c = Calendar.current.dateComponents([.year, .month, .day], from: dueDate)
            day = "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
        } else {
            day = "nodate"
        }
        return title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) + "|" + day
    }
}

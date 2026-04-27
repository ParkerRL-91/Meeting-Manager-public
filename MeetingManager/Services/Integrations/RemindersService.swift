import EventKit
import Foundation
import os

/// Pushes action items to Apple Reminders via EventKit. No third-party dep.
///
/// Uses the modern `requestFullAccessToReminders()` API on macOS 14+,
/// falling back to the legacy `requestAccess(to:)` on earlier systems.
@MainActor
final class RemindersService {
    static let shared = RemindersService()

    private let store = EKEventStore()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.meetingmanager", category: "reminders")

    private init() {}

    // MARK: - Authorization

    var isAuthorized: Bool {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        if #available(macOS 14.0, *) {
            return status == .fullAccess
        }
        return status == .authorized
    }

    @discardableResult
    func requestAccess() async -> Bool {
        do {
            if #available(macOS 14.0, *) {
                return try await store.requestFullAccessToReminders()
            } else {
                return try await store.requestAccess(to: .reminder)
            }
        } catch {
            logger.error("Reminders access request failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - Lists

    func availableLists() -> [EKCalendar] {
        store.calendars(for: .reminder)
    }

    /// Resolves an EKCalendar from a stored identifier, falling back to the system default.
    func list(withIdentifier identifier: String?) -> EKCalendar? {
        if let id = identifier, !id.isEmpty,
           let match = store.calendars(for: .reminder).first(where: { $0.calendarIdentifier == id }) {
            return match
        }
        return store.defaultCalendarForNewReminders()
    }

    // MARK: - Add

    /// Adds a single ActionItem to Apple Reminders.
    /// Title format: "Assignee: Title" when assignee is present, otherwise just title.
    func add(_ item: ActionItem, list: EKCalendar? = nil) throws {
        let reminder = EKReminder(eventStore: store)
        let assigneePrefix: String? = {
            guard let assignee = item.assignee, !assignee.isEmpty else { return nil }
            return assignee
        }()
        reminder.title = assigneePrefix.map { "\($0): \(item.title)" } ?? item.title
        reminder.calendar = list ?? store.defaultCalendarForNewReminders()
        if let due = item.dueDate {
            reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day], from: due)
        }
        try store.save(reminder, commit: true)
        logger.info("Added action item to Reminders: \(item.title, privacy: .public)")
    }

    /// Adds multiple action items in a single batched commit.
    /// - Returns: number of items successfully added.
    @discardableResult
    func addAll(_ items: [ActionItem], list: EKCalendar? = nil) throws -> Int {
        let target = list ?? store.defaultCalendarForNewReminders()
        var added = 0
        for item in items {
            let reminder = EKReminder(eventStore: store)
            let prefix: String? = {
                guard let assignee = item.assignee, !assignee.isEmpty else { return nil }
                return assignee
            }()
            reminder.title = prefix.map { "\($0): \(item.title)" } ?? item.title
            reminder.calendar = target
            if let due = item.dueDate {
                reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day], from: due)
            }
            try store.save(reminder, commit: false)
            added += 1
        }
        try store.commit()
        logger.info("Batch-added \(added, privacy: .public) action items to Reminders")
        return added
    }
}

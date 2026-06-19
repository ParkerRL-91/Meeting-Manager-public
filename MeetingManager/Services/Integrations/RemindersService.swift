import EventKit
import Foundation
import os

/// Read-only bridge to Apple Reminders via EventKit. No third-party dep.
///
/// The outbound push was removed in PRJ-013 Phase 2 (the app is now the user's
/// own task manager). Read access is kept solely for the one-time import that
/// brings existing reminders across — see `TaskImportService`.
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

    // MARK: - Read (one-time import)

    /// Reads every reminder across all lists for the one-time import. Returns each
    /// reminder paired with its list title (mapped to a tag by `TaskImportService`).
    /// Wraps the callback-based `fetchReminders` in a continuation.
    func fetchReminders() async -> [(reminder: EKReminder, listTitle: String)] {
        let predicate = store.predicateForReminders(in: nil)
        let fetched: [EKReminder] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders ?? [])
            }
        }
        return fetched.map { ($0, $0.calendar?.title ?? "Reminders") }
    }
}

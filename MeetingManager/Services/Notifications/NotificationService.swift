import UserNotifications
import os

/// Manages local notifications for upcoming meeting reminders.
final class NotificationService: NSObject {

    private let center = UNUserNotificationCenter.current()

    // MARK: - Authorization

    /// Request notification authorization from the user.
    func requestAuthorization() async -> Bool {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            if granted {
                Logger.general.info("Notification authorization granted")
            } else {
                Logger.general.info("Notification authorization denied")
            }
            return granted
        } catch {
            Logger.general.error("Failed to request notification authorization: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Schedule

    /// Schedule a notification for an upcoming meeting.
    /// - Parameters:
    ///   - meeting: The meeting to notify about.
    ///   - leadTimeMinutes: How many minutes before the meeting to send the notification.
    func scheduleNotification(for meeting: Meeting, leadTimeMinutes: Int) {
        guard let scheduledStart = meeting.scheduledStartDate else {
            Logger.general.warning("Cannot schedule notification for meeting '\(meeting.title)' — no scheduled start date")
            return
        }

        let fireDate = scheduledStart.addingTimeInterval(-Double(leadTimeMinutes) * 60)

        // Don't schedule notifications in the past
        guard fireDate > Date() else {
            Logger.general.debug("Skipping notification for '\(meeting.title)' — fire date is in the past")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "Upcoming Meeting"
        content.body = "\(meeting.title) starts in \(leadTimeMinutes) minute\(leadTimeMinutes == 1 ? "" : "s")"
        content.sound = .default
        content.categoryIdentifier = NotificationActions.categoryIdentifier
        content.userInfo = ["meetingId": meeting.id]

        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: fireDate
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)

        let request = UNNotificationRequest(
            identifier: notificationIdentifier(for: meeting.id),
            content: content,
            trigger: trigger
        )

        center.add(request) { error in
            if let error {
                Logger.general.error("Failed to schedule notification for '\(meeting.title)': \(error.localizedDescription)")
            } else {
                Logger.general.info("Scheduled notification for '\(meeting.title)' at \(fireDate)")
            }
        }
    }

    // MARK: - Snooze

    /// Schedule a snooze notification for a meeting.
    /// - Parameters:
    ///   - meetingId: The meeting identifier.
    ///   - minutes: How many minutes to snooze.
    func scheduleSnooze(meetingId: String, minutes: Int) {
        let content = UNMutableNotificationContent()
        content.title = "Meeting Reminder (Snoozed)"
        content.body = "Your meeting is about to start"
        content.sound = .default
        content.categoryIdentifier = NotificationActions.categoryIdentifier
        content.userInfo = ["meetingId": meetingId]

        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: Double(minutes) * 60,
            repeats: false
        )

        let request = UNNotificationRequest(
            identifier: snoozeIdentifier(for: meetingId),
            content: content,
            trigger: trigger
        )

        center.add(request) { error in
            if let error {
                Logger.general.error("Failed to schedule snooze for meeting \(meetingId): \(error.localizedDescription)")
            } else {
                Logger.general.info("Snoozed notification for meeting \(meetingId) by \(minutes) minutes")
            }
        }
    }

    // MARK: - Cancel

    /// Cancel a pending notification for a specific meeting.
    func cancelNotification(meetingId: String) {
        let identifiers = [
            notificationIdentifier(for: meetingId),
            snoozeIdentifier(for: meetingId)
        ]
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        Logger.general.debug("Cancelled notifications for meeting \(meetingId)")
    }

    // MARK: - Reschedule All

    /// Cancel all pending meeting notifications and reschedule for the given meetings.
    /// - Parameters:
    ///   - meetings: The list of meetings to schedule notifications for.
    ///   - leadTimeMinutes: Lead time in minutes before each meeting.
    func rescheduleAll(meetings: [Meeting], leadTimeMinutes: Int) {
        // Remove all existing meeting notifications
        center.removeAllPendingNotificationRequests()
        Logger.general.info("Cleared all pending notifications, rescheduling \(meetings.count) meetings")

        for meeting in meetings {
            scheduleNotification(for: meeting, leadTimeMinutes: leadTimeMinutes)
        }
    }

    // MARK: - Identifiers

    private func notificationIdentifier(for meetingId: String) -> String {
        "meeting-\(meetingId)"
    }

    private func snoozeIdentifier(for meetingId: String) -> String {
        "meeting-snooze-\(meetingId)"
    }
}

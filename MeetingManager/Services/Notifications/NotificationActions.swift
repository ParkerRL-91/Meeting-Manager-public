import UserNotifications
import os

/// Defines notification action identifiers and registers the notification category for meeting alerts.
enum NotificationActions {

    // MARK: - Identifiers

    /// The category identifier for meeting alert notifications.
    static let categoryIdentifier = "MEETING_ALERT"

    /// Action to start recording the meeting immediately.
    static let startRecording = "START_RECORDING"

    /// Action to snooze the reminder for a few more minutes.
    static let snooze = "SNOOZE"

    /// Action to dismiss the notification without further action.
    static let dismiss = "DISMISS"

    // MARK: - Registration

    /// Register the meeting alert notification category with its associated actions.
    static func registerCategories() {
        let startAction = UNNotificationAction(
            identifier: startRecording,
            title: "Start Recording",
            options: [.foreground]
        )

        let snoozeAction = UNNotificationAction(
            identifier: snooze,
            title: "Snooze (5 min)",
            options: []
        )

        let dismissAction = UNNotificationAction(
            identifier: dismiss,
            title: "Dismiss",
            options: [.destructive]
        )

        let meetingCategory = UNNotificationCategory(
            identifier: categoryIdentifier,
            actions: [startAction, snoozeAction, dismissAction],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )

        UNUserNotificationCenter.current().setNotificationCategories([meetingCategory])
        Logger.general.info("Registered notification categories")
    }
}

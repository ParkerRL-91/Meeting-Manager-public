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

    /// Category for auto-detected meeting invites (call app / browser meet).
    static let meetingDetectedCategory = "MEETING_DETECTED"

    // MARK: - Registration

    /// Register all notification categories with their associated actions.
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

        // Scheduled meeting alert
        let meetingCategory = UNNotificationCategory(
            identifier: categoryIdentifier,
            actions: [startAction, snoozeAction, dismissAction],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )

        // Auto-detected call/meeting invite
        let detectedCategory = UNNotificationCategory(
            identifier: meetingDetectedCategory,
            actions: [startAction, dismissAction],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )

        UNUserNotificationCenter.current().setNotificationCategories([meetingCategory, detectedCategory])
        Logger.general.info("Registered notification categories")
    }
}

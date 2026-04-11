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

    /// Action to join the meeting (open video URL) and start recording.
    static let joinMeeting = "JOIN_MEETING"

    /// Action to dismiss the notification without further action.
    static let dismiss = "DISMISS"

    /// Action to open the meeting prep view for the notified meeting.
    static let prepMeeting = "PREP_MEETING"

    /// Action to share the meeting recap after a summary is generated.
    static let sendRecap = "SEND_RECAP"

    /// Category for post-meeting summary ready notifications.
    static let summaryReadyCategory = "SUMMARY_READY"

    /// Category for auto-detected meeting invites (call app / browser meet).
    static let meetingDetectedCategory = "MEETING_DETECTED"

    // MARK: - Registration

    /// Register all notification categories with their associated actions.
    static func registerCategories() {
        let joinAction = UNNotificationAction(
            identifier: joinMeeting,
            title: "Join & Record",
            options: [.foreground]
        )

        let startAction = UNNotificationAction(
            identifier: startRecording,
            title: "Record Only",
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

        let prepAction = UNNotificationAction(
            identifier: prepMeeting,
            title: "Prep",
            options: [.foreground]
        )

        // Scheduled meeting alert — Join & Record first (most useful action)
        let meetingCategory = UNNotificationCategory(
            identifier: categoryIdentifier,
            actions: [joinAction, prepAction, dismissAction],
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

        let shareRecapAction = UNNotificationAction(
            identifier: sendRecap,
            title: "View Recap",
            options: [.foreground]
        )

        // Summary ready — tapping the banner or View Recap navigates to the meeting
        let summaryReadyCat = UNNotificationCategory(
            identifier: summaryReadyCategory,
            actions: [shareRecapAction],
            intentIdentifiers: [],
            options: []
        )

        UNUserNotificationCenter.current().setNotificationCategories([meetingCategory, detectedCategory, summaryReadyCat])
        Logger.general.info("Registered notification categories")
    }
}

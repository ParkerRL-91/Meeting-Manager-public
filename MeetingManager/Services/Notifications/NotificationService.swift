import UserNotifications
import os

/// Manages local notifications for upcoming meeting reminders.
final class NotificationService: NSObject {

    private let center = UNUserNotificationCenter.current()
    private let prepService = MeetingPrepService()

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
    func scheduleNotification(for meeting: Meeting, leadTimeMinutes: Int) async {
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

        // Build enriched notification body from prep data
        let body = await enrichedBody(for: meeting, leadTimeMinutes: leadTimeMinutes)

        let content = UNMutableNotificationContent()
        content.title = "Upcoming Meeting"
        content.body = body
        content.sound = .default
        content.categoryIdentifier = NotificationActions.categoryIdentifier
        var userInfo: [String: String] = ["meetingId": meeting.id]
        if let meetLink = meeting.meetLink, !meetLink.isEmpty {
            userInfo["meetLink"] = meetLink
        }
        content.userInfo = userInfo

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

    // MARK: - Prep Enrichment

    /// Build an enriched notification body using prep context when available.
    /// Falls back to the simple lead-time text if no prep data is found.
    private func enrichedBody(for meeting: Meeting, leadTimeMinutes: Int) async -> String {
        let fallback = "\(meeting.title) starts in \(leadTimeMinutes) minute\(leadTimeMinutes == 1 ? "" : "s")"

        guard let brief = try? await prepService.prepBrief(for: meeting) else {
            return fallback
        }

        let participantCount = brief.participants.count
        let itemCount = brief.openActionItems.count
        let excerpt = brief.lastSummaryExcerpt

        // Only enrich when there is at least one piece of useful context
        guard participantCount > 0 || itemCount > 0 || excerpt != nil else {
            return fallback
        }

        // Build summary line: "Product Sync — 3 participants, 2 open items"
        var parts: [String] = []
        if participantCount > 0 {
            parts.append("\(participantCount) participant\(participantCount == 1 ? "" : "s")")
        }
        if itemCount > 0 {
            parts.append("\(itemCount) open item\(itemCount == 1 ? "" : "s")")
        }

        let summaryLine: String
        if parts.isEmpty {
            summaryLine = meeting.title
        } else {
            summaryLine = "\(meeting.title) — \(parts.joined(separator: ", "))"
        }

        // Append summary excerpt (truncated to ~100 chars) on a second line
        if let excerpt {
            let truncated = excerpt.count > 100 ? String(excerpt.prefix(100)) + "…" : excerpt
            return "\(summaryLine)\nLast time: \(truncated)"
        }

        return summaryLine
    }

    // MARK: - Morning Brief

    /// Schedule a daily morning briefing notification at the user-configured time.
    ///
    /// The notification repeats every day at the same hour/minute. It is idempotent —
    /// calling this multiple times replaces any existing morning brief notification.
    ///
    /// - Parameters:
    ///   - meetingCount: Total number of meetings today.
    ///   - openItemCount: Total number of open action items to follow up on.
    ///   - hour: Hour (0-23) to fire the notification.
    ///   - minute: Minute (0-59) to fire the notification.
    func scheduleMorningBrief(meetingCount: Int, openItemCount: Int, hour: Int = 8, minute: Int = 30) {
        let content = UNMutableNotificationContent()
        content.title = "Good morning! Your daily brief is ready."

        let meetingWord = meetingCount == 1 ? "meeting" : "meetings"
        if openItemCount > 0 {
            let itemWord = openItemCount == 1 ? "open item" : "open items"
            content.body = "You have \(meetingCount) \(meetingWord) today. \(openItemCount) \(itemWord) to follow up on."
        } else if meetingCount > 0 {
            content.body = "You have \(meetingCount) \(meetingWord) today."
        } else {
            content.body = "No meetings scheduled today. Enjoy your free time!"
        }

        content.sound = .default
        content.userInfo = ["type": "morningBrief"]

        var dateComponents = DateComponents()
        dateComponents.hour = hour
        dateComponents.minute = minute

        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)

        let request = UNNotificationRequest(
            identifier: morningBriefIdentifier,
            content: content,
            trigger: trigger
        )

        // Remove any existing morning brief before scheduling the new one
        center.removePendingNotificationRequests(withIdentifiers: [morningBriefIdentifier])
        center.add(request) { error in
            if let error {
                Logger.general.error("Failed to schedule morning brief notification: \(error.localizedDescription)")
            } else {
                Logger.general.info("Scheduled morning brief notification at \(hour):\(String(format: "%02d", minute))")
            }
        }
    }

    /// Cancel the recurring morning brief notification.
    func cancelMorningBrief() {
        center.removePendingNotificationRequests(withIdentifiers: [morningBriefIdentifier])
        Logger.general.info("Cancelled morning brief notification")
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
        // Only remove pre-meeting reminders ("meeting-<id>"); preserve user-initiated
        // snoozes ("meeting-snooze-<id>") and the recurring morning brief.
        center.getPendingNotificationRequests { [weak self] requests in
            guard let self else { return }
            let stale = requests
                .map(\.identifier)
                .filter { $0.hasPrefix("meeting-") && !$0.hasPrefix("meeting-snooze-") }
            if !stale.isEmpty {
                self.center.removePendingNotificationRequests(withIdentifiers: stale)
            }
            Logger.general.info("Cleared \(stale.count) pre-meeting notifications, rescheduling \(meetings.count) meetings")

            Task {
                for meeting in meetings {
                    await self.scheduleNotification(for: meeting, leadTimeMinutes: leadTimeMinutes)
                }
            }
        }
    }

    // MARK: - Identifiers

    private func notificationIdentifier(for meetingId: String) -> String {
        "meeting-\(meetingId)"
    }

    private func snoozeIdentifier(for meetingId: String) -> String {
        "meeting-snooze-\(meetingId)"
    }

    private var morningBriefIdentifier: String {
        "morning-brief"
    }
}

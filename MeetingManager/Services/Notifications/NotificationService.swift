import UserNotifications
import os

/// Manages local notifications for upcoming meeting reminders.
///
/// ## Reliability model
///
/// macOS' `UNUserNotificationCenter` has several quirks that historically
/// caused this app's reminders to silently no-op:
///
/// 1. `UNCalendarNotificationTrigger` matching to the second is fragile —
///    if the system clock drifts past the matched second before the
///    daemon evaluates the request, the notification is silently skipped.
///    This service drops `.second` from the components.
/// 2. `UNCalendarNotificationTrigger` for short-lead (≤24h) fires is
///    overkill and less reliable than `UNTimeIntervalNotificationTrigger`.
///    This service uses interval triggers for anything firing within
///    24 hours and reserves calendar triggers for meetings further out.
/// 3. `rescheduleAll` was previously a wipe-and-rebuild that left a
///    sub-second gap in which a near-firing notification could be lost.
///    This service now diffs against pending requests and only re-adds
///    those that actually changed.
/// 4. `center.add(request)` is fire-and-forget — its callback runs out
///    of band. This service awaits it with a continuation so the caller
///    knows whether the schedule actually landed.
final class NotificationService: NSObject {

    private let center = UNUserNotificationCenter.current()
    private let prepService = MeetingPrepService()

    // MARK: - Authorization

    /// Request notification authorization from the user.
    func requestAuthorization() async -> Bool {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            if granted {
                Logger.notifications.info("Notification authorization granted")
            } else {
                Logger.notifications.info("Notification authorization denied")
            }
            return granted
        } catch {
            Logger.notifications.error("Failed to request notification authorization: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Schedule

    /// Schedule a notification for an upcoming meeting.
    ///
    /// Picks the trigger type based on lead time:
    /// - `UNTimeIntervalNotificationTrigger` when fire is within 24h
    ///   (more reliable for short-lead, the common case).
    /// - `UNCalendarNotificationTrigger` (no `.second`) for fires more
    ///   than 24h out (so DST / clock drift doesn't slip the fire date).
    ///
    /// - Parameters:
    ///   - meeting: The meeting to notify about.
    ///   - leadTimeMinutes: How many minutes before the meeting to send.
    /// - Returns: True if the system accepted the schedule.
    @discardableResult
    func scheduleNotification(for meeting: Meeting, leadTimeMinutes: Int) async -> Bool {
        guard let scheduledStart = meeting.scheduledStartDate else {
            Logger.notifications.warning("[NotificationService] cannot schedule '\(meeting.title)' — no scheduled start date")
            return false
        }

        let now = Date()
        let fireDate = scheduledStart.addingTimeInterval(-Double(leadTimeMinutes) * 60)
        let secondsUntilFire = fireDate.timeIntervalSince(now)

        // Don't schedule notifications in the past. Also skip anything
        // firing in less than 1 second — UNNotificationCenter's minimum.
        guard secondsUntilFire >= 1 else {
            Logger.notifications.debug("[NotificationService] skipping '\(meeting.title)' — fire in \(Int(secondsUntilFire))s (already past or too close)")
            return false
        }

        // Build enriched body from prep data when available.
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

        // Pick trigger type by horizon.
        let trigger: UNNotificationTrigger
        if secondsUntilFire < 24 * 3600 {
            // Within 24 hours — use interval. Most reliable for short-lead.
            trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: secondsUntilFire,
                repeats: false
            )
        } else {
            // > 24h out — use calendar without `.second`. Reliable across DST,
            // sleep/wake transitions, and long device-off intervals.
            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: fireDate
            )
            trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        }

        let request = UNNotificationRequest(
            identifier: notificationIdentifier(for: meeting.id),
            content: content,
            trigger: trigger
        )

        // Wrap fire-and-forget add() in a continuation so we know the OS
        // actually accepted the schedule. Errors here would otherwise be
        // logged but invisible to the caller.
        return await withCheckedContinuation { continuation in
            center.add(request) { error in
                if let error {
                    Logger.notifications.error("[NotificationService] failed to schedule '\(meeting.title)': \(error.localizedDescription)")
                    continuation.resume(returning: false)
                } else {
                    Logger.notifications.info("[NotificationService] scheduled '\(meeting.title)' to fire in \(Int(secondsUntilFire))s (at \(fireDate)) link=\(meeting.meetLink != nil ? "yes" : "no")")
                    continuation.resume(returning: true)
                }
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
                Logger.notifications.error("Failed to schedule morning brief notification: \(error.localizedDescription)")
            } else {
                Logger.notifications.info("Scheduled morning brief notification at \(hour):\(String(format: "%02d", minute))")
            }
        }
    }

    /// Cancel the recurring morning brief notification.
    func cancelMorningBrief() {
        center.removePendingNotificationRequests(withIdentifiers: [morningBriefIdentifier])
        Logger.notifications.info("Cancelled morning brief notification")
    }

    // MARK: - Snooze

    /// Schedule a snooze notification for a meeting.
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
                Logger.notifications.error("Failed to schedule snooze for meeting \(meetingId): \(error.localizedDescription)")
            } else {
                Logger.notifications.info("Snoozed notification for meeting \(meetingId) by \(minutes) minutes")
            }
        }
    }

    // MARK: - Cancel

    /// Cancel every pending meeting reminder (and snooze) currently scheduled
    /// with the system. Used when the user has opted out of system-banner
    /// reminders in favour of the in-app HUD.
    func cancelAllMeetingNotifications() async {
        let pending = await pendingMeetingNotifications()
        let ids = pending.keys.filter { $0.hasPrefix("meeting-") }
        if !ids.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: Array(ids))
            Logger.notifications.info("[NotificationService] cancelled \(ids.count) pending meeting notification(s)")
        }
    }

    /// Cancel a pending notification for a specific meeting.
    func cancelNotification(meetingId: String) {
        let identifiers = [
            notificationIdentifier(for: meetingId),
            snoozeIdentifier(for: meetingId)
        ]
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        Logger.notifications.debug("Cancelled notifications for meeting \(meetingId)")
    }

    // MARK: - Reschedule All

    /// Diff-and-update reschedule. Reads currently pending notifications,
    /// computes the desired set of (meetingId, fireDate, hash) tuples,
    /// and only adds new / changed ones — leaving notifications that
    /// already match in place.
    ///
    /// This avoids the wipe-and-rebuild gap where a near-firing
    /// notification could be silently dropped because the recreate
    /// re-evaluated its fire date as "in the past."
    ///
    /// Body content (participant counts, prep excerpts) changing does
    /// NOT trigger a re-schedule — only the meetingId, fire time, and
    /// presence/value of meetLink do. That's intentional: prep enrichment
    /// can flap as the user adds notes; we don't want the underlying
    /// reminder to thrash.
    func rescheduleAll(meetings: [Meeting], leadTimeMinutes: Int) {
        Task {
            await self.rescheduleAllAsync(meetings: meetings, leadTimeMinutes: leadTimeMinutes)
        }
    }

    /// Async core of rescheduleAll. Public so AppState can `await` it
    /// during initial load and surface the result count.
    @discardableResult
    func rescheduleAllAsync(meetings: [Meeting], leadTimeMinutes: Int) async -> (added: Int, kept: Int, removed: Int) {
        let pending = await pendingMeetingNotifications()

        // Build desired set keyed by identifier.
        let leadSeconds = Double(leadTimeMinutes) * 60
        var desired: [String: ScheduledKey] = [:]
        for meeting in meetings {
            guard let start = meeting.scheduledStartDate else { continue }
            let fireDate = start.addingTimeInterval(-leadSeconds)
            // Skip past-fire meetings — same guard as scheduleNotification.
            guard fireDate.timeIntervalSinceNow >= 1 else { continue }
            let id = notificationIdentifier(for: meeting.id)
            desired[id] = ScheduledKey(
                fireDate: fireDate,
                hasLink: meeting.meetLink?.isEmpty == false
            )
        }

        // Identifiers we no longer want.
        let stale = pending.keys.filter { !$0.hasPrefix("meeting-snooze-") && desired[$0] == nil }
        if !stale.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: Array(stale))
        }

        // Add or update.
        var added = 0
        var kept = 0
        for (id, key) in desired {
            if let existing = pending[id], existing == key {
                kept += 1
                continue
            }
            // Either no pending entry, or fire date / link presence changed.
            // Remove the old (if any) and add fresh.
            if pending[id] != nil {
                center.removePendingNotificationRequests(withIdentifiers: [id])
            }
            if let meeting = meetings.first(where: { notificationIdentifier(for: $0.id) == id }) {
                let scheduled = await scheduleNotification(for: meeting, leadTimeMinutes: leadTimeMinutes)
                if scheduled { added += 1 }
            }
        }

        Logger.notifications.info("[NotificationService] rescheduleAll complete: added=\(added) kept=\(kept) removed=\(stale.count)")
        return (added, kept, stale.count)
    }

    /// Read pending notifications and decode the comparable scheduled-key
    /// for each meeting reminder request.
    private func pendingMeetingNotifications() async -> [String: ScheduledKey] {
        await withCheckedContinuation { continuation in
            center.getPendingNotificationRequests { requests in
                var result: [String: ScheduledKey] = [:]
                for req in requests where req.identifier.hasPrefix("meeting-") && !req.identifier.hasPrefix("meeting-snooze-") {
                    guard let fireDate = (req.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate()
                        ?? (req.trigger as? UNTimeIntervalNotificationTrigger)?.nextTriggerDate() else { continue }
                    let hasLink = (req.content.userInfo["meetLink"] as? String)?.isEmpty == false
                    result[req.identifier] = ScheduledKey(fireDate: fireDate, hasLink: hasLink)
                }
                continuation.resume(returning: result)
            }
        }
    }

    /// Comparable key — two requests with matching fire date (rounded to
    /// the nearest second) and matching link presence are interchangeable.
    private struct ScheduledKey: Equatable {
        let fireDate: Date
        let hasLink: Bool

        static func == (lhs: ScheduledKey, rhs: ScheduledKey) -> Bool {
            // Compare fire dates to second precision — sub-second drift on
            // pending-list reads shouldn't trigger an unnecessary reschedule.
            return abs(lhs.fireDate.timeIntervalSince(rhs.fireDate)) < 1
                && lhs.hasLink == rhs.hasLink
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

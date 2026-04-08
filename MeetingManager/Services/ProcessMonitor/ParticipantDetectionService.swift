import AppKit
import Foundation
import os

/// Detects meeting participants during a live recording.
///
/// **Priority order:**
/// 1. Calendar invite attendees — already written to `Meeting.participants` by `CalendarSyncManager`.
///    If the meeting has participants, this service never starts polling.
/// 2. Screen fallback — reads native app and browser window titles via CGWindowList
///    and AppleScript. Only runs when `meeting.participantList.isEmpty`.
///
/// Detected participants are stored in `Meeting.participants` (comma-separated),
/// matching the format used by the calendar path. No additional data model needed.
///
/// **Permissions:**
/// - CGWindowList requires Screen Recording permission (already used by BrowserCallDetector).
/// - AppleScript requires Automation permission for Chrome/Safari (already requested).
/// - Falls back gracefully (empty result, no crash) if permissions are unavailable.
///
/// **Platform note:**
/// `CGWindowListCopyWindowInfo` (title reads only) is used here — not `CGWindowListCreateImage`.
/// `CGWindowListCreateImage` is deprecated in macOS 15.0. Any future image-based detection
/// must use ScreenCaptureKit. This service only reads window metadata, which remains supported.
@MainActor
final class ParticipantDetectionService {

    // MARK: - State

    private var pollTimer: Timer?
    private(set) var detectedParticipants: [String] = []

    // MARK: - Dependencies

    private let meetingRepository: MeetingRepository
    private let database: AppDatabase

    init(meetingRepository: MeetingRepository, database: AppDatabase = .shared) {
        self.meetingRepository = meetingRepository
        self.database = database
    }

    deinit {
        pollTimer?.invalidate()
    }

    // MARK: - Lifecycle

    /// Start polling for participant names for a given meeting.
    /// - Parameters:
    ///   - meetingId: The meeting to update when participants are detected.
    ///   - existingParticipants: If non-empty, skips screen detection entirely
    ///     (calendar data is already good — no polling needed).
    func start(meetingId: String, existingParticipants: [String]) {
        // Primary source check: if calendar already provided participants, skip.
        guard existingParticipants.isEmpty else {
            Logger.general.info("ParticipantDetection: calendar has \(existingParticipants.count) participants — skipping screen detection")
            return
        }

        guard pollTimer == nil else { return }

        Logger.general.info("ParticipantDetection: starting screen fallback detection (30s interval)")

        pollTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.poll(meetingId: meetingId)
            }
        }
        pollTimer?.fire()
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        Logger.general.info("ParticipantDetection: stopped")
    }

    // MARK: - Polling

    private func poll(meetingId: String) {
        let detected = detectFromWindows()
        guard !detected.isEmpty else { return }

        // Found participants — stop polling (we have what we need)
        detectedParticipants = detected
        stop()

        // Persist to DB
        Task { [weak self] in
            guard let self else { return }
            await self.save(participants: detected, meetingId: meetingId)
        }
    }

    private func save(participants: [String], meetingId: String) async {
        do {
            try await database.writer.write { db in
                guard var meeting = try Meeting.fetchOne(db, key: meetingId) else { return }
                // Only write if still empty — don't overwrite if calendar sync ran in the meantime
                guard meeting.participants == nil || meeting.participants!.isEmpty else { return }
                meeting.participants = participants.joined(separator: ", ")
                try meeting.update(db)
            }
            Logger.general.info("ParticipantDetection: saved \(participants.count) participants for \(meetingId)")
        } catch {
            Logger.general.error("ParticipantDetection: failed to save participants: \(error.localizedDescription)")
        }
    }

    // MARK: - Window Title Detection

    /// Read meeting app window titles via CGWindowList and extract participant indicators.
    /// Returns an array of detected participant names/descriptions (never empty on success).
    private func detectFromWindows() -> [String] {
        guard let list = CGWindowListCopyWindowInfo(
            CGWindowListOption([.optionOnScreenOnly, .excludeDesktopElements]),
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        var found: [String] = []

        for window in list {
            guard let owner = window[kCGWindowOwnerName as String] as? String,
                  let title = window[kCGWindowName as String] as? String,
                  !title.isEmpty else { continue }

            // Try each known platform
            if let participants = extractParticipants(from: title, app: owner) {
                found.append(contentsOf: participants)
            }
        }

        return found.isEmpty ? [] : Array(Set(found)).sorted()
    }

    /// Parse window title for participant information by platform.
    ///
    /// Window title patterns (best-effort, vary by app version):
    /// - **Zoom**: Title bar may show "Zoom Meeting" or "Meeting with {Name}" when in small-window mode.
    ///   Zoom's main window title changes depending on layout.
    /// - **Google Meet** (browser): Tab title is typically "Meet — {meeting name}" or "{Name}'s meeting".
    ///   Full participant list is not in the title — detect meeting name only.
    /// - **Teams**: Main window title is "{Name} | Microsoft Teams" when in a call.
    /// - **FaceTime**: Window title shows participant name(s) when connected.
    ///
    /// Returns nil if no useful participant data found in this title.
    private func extractParticipants(from title: String, app: String) -> [String]? {
        switch app {
        case "zoom.us", "Zoom":
            return parseZoomTitle(title)
        case "Microsoft Teams":
            return parseTeamsTitle(title)
        case "FaceTime":
            return parseFaceTimeTitle(title)
        case "Google Chrome", "Safari", "Firefox", "Microsoft Edge", "Brave Browser":
            return parseBrowserMeetTitle(title)
        default:
            return nil
        }
    }

    private func parseZoomTitle(_ title: String) -> [String]? {
        // Zoom titles: "Zoom Meeting", "Meeting with Alice", "Alice Smith's Personal Meeting Room"
        // In mini-window or spotlight: "{Name}'s Meeting"
        if title.contains("Personal Meeting Room") || title == "Zoom Meeting" {
            return nil // Generic titles — no specific participant name
        }
        let withPatterns = ["Meeting with ", "Zoom Meeting with "]
        for pattern in withPatterns {
            if title.hasPrefix(pattern) {
                let name = String(title.dropFirst(pattern.count))
                    .replacingOccurrences(of: "'s Meeting", with: "")
                    .trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { return [name] }
            }
        }
        // "{Name}'s Personal Meeting Room" or "{Name}'s Meeting"
        if title.hasSuffix("'s Meeting") || title.hasSuffix("'s Personal Meeting Room") {
            let name = title
                .replacingOccurrences(of: "'s Personal Meeting Room", with: "")
                .replacingOccurrences(of: "'s Meeting", with: "")
                .trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { return [name] }
        }
        return nil
    }

    private func parseTeamsTitle(_ title: String) -> [String]? {
        // Teams: "{Name} | Microsoft Teams" when in a call with someone
        // Or: "Microsoft Teams" generically
        let suffix = " | Microsoft Teams"
        guard title.hasSuffix(suffix) else { return nil }
        let name = String(title.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty,
              name != "Microsoft Teams",
              name != "New meeting",
              name != "Calendar" else { return nil }
        return [name]
    }

    private func parseFaceTimeTitle(_ title: String) -> [String]? {
        // FaceTime shows participant name when connected: "FaceTime with Alice" or just "Alice"
        let prefix = "FaceTime with "
        if title.hasPrefix(prefix) {
            let name = String(title.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { return [name] }
        }
        // Active call window might just show the person's name
        if title != "FaceTime" && !title.isEmpty {
            return [title]
        }
        return nil
    }

    private func parseBrowserMeetTitle(_ title: String) -> [String]? {
        // Google Meet tab: "Meet — {meeting name}" or "{Name}'s meeting"
        // We can't reliably extract participant names from Meet titles (they show meeting name, not attendees)
        // Return nil — calendar attendees are the correct source for Meet participants
        let meetPrefixes = ["Meet — ", "Meet - "]
        for prefix in meetPrefixes {
            if title.hasPrefix(prefix) {
                return nil // Meeting name, not participant name
            }
        }
        return nil
    }
}

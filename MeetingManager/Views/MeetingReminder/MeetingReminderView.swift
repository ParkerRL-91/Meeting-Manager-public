import SwiftUI
import AppKit

enum MeetingReminderMode {
    /// Pre-meeting "starts in 1 min" reminder. Auto-dismisses, fires
    /// `.startRecording`, accent red.
    case upcoming
    /// "You're in another meeting — switch to this one?" Persistent until
    /// acted on, fires `.switchToMeeting`, accent orange.
    case `switch`
}

struct MeetingReminderView: View {
    let meeting: Meeting
    var mode: MeetingReminderMode = .upcoming
    let onDismiss: () -> Void

    private var timeString: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "h:mm a"
        fmt.amSymbol = "AM"
        fmt.pmSymbol = "PM"
        let start = meeting.scheduledStartDate.map { fmt.string(from: $0) } ?? ""
        let end   = meeting.scheduledEndDate.map   { fmt.string(from: $0) } ?? ""
        if start.isEmpty { return end }
        if end.isEmpty   { return start }
        return "\(start) – \(end)"
    }

    private var platform: MeetingPlatform {
        MeetingPlatform(from: meeting.meetLink)
    }

    var body: some View {
        HStack(spacing: 0) {

            // Left accent bar — red for an upcoming reminder, orange for
            // a switch offer (so users can tell at a glance).
            Rectangle()
                .fill(mode == .switch ? Color.orange : Color.red)
                .frame(width: 4)
                .clipShape(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 12, bottomLeadingRadius: 12,
                        bottomTrailingRadius: 0, topTrailingRadius: 0
                    )
                )

            // Meeting info
            VStack(alignment: .leading, spacing: 3) {
                if mode == .switch {
                    Text("Switch to next meeting")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.orange)
                        .textCase(.uppercase)
                        .tracking(0.5)
                }
                Text(meeting.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(timeString)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .frame(maxWidth: .infinity, alignment: .leading)

            // Action button block
            HStack(spacing: 0) {
                if let link = meeting.meetLink, !link.isEmpty {
                    // Primary action — varies by mode.
                    Button(action: {
                        if mode == .switch {
                            switchAndRecord()
                        } else {
                            joinAndStart(link: link)
                        }
                    }) {
                        HStack(spacing: 8) {
                            PlatformIcon(platform: platform)
                                .frame(width: 22, height: 22)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(mode == .switch ? "Switch & Record" : "Join Meeting")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.white)
                                Text(mode == .switch ? "stop current, start this one" : "& open Meeting Manager")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.white.opacity(0.65))
                            }
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 52)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    // Thin separator
                    Rectangle()
                        .fill(Color.white.opacity(0.12))
                        .frame(width: 1, height: 36)

                    // Chevron dropdown
                    Menu {
                        Button("Open Meeting Manager") { openApp() }
                        Button("Start Recording Only")  { startRecordingOnly() }
                        Divider()
                        Button("Dismiss")               { onDismiss() }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                            .frame(width: 32, height: 52)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()

                } else {
                    // No video link — offer open + record
                    Button(action: openAndRecord) {
                        HStack(spacing: 8) {
                            Image(systemName: "record.circle.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(.red)

                            VStack(alignment: .leading, spacing: 1) {
                                Text("Open & Record")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.white)
                                Text("open Meeting Manager")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.white.opacity(0.65))
                            }
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 52)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    // Thin separator
                    Rectangle()
                        .fill(Color.white.opacity(0.12))
                        .frame(width: 1, height: 36)

                    // Dismiss chevron
                    Menu {
                        Button("Dismiss") { onDismiss() }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                            .frame(width: 32, height: 52)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            .background(Color.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.trailing, 12)
        }
        .frame(height: 64)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: NSColor(red: 0.11, green: 0.11, blue: 0.13, alpha: 0.96)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.55), radius: 24, x: 0, y: 6)
        .padding(6)   // breathing room for the shadow
    }

    // MARK: - Actions

    private func joinAndStart(link: String) {
        if let url = URL(string: link) {
            NSWorkspace.shared.open(url)
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(
            name: .startRecording,
            object: nil,
            userInfo: ["meetingId": meeting.id]
        )
        onDismiss()
    }

    private func openApp() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        AppState.shared?.selectedMeetingId = meeting.id
        onDismiss()
    }

    private func startRecordingOnly() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(
            name: .startRecording,
            object: nil,
            userInfo: ["meetingId": meeting.id]
        )
        onDismiss()
    }

    private func openAndRecord() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(
            name: .startRecording,
            object: nil,
            userInfo: ["meetingId": meeting.id]
        )
        onDismiss()
    }

    /// Switch-mode primary action — AppState handles the stop+start sequence.
    private func switchAndRecord() {
        NotificationCenter.default.post(
            name: .switchToMeeting,
            object: nil,
            userInfo: ["meetingId": meeting.id]
        )
        onDismiss()
    }
}

// MARK: - Platform Icon

/// Tries to resolve the real installed app icon; falls back to a coloured SF symbol.
private struct PlatformIcon: View {
    let platform: MeetingPlatform

    var body: some View {
        if let icon = platform.appIcon {
            Image(nsImage: icon)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: "video.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(platform.symbolColor)
        }
    }
}

// MARK: - Meeting Platform

enum MeetingPlatform {
    case googleMeet, zoom, teams, webex, unknown

    init(from urlString: String?) {
        guard let u = urlString?.lowercased(), !u.isEmpty else { self = .unknown; return }
        if u.contains("meet.google.com")            { self = .googleMeet }
        else if u.contains("zoom.us")               { self = .zoom }
        else if u.contains("teams.microsoft.com") ||
                u.contains("teams.live.com")        { self = .teams }
        else if u.contains("webex.com")             { self = .webex }
        else                                        { self = .unknown }
    }

    var symbolColor: Color {
        switch self {
        case .googleMeet: return Color(red: 0.25, green: 0.72, blue: 0.42)
        case .zoom:       return Color(red: 0.18, green: 0.46, blue: 0.96)
        case .teams:      return Color(red: 0.38, green: 0.34, blue: 0.82)
        case .webex:      return Color(red: 0.10, green: 0.58, blue: 0.95)
        case .unknown:    return .white.opacity(0.8)
        }
    }

    /// Returns the installed app's icon, or nil if the app isn't on this machine.
    var appIcon: NSImage? {
        let bundleIds: [String]
        switch self {
        case .googleMeet: bundleIds = ["com.google.GoogleMeet"]
        case .zoom:       bundleIds = ["us.zoom.xos"]
        case .teams:      bundleIds = ["com.microsoft.teams2", "com.microsoft.teams"]
        case .webex:      bundleIds = ["com.cisco.webexmeetings", "Cisco-Systems.Spark"]
        case .unknown:    return nil
        }
        for id in bundleIds {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                return NSWorkspace.shared.icon(forFile: url.path)
            }
        }
        return nil
    }
}

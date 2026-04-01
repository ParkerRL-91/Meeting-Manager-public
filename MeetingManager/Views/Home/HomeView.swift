import SwiftUI

/// Dashboard shown when no meeting is selected. Inspired by Granola's "Coming Up" view.
/// Shows today's scheduled meetings with countdown timers and Start Now CTAs, followed by recent activity.
struct HomeView: View {
    @Environment(AppState.self) private var appState

    // Tick every 30 seconds to refresh countdowns
    @State private var now = Date()
    @State private var showAllRecent = false
    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                // MARK: - Date Header
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(todayString)
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(Color.appTextPrimary)
                        Text(dateString)
                            .font(.subheadline)
                            .foregroundStyle(Color.appTextSecondary)
                    }
                    Spacer()
                    // Quick action: new ad-hoc meeting
                    Button {
                        NotificationCenter.default.post(name: .createNewMeeting, object: nil)
                    } label: {
                        Label("New Meeting", systemImage: "plus")
                            .font(.subheadline.weight(.medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.appAccent)
                    .controlSize(.regular)
                }
                .padding(.horizontal, 24)
                .padding(.top, 28)
                .padding(.bottom, 20)

                // MARK: - Recording Banner
                if appState.isRecording, let activeMeeting = appState.activeMeeting {
                    ActiveRecordingBanner(meeting: activeMeeting)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 16)
                }

                // MARK: - Today's Meetings
                let todayMeetings = allToday
                if !todayMeetings.isEmpty {
                    SectionHeader(title: "Today")
                        .padding(.horizontal, 24)
                        .padding(.bottom, 10)

                    VStack(spacing: 8) {
                        ForEach(todayMeetings) { meeting in
                            UpcomingMeetingCard(meeting: meeting, now: now)
                                .onTapGesture {
                                    appState.selectedMeetingId = meeting.id
                                }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                } else {
                    // No meetings today
                    NoMeetingsTodayCard()
                        .padding(.horizontal, 24)
                        .padding(.bottom, 24)
                }

                // MARK: - Recent Meetings (exclude today — already shown above)
                let allRecent = recentMeetings
                let visibleRecent = showAllRecent ? allRecent : Array(allRecent.prefix(8))
                if !visibleRecent.isEmpty {
                    SectionHeader(title: "Recent")
                        .padding(.horizontal, 24)
                        .padding(.bottom, 10)

                    VStack(spacing: 6) {
                        ForEach(visibleRecent) { meeting in
                            RecentMeetingRow(meeting: meeting)
                                .onTapGesture {
                                    appState.selectedMeetingId = meeting.id
                                }
                        }
                    }
                    .padding(.horizontal, 24)

                    if allRecent.count > 8 {
                        Button(showAllRecent ? "Show less" : "Show \(allRecent.count - 8) more") {
                            withAnimation { showAllRecent.toggle() }
                        }
                        .font(.subheadline)
                        .foregroundStyle(Color.appAccent)
                        .buttonStyle(.plain)
                        .padding(.horizontal, 24)
                        .padding(.top, 6)
                    }
                    Spacer().frame(height: 32)
                }
            }
        }
        .background(Color.appBackground)
        .onReceive(timer) { date in
            now = date
        }
    }

    // MARK: - Computed

    private var todayString: String {
        let cal = Calendar.current
        if cal.isDateInToday(now) { return "Today" }
        return "Upcoming"
    }

    private var dateString: String {
        now.formatted(date: .complete, time: .omitted)
    }

    /// All meetings for today: upcoming + past, deduped and sorted by scheduled start.
    private var allToday: [Meeting] {
        let cal = Calendar.current
        func isToday(_ meeting: Meeting) -> Bool {
            guard let date = meeting.scheduledStartDate ?? meeting.startDate else { return false }
            return cal.isDateInToday(date)
        }
        let upcoming = appState.upcomingMeetings.filter(isToday)
        let past = appState.pastMeetings.filter(isToday)
        var seen = Set<String>()
        return (upcoming + past)
            .filter { seen.insert($0.id).inserted }
            .sorted {
                let da = $0.scheduledStartDate ?? $0.startDate ?? .distantFuture
                let db = $1.scheduledStartDate ?? $1.startDate ?? .distantFuture
                return da < db
            }
    }

    /// Past meetings excluding today (today's are shown in the Today section).
    private var recentMeetings: [Meeting] {
        let cal = Calendar.current
        return appState.pastMeetings.filter { meeting in
            guard let date = meeting.scheduledStartDate ?? meeting.startDate else { return true }
            return !cal.isDateInToday(date)
        }
    }
}

// MARK: - Section Header

private struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Color.appTextTertiary)
            .textCase(.uppercase)
            .tracking(0.8)
    }
}

// MARK: - Active Recording Banner

private struct ActiveRecordingBanner: View {
    let meeting: Meeting
    @Environment(AppState.self) private var appState
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color.appRecording)
                .frame(width: 10, height: 10)
                .opacity(pulse ? 0.3 : 1.0)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
                .onAppear { pulse = true }

            VStack(alignment: .leading, spacing: 2) {
                Text(appState.isReopening ? "Appending to recording" : "Recording in progress")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.appTextPrimary)
                Text(meeting.title)
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)
                    .lineLimit(1)
            }

            Spacer()

            Button("Open") {
                appState.selectedMeetingId = meeting.id
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.appRecording)
            .controlSize(.small)
        }
        .padding(14)
        .background(Color.appRecording.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.appRecording.opacity(0.3), lineWidth: 1)
        )
    }
}

// MARK: - Upcoming Meeting Card

private struct UpcomingMeetingCard: View {
    let meeting: Meeting
    let now: Date
    @Environment(AppState.self) private var appState

    private var scheduledDate: Date? {
        meeting.scheduledStartDate ?? meeting.startDate
    }

    private var minutesUntil: Int? {
        guard let date = scheduledDate else { return nil }
        let diff = date.timeIntervalSince(now)
        guard diff > 0 else { return nil }
        return Int(diff / 60)
    }

    private var isWithinHour: Bool {
        guard let date = scheduledDate else { return false }
        let diff = date.timeIntervalSince(now)
        return diff <= 3600
    }

    private var isPast: Bool {
        guard let date = scheduledDate else { return false }
        return date < now
    }

    private var statusLabel: String {
        if meeting.isReopenable { return "Ended" }
        if meeting.status == .complete { return "Complete" }
        if meeting.status == .cancelled { return "Cancelled" }
        if let mins = minutesUntil {
            if mins == 0 { return "Starting now" }
            if mins < 60 { return "In \(mins) min" }
            let hrs = mins / 60
            let rem = mins % 60
            return rem == 0 ? "In \(hrs)h" : "In \(hrs)h \(rem)m"
        }
        if isPast { return "In progress" }
        return ""
    }

    private var statusColor: Color {
        if meeting.isReopenable { return Color.appSuccess }
        if meeting.status == .complete { return Color.appTextTertiary }
        if let mins = minutesUntil {
            if mins <= 5 { return Color.appRecording }
            if mins <= 60 { return Color.appWarning }
            return Color.appTextSecondary
        }
        return Color.appSuccess
    }

    /// Returns (label, tint) for the CTA button, or nil if no CTA should be shown.
    private var ctaInfo: (label: String, tint: Color)? {
        guard !meeting.isAllDay else { return nil }
        if meeting.isReopenable { return ("Re-open recording", Color.appAccent) }
        guard meeting.status != .complete, meeting.status != .cancelled else { return nil }
        guard let start = scheduledDate else { return nil }
        let diff = start.timeIntervalSince(now)
        if diff > 3600 { return ("Start now", Color.appAccent) }
        return ("Record now", isWithinHour && !isPast ? Color.appWarning : Color.appRecording)
    }

    var body: some View {
        HStack(spacing: 14) {
            // Time column
            VStack(alignment: .trailing, spacing: 2) {
                if let date = scheduledDate {
                    Text(date, format: .dateTime.hour().minute())
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Color.appTextPrimary)
                    if let end = meeting.scheduledEndDate {
                        Text(end, format: .dateTime.hour().minute())
                            .font(.caption2)
                            .foregroundStyle(Color.appTextTertiary)
                    }
                }
            }
            .frame(width: 52, alignment: .trailing)

            // Left accent bar
            RoundedRectangle(cornerRadius: 2)
                .fill(isWithinHour ? statusColor : Color.appAccent)
                .frame(width: 3, height: 38)

            // Title + participant avatars
            VStack(alignment: .leading, spacing: 5) {
                Text(meeting.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.appTextPrimary)
                    .lineLimit(1)

                if !meeting.participantList.isEmpty {
                    HStack(spacing: -6) {
                        ForEach(Array(meeting.participantList.prefix(3).enumerated()), id: \.offset) { idx, name in
                            InitialsAvatar(name: name, size: 20, index: idx)
                        }
                        if meeting.participantList.count > 3 {
                            Text("+\(meeting.participantList.count - 3)")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Color.appTextSecondary)
                                .padding(.leading, 8)
                        }
                    }
                }
            }

            Spacer()

            // Status + CTA
            VStack(alignment: .trailing, spacing: 4) {
                if !statusLabel.isEmpty {
                    Text(statusLabel)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(statusColor)
                }

                if let cta = ctaInfo {
                    Button(cta.label) {
                        if meeting.isReopenable {
                            appState.startOrReopenRecording(for: meeting)
                        } else {
                            appState.startRecording(for: meeting)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(cta.tint)
                    .controlSize(.mini)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - No Meetings Today Card

private struct NoMeetingsTodayCard: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "calendar")
                .font(.title3)
                .foregroundStyle(Color.appTextTertiary)

            Text("No meetings scheduled for today")
                .font(.subheadline)
                .foregroundStyle(Color.appTextSecondary)

            Spacer()
        }
        .padding(16)
        .background(Color.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Recent Meeting Row

private struct RecentMeetingRow: View {
    let meeting: Meeting

    var body: some View {
        HStack(spacing: 12) {
            // Status dot
            Circle()
                .fill(meeting.status == .complete ? Color.appSuccess : Color.appTextTertiary)
                .frame(width: 7, height: 7)
                .padding(.leading, 4)

            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.title)
                    .font(.subheadline)
                    .foregroundStyle(Color.appTextPrimary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if let date = meeting.startDate ?? meeting.scheduledStartDate {
                        Text(relativeDate(date))
                            .font(.caption)
                            .foregroundStyle(Color.appTextSecondary)
                    }
                    let dur = meeting.formattedDuration
                    if dur != "--" {
                        Text("·")
                            .font(.caption)
                            .foregroundStyle(Color.appTextTertiary)
                        Text(dur)
                            .font(.caption)
                            .foregroundStyle(Color.appTextSecondary)
                    }
                }
            }

            Spacer()

            // Participant initials (up to 3)
            HStack(spacing: -6) {
                ForEach(Array(meeting.participantList.prefix(3).enumerated()), id: \.offset) { idx, name in
                    InitialsAvatar(name: name, size: 22, index: idx)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color.appSurface.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }

    private func relativeDate(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let days = cal.dateComponents([.day], from: date, to: Date()).day ?? 0
        if days < 7 { return "\(days)d ago" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

// MARK: - Initials Avatar

struct InitialsAvatar: View {
    let name: String
    var size: CGFloat = 28
    var index: Int = 0

    private static let avatarColors: [Color] = [
        Color.appAccent,
        .purple,
        .orange,
        .green,
        .pink,
        .teal
    ]

    private var initials: String {
        let parts = name.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        if parts.count >= 2 {
            return String(parts[0].prefix(1)) + String(parts[1].prefix(1))
        }
        return String(name.prefix(2)).uppercased()
    }

    private var backgroundColor: Color {
        InitialsAvatar.avatarColors[abs(name.hashValue) % InitialsAvatar.avatarColors.count]
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(backgroundColor.opacity(0.85))
                .frame(width: size, height: size)
                .overlay(Circle().stroke(Color.appBackground, lineWidth: 1.5))
            Text(initials)
                .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
        }
    }
}

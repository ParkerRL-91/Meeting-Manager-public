import SwiftUI

/// Dashboard shown when no meeting is selected. Inspired by Granola's "Coming Up" view.
/// Shows today's scheduled meetings with countdown timers and Start Now CTAs, followed by recent activity.
struct HomeView: View {
    @Environment(AppState.self) private var appState

    // Tick every 30 seconds to refresh countdowns
    @State private var now = Date()
    @State private var showAllRecent = false
    @State private var cachedAllToday: [Meeting] = []
    @State private var cachedRecentMeetings: [Meeting] = []
    @State private var prepBriefs: [String: MeetingPrepBrief] = [:]
    @State private var expandedCardIds: Set<String> = []
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
                let todayMeetings = cachedAllToday
                if !todayMeetings.isEmpty {
                    SectionHeader(title: "Today")
                        .padding(.horizontal, 24)
                        .padding(.bottom, 10)

                    VStack(spacing: 8) {
                        ForEach(todayMeetings) { meeting in
                            MeetingPrepCardView(
                                meeting: meeting,
                                prepBrief: prepBriefs[meeting.id],
                                now: now,
                                isExpanded: Binding(
                                    get: { expandedCardIds.contains(meeting.id) },
                                    set: { newValue in
                                        if newValue { expandedCardIds.insert(meeting.id) }
                                        else { expandedCardIds.remove(meeting.id) }
                                    }
                                )
                            )
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
                let allRecent = cachedRecentMeetings
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
        .onAppear {
            rebuildCache()
            loadPrepBriefs()
        }
        .onChange(of: appState.upcomingMeetings) { _, _ in
            rebuildCache()
            loadPrepBriefs()
        }
        .onChange(of: appState.pastMeetings) { _, _ in
            rebuildCache()
            loadPrepBriefs()
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

    // MARK: - Cache

    private func loadPrepBriefs() {
        Task {
            let service = MeetingPrepService()
            let meetings = cachedAllToday
            guard !meetings.isEmpty else { return }
            if let briefs = try? await service.prepBriefs(for: meetings) {
                await MainActor.run {
                    prepBriefs = briefs
                }
            }
        }
    }

    private func rebuildCache() {
        let cal = Calendar.current
        let isToday: (Meeting) -> Bool = { meeting in
            guard let date = meeting.scheduledStartDate ?? meeting.startDate else { return false }
            return cal.isDateInToday(date)
        }
        var seen = Set<String>()
        cachedAllToday = (appState.upcomingMeetings.filter(isToday)
                         + appState.pastMeetings.filter(isToday))
            .filter { seen.insert($0.id).inserted }
            .sorted {
                let da = $0.scheduledStartDate ?? $0.startDate ?? .distantFuture
                let db = $1.scheduledStartDate ?? $1.startDate ?? .distantFuture
                return da < db
            }
        cachedRecentMeetings = appState.pastMeetings.filter { !isToday($0) }
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

// InitialsAvatar moved to Views/Components/InitialsAvatar.swift

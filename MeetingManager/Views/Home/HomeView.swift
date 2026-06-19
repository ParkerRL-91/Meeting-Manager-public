import SwiftUI
import AppKit

/// Dashboard shown when no meeting is selected. Shows today's meetings and upcoming context.
/// Shows today's scheduled meetings with countdown timers and Start Now CTAs, followed by recent activity.
struct HomeView: View {
    @Environment(AppState.self) private var appState

    // Tick every 60 seconds to refresh countdowns
    @State private var now = Date()
    @State private var showAllRecent = false
    @State private var cachedAllToday: [Meeting] = []
    @State private var cachedRecentMeetings: [Meeting] = []
    @State private var prepBriefs: [String: MeetingPrepBrief] = [:]
    @State private var expandedCardIds: Set<String> = []
    @State private var prepBriefDebounce: DispatchWorkItem?
    @State private var authManager = GoogleAuthManager()
    @AppStorage("home.calendarBannerDismissed") private var calendarBannerDismissed: Bool = false
    @State private var openActionItems: [ActionItem] = []
    @State private var latestDigest: WeeklyDigestRecord?
    @State private var digestExpanded = false
    @State private var actionItemMeetingTitles: [String: String] = [:]
    private let timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                // Model download progress is rendered as a sidebar footer (see SidebarView)
                // so it doesn't compete with primary content.

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

                // MARK: - Calendar Connect Banner (subtle, dismissible)
                // Only nag about connecting Google Calendar if the user actually
                // wants Google as their calendar source. Users who picked Apple
                // Calendar (or none) shouldn't see this banner.
                if !authManager.isSignedIn
                    && cachedAllToday.isEmpty
                    && !calendarBannerDismissed
                    && (CalendarSource.current == .googleCalendar || CalendarSource.current == .both) {
                    CalendarConnectBanner(
                        onConnect: {
                            appState.pendingSettingsTab = 3
                            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                            NSApp.activate(ignoringOtherApps: true)
                        },
                        onDismiss: {
                            calendarBannerDismissed = true
                        }
                    )
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

                // MARK: - Processing strip (TASK-042) — what the queue is
                // doing right now, so "where's my summary" has an answer on
                // the home screen.
                if let running = appState.taskQueueManager.currentTask {
                    let pendingCount = appState.taskQueueManager.allTasks.filter { $0.status == .pending }.count
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("\(running.displayName)\(appState.taskQueueManager.currentProgress.map { " — \($0.stage)" } ?? "")\(pendingCount > 0 ? "  ·  \(pendingCount) queued" : "")")
                            .font(.caption)
                            .foregroundStyle(Color.appTextSecondary)
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
                }

                // MARK: - Open Action Items (TASK-042) — yesterday's
                // commitments are the first thing worth seeing in the morning.
                if !openActionItems.isEmpty {
                    SectionHeader(title: "Open Action Items")
                        .padding(.horizontal, 24)
                        .padding(.bottom, 10)
                    VStack(spacing: 6) {
                        ForEach(openActionItems.prefix(5)) { item in
                            HomeActionItemRow(
                                item: item,
                                meetingTitle: item.meetingId.flatMap { actionItemMeetingTitles[$0] },
                                onToggle: {
                                    guard let id = item.id else { return }
                                    Task {
                                        try? await ActionItemRepository(database: AppDatabase.shared).toggleComplete(id: id)
                                        await loadOpenActionItems()
                                    }
                                },
                                onOpenMeeting: { appState.selectedMeetingId = item.meetingId }
                            )
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                }

                // MARK: - Weekly digest (TASK-051) — collapsed card for the
                // most recent generated week.
                if let digest = latestDigest {
                    VStack(alignment: .leading, spacing: 8) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { digestExpanded.toggle() }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "calendar.badge.clock")
                                    .font(.caption)
                                    .foregroundStyle(Color.appAccent)
                                Text("Weekly digest — \(digest.isoWeek)")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(Color.appTextPrimary)
                                Spacer()
                                Image(systemName: digestExpanded ? "chevron.down" : "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(Color.appTextTertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if digestExpanded {
                            MarkdownRenderer(text: digest.content, baseFontSize: 13)
                        }
                    }
                    .padding(14)
                    .background(Color.appSurfaceSecondary.opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 24)
                    .padding(.bottom, 20)
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
        .task {
            await loadOpenActionItems()
            latestDigest = try? await WeeklyDigestRepository(database: AppDatabase.shared).latest()
        }
        .onChange(of: appState.upcomingMeetings) { _, _ in
            rebuildCache()
            prepBriefDebounce?.cancel()
            let work = DispatchWorkItem { loadPrepBriefs() }
            prepBriefDebounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        }
        .onChange(of: appState.pastMeetings) { _, _ in
            rebuildCache()
            prepBriefDebounce?.cancel()
            let work = DispatchWorkItem { loadPrepBriefs() }
            prepBriefDebounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
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

    private func loadOpenActionItems() async {
        let repo = ActionItemRepository(database: AppDatabase.shared)
        let items = (try? await repo.allOpenItems(limit: 10)) ?? []
        var titles: [String: String] = [:]
        for id in Set(items.compactMap(\.meetingId)) {
            titles[id] = (try? await appState.meetingRepository.find(id: id))?.title
        }
        openActionItems = items
        actionItemMeetingTitles = titles
    }

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
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "calendar")
                .font(.title3)
                .foregroundStyle(Color.appTextTertiary)

            Text("No meetings scheduled for today")
                .font(.subheadline)
                .foregroundStyle(Color.appTextSecondary)

            Spacer()

            Button {
                appState.startNewMeeting()
            } label: {
                Label("Start a meeting now", systemImage: "record.circle")
                    .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.appAccent)
            .controlSize(.small)
        }
        .padding(16)
        .background(Color.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Calendar Connect Banner

private struct CalendarConnectBanner: View {
    let onConnect: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "calendar")
                .font(.subheadline)
                .foregroundStyle(Color.appAccent)
                .frame(width: 18)

            Text("Connect calendar to see your meetings here")
                .font(.subheadline)
                .foregroundStyle(Color.appTextSecondary)
                .lineLimit(1)

            Spacer()

            Button("Connect") {
                onConnect()
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.appAccent)
            .controlSize(.small)

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    onDismiss()
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.appTextSecondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.appAccent.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.appAccent.opacity(0.25), lineWidth: 1)
        )
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

// MARK: - Home Action Item Row (TASK-042)

private struct HomeActionItemRow: View {
    let item: ActionItem
    let meetingTitle: String?
    let onToggle: () -> Void
    let onOpenMeeting: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onToggle) {
                Image(systemName: "circle")
                    .font(.body)
                    .foregroundStyle(Color.appTextSecondary)
            }
            .buttonStyle(.plain)
            .help("Mark complete")

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.subheadline)
                    .foregroundStyle(Color.appTextPrimary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let assignee = item.assignee, !assignee.isEmpty {
                        Text(assignee)
                            .font(.caption2)
                            .foregroundStyle(Color.appAccent)
                    }
                    if let meetingTitle {
                        Text(meetingTitle)
                            .font(.caption2)
                            .foregroundStyle(Color.appTextTertiary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer()

            Button(action: onOpenMeeting) {
                Image(systemName: "arrow.right.circle")
                    .font(.caption)
                    .foregroundStyle(Color.appTextTertiary)
            }
            .buttonStyle(.plain)
            .help("Open meeting")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.appSurfaceSecondary.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

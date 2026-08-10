import SwiftUI
import AppKit

/// Dashboard shown when no meeting is selected. Shows today's scheduled meetings
/// with countdown timers and Start Now CTAs, open action items, the AI briefing,
/// and the embedded Weekly Review section (TASK-138).
struct HomeView: View {
    @Environment(AppState.self) private var appState

    // Tick every 60 seconds to refresh countdowns
    @State private var now = Date()
    @State private var cachedAllToday: [Meeting] = []
    @State private var prepBriefs: [String: MeetingPrepBrief] = [:]
    @State private var expandedCardIds: Set<String> = []
    @State private var prepBriefDebounce: DispatchWorkItem?
    /// The shared instance from AppState, not a private one. A second
    /// GoogleAuthManager re-reads the Keychain on every Home mount, reports
    /// `isSignedIn == false` during its own async restore, and never sees a
    /// sign-out performed in Settings.
    private var authManager: GoogleAuthManager { appState.googleAuthManager }
    @AppStorage("home.calendarBannerDismissed") private var calendarBannerDismissed: Bool = false
    /// Episode id of the health banner the user dismissed. Deliberately `@State`,
    /// not `@AppStorage`: a dismissal must not outlive its failure episode. The
    /// `calendarBannerDismissed` flag above can be silenced forever, which is the
    /// pattern that let an 18-day sync outage go unnoticed.
    @State private var dismissedHealthEpisodeId: UUID?
    /// Episodes whose dismissal the 24-hour re-raise has already overridden, so a
    /// second dismissal of the same long outage still sticks.
    @State private var reRaisedHealthEpisodeIds: Set<UUID> = []
    @State private var openActionItems: [TaskItem] = []
    @State private var actionItemMeetingTitles: [String: String] = [:]
    // Categorized schedule + AI-briefing data (merged from the former Daily
    // Brief page). `nil` until the first `buildBrief` lands; `cachedAllToday`
    // renders as an instant skeleton until then.
    @State private var brief: DailyBrief?
    @State private var briefLoadFailed = false
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
                    // Quick action (TASK-121): context-sensitive New Meeting
                    // control. Opens the picker when the click maps to calendar
                    // meetings (or while recording); otherwise plain-clicks the
                    // app-wide fast path (`.createNewMeeting` → startNewMeeting).
                    NewMeetingButton(
                        style: .prominent,
                        primaryAction: {
                            NotificationCenter.default.post(name: .createNewMeeting, object: nil)
                        }
                    )
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

                // MARK: - Calendar Sync Health Banner
                // Ranked above the connect banner: a broken sync is more urgent
                // than an absent one, and the two are mutually exclusive (see
                // `showConnectBanner`). Health is `.unknown` until the Keychain
                // restore resolves AND a sync produces an outcome, so this cannot
                // flash during launch.
                if let reason = healthBannerReason,
                   let episodeId = appState.calendarSyncManager.healthEpisodeId,
                   dismissedHealthEpisodeId != episodeId {
                    CalendarSyncHealthBanner(
                        message: reason.bannerMessage,
                        onReconnect: {
                            // EXEMPT: user-driven OAuth handshake, not post-meeting
                            // AI/network work — TaskQueueManager doesn't apply.
                            Task {
                                if case .success = await appState.reconnectGoogleCalendar() {
                                    // `calendarBannerDismissed` is @AppStorage, so one
                                    // past click silences the connect banner forever.
                                    // A successful reconnect is the one moment we know
                                    // the user wants calendar state surfaced again.
                                    calendarBannerDismissed = false
                                }
                            }
                        },
                        onDismiss: { dismissedHealthEpisodeId = episodeId }
                    )
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
                }

                // MARK: - Calendar Connect Banner (subtle, dismissible)
                // Only nag about connecting Google Calendar if the user actually
                // wants Google as their calendar source. Users who picked Apple
                // Calendar (or none) shouldn't see this banner.
                // Brief-gated: only nag once the brief has loaded and confirmed
                // an empty day, so an async load can't flash the banner.
                if let brief, brief.meetings.isEmpty
                    && showConnectBanner
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

                // MARK: - Today's schedule (categorized time-rail)
                // First-paint rule: while `brief == nil`, render the cached
                // plain cards as an instant skeleton (no full-page spinner);
                // the rail + categories swap in when `buildBrief` lands. The
                // empty state gates on `brief != nil` so an async load can't
                // flash "No meetings today".
                if let brief {
                    if brief.meetings.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            NoMeetingsTodayCard()
                            // TASK-134: "no meetings" is a claim about the
                            // calendar, and a wedged sync produces exactly the
                            // same empty list as a genuinely free day.
                            if let caption = staleSyncCaption {
                                Text(caption)
                                    .font(.caption)
                                    .foregroundStyle(Color.appTextSecondary)
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.bottom, 24)
                    } else {
                        SectionHeader(title: "Today")
                            .padding(.horizontal, 24)
                            .padding(.bottom, 10)
                        HomeScheduleRail(brief: brief, now: now, expandedCardIds: $expandedCardIds)
                            .padding(.bottom, 24)
                    }
                } else {
                    if !cachedAllToday.isEmpty {
                        SectionHeader(title: "Today")
                            .padding(.horizontal, 24)
                            .padding(.bottom, 10)

                        VStack(spacing: 8) {
                            ForEach(cachedAllToday) { meeting in
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
                        // Match the rail's card x-position (56px time column +
                        // 17px dot lane + 4px padding each side) so the rail
                        // swapping in over the skeleton doesn't reflow the
                        // cards horizontally.
                        .padding(.leading, 81)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 24)
                    }

                    // buildBrief failed (brief stayed nil past the load
                    // attempt): say so instead of a silent forever-skeleton —
                    // the old Daily Brief page had an explicit error state.
                    if briefLoadFailed {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle")
                            Text("Couldn't load today's schedule details — showing basic cards. It retries when your meetings change.")
                        }
                        .font(.caption)
                        .foregroundStyle(Color.appTextSecondary)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 24)
                    }
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
                                        try? await TaskRepository(database: AppDatabase.shared).toggleComplete(id: id)
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

                // MARK: - AI Briefing (merged from the former Daily Brief page)
                // Collapsible; sits below the actionable content so a long
                // narrative can't push the morning to-do list below the fold.
                // NO view-level auto-generation kick and NO Ollama status
                // ping — generation runs only via the scheduler + the button.
                if let brief, !brief.meetings.isEmpty {
                    HomeAIBriefingSection(brief: brief)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 24)
                }

                // MARK: - Weekly Review (TASK-138) — the full former page, now
                // embedded: week picker, derived queue states, Generate/Refresh.
                WeeklyReviewSection()
                    .padding(.horizontal, 24)
                    .padding(.bottom, 32)
            }
        }
        .background(Color.appBackground)
        .onReceive(timer) { date in
            now = date
            // Reusing the existing 60s countdown tick rather than adding a timer.
            // This is what makes the one-hour staleness verdict appear (and the
            // overdue-sync catch-up fire) without the user navigating anywhere.
            appState.calendarSyncManager.refreshHealth(now: date)
            reRaiseAgedStaleDismissal(now: date)
        }
        .onAppear {
            rebuildCache()
            loadPrepBriefs()
        }
        .task {
            await loadOpenActionItems()
            await loadBrief()
        }
        .onChange(of: appState.upcomingMeetings) { _, _ in
            scheduleReactiveRefresh()
        }
        .onChange(of: appState.pastMeetings) { _, _ in
            scheduleReactiveRefresh()
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

    // MARK: - Calendar Sync Health

    /// The reason to show the health banner, or nil when there's nothing wrong.
    /// `.unknown` and `.healthy` both render nothing.
    private var healthBannerReason: CalendarHealthReason? {
        switch appState.calendarSyncManager.health {
        case .disconnected(let reason), .degraded(let reason): return reason
        case .unknown, .healthy: return nil
        }
    }

    /// Keeps the two calendar banners mutually exclusive. The `accessRevoked`
    /// check is a belt on top of the health verdict: it covers the window between
    /// `markAccessRevoked()` flipping `isSignedIn` false and the next
    /// `refreshHealth()`, during which the connect banner would otherwise
    /// briefly claim no calendar is connected at all.
    private var showConnectBanner: Bool {
        healthBannerReason == nil
            && !authManager.accessRevoked
            // Don't claim "no calendar connected" before the Keychain restore has
            // resolved — `isSignedIn` is false during that window even for a
            // signed-in user.
            && authManager.didAttemptSessionRestore
            && !authManager.isSignedIn
    }

    /// Caption for the empty-day card: names the age of the last good sync when
    /// it's old enough that an empty schedule is more likely a sync problem than
    /// a free day. Google-sourced only — the copy (and the sync it describes) is
    /// meaningless for an Apple-Calendar-only user. Silent when there is no
    /// successful sync on record at all; that state belongs to the connect /
    /// health banners above, which name it far more directly.
    private var staleSyncCaption: String? {
        guard CalendarSource.current == .googleCalendar || CalendarSource.current == .both,
              let last = appState.calendarSyncManager.effectiveLastSuccessfulSync,
              now.timeIntervalSince(last) > 6 * 60 * 60 else { return nil }
        return "Calendar last synced \(last.formatted(.relative(presentation: .named))) — this may not reflect your real schedule."
    }

    /// A `.syncStalled` episode keeps its identity for as long as the outage
    /// lasts, so one dismissal can hide a multi-day failure indefinitely.
    /// Forget the dismissal once the outage passes a day old — once per episode,
    /// so a second dismissal of the same outage still holds. The manager's episode
    /// identity is deliberately untouched; only this view's memory is cleared.
    private func reRaiseAgedStaleDismissal(now: Date) {
        guard let dismissed = dismissedHealthEpisodeId,
              !reRaisedHealthEpisodeIds.contains(dismissed),
              case .syncStalled(let since)? = healthBannerReason,
              now.timeIntervalSince(since) > 24 * 60 * 60 else { return }
        reRaisedHealthEpisodeIds.insert(dismissed)
        dismissedHealthEpisodeId = nil
    }

    // MARK: - Cache

    private func loadOpenActionItems() async {
        let repo = TaskRepository(database: AppDatabase.shared)
        let items = (try? await repo.allOpenItems(limit: 10)) ?? []
        var titles: [String: String] = [:]
        for id in Set(items.compactMap(\.meetingId)) {
            titles[id] = (try? await appState.meetingRepository.find(id: id))?.title
        }
        openActionItems = items
        actionItemMeetingTitles = titles
    }

    /// Rebuild the synchronous skeleton immediately, then debounce the richer
    /// `buildBrief` + prep-brief reload (Home's existing 0.5s debounce).
    private func scheduleReactiveRefresh() {
        rebuildCache()
        prepBriefDebounce?.cancel()
        let work = DispatchWorkItem {
            // prepBriefs only feeds the pre-brief skeleton; buildBrief computes
            // the same prep data internally, so skip once the rail is live —
            // otherwise every meeting-list change pays the prep pipeline twice.
            if brief == nil { loadPrepBriefs() }
            Task { await loadBrief() }
        }
        prepBriefDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Load the categorized brief and keep the sidebar needs-prep badge in
    /// sync (mirrors the former DailyBriefView.loadBrief). No AI kick here.
    @MainActor
    private func loadBrief() async {
        let service = DailyBriefService()
        do {
            let loaded = try await service.buildBrief(for: Date())
            brief = loaded
            briefLoadFailed = false
            appState.dailyBriefMeetingsNeedingPrep = loaded.meetingsNeedingPrep
        } catch {
            // Keep any previously-loaded brief; only flag when we have nothing
            // to show, so the gates (empty state / banner) don't stay shut
            // silently forever.
            if brief == nil { briefLoadFailed = true }
            appState.fileLog("Home: buildBrief failed — \(error.localizedDescription)")
        }
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
        VStack(alignment: .leading, spacing: 10) {
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

            // PRJ-014 discoverability hook (ported from Daily Brief empty
            // state): the KB sidebar item is hidden until a folder is
            // configured, so offer a way in from here.
            if !appState.kbConfigured {
                Button {
                    appState.pendingSettingsTab = 8   // Knowledge Base tab
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Text("Connect a Knowledge Base to ground briefs in your own documents →")
                        .font(.caption)
                        .foregroundStyle(Color.appAccent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .background(Color.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Calendar Sync Health Banner

/// Amber warning shown when calendar sync is broken, with a one-click reconnect.
/// Distinct from `CalendarConnectBanner` (blue, "you've never connected") both in
/// colour and in dismissal semantics — see `dismissedHealthEpisodeId`.
private struct CalendarSyncHealthBanner: View {
    let message: String
    let onReconnect: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.subheadline)
                .foregroundStyle(Color.appWarning)
                .frame(width: 18)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(Color.appTextSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            Button("Reconnect") {
                onReconnect()
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
            .accessibilityLabel("Dismiss calendar warning")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.appWarningSubtle)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.appWarning.opacity(0.3), lineWidth: 1)
        )
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

// InitialsAvatar moved to Views/Components/InitialsAvatar.swift
// SectionHeader moved to Views/Components/SectionHeader.swift (TASK-138)

// MARK: - Home Action Item Row (TASK-042)

private struct HomeActionItemRow: View {
    let item: TaskItem
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

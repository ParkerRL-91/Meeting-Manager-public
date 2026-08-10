import SwiftUI

/// The Weekly Review, embedded as a Home section (TASK-138) — a browsable
/// retrospective per ISO week: meetings held, decisions made, people, and
/// things worth revisiting, plus deterministic appendices (reversals,
/// relationship signals, meeting ROI, tracked topics). Auto-generated on the
/// first run after Friday 00:00 for the current week; any week can be
/// generated/refreshed on demand via the ◀ ▶ picker.
///
/// Always expanded and un-padded horizontally — `HomeView` owns the 24px
/// gutter and the scroll container. The initial week is
/// `WeeklyDigest.targetReviewWeek()` (the cadence's target), with a one-time
/// fallback to the newest STORED week so a first paint lands on a real review
/// rather than an empty state.
///
/// TASK-122: generation state is DERIVED from the durable task queue
/// (`taskQueueManager.allTasks`), not view-local flags. There is no poll — the
/// queue is `@Observable`, so navigating away and back re-derives live, and a
/// `.weeklyDigestCompleted` notification swaps in a finished review in place.
struct WeeklyReviewSection: View {
    @Environment(AppState.self) private var appState

    @State private var selectedWeek: String = WeeklyDigest.targetReviewWeek()
    @State private var record: WeeklyDigestRecord?
    @State private var isLoading = true
    /// Whether the selected week has any recorded meetings. Gates Generate:
    /// a meeting-less week has nothing to review. Defaults true so the button
    /// isn't disabled during the initial load flash.
    @State private var hasMeetings = true
    /// The newest-stored-week jump is one-shot: without this, a user who pages
    /// back to a week they haven't generated would be yanked forward again.
    @State private var didInitialFallback = false

    private var isCurrentWeekOrLater: Bool {
        selectedWeek >= WeeklyDigest.isoWeek()   // ISO week ids sort chronologically
    }

    // MARK: - Derived queue state

    /// The queue sentinel for the selected week.
    private var sentinel: String { "\(AppState.weeklyDigestSentinel):\(selectedWeek)" }

    /// Two-step derivation (a single `!isTerminal` filter can't render Failed —
    /// `.failed` IS terminal): the ACTIVE (pending/running) row for this week's
    /// sentinel, else the NEWEST `.failed` row for the same sentinel.
    private var digestTask: TaskQueueItem? {
        let tasks = appState.taskQueueManager.allTasks
        if let active = tasks.first(where: {
            $0.type == .weeklyDigest && $0.meetingId == sentinel
                && ($0.status == .pending || $0.status == .running)
        }) {
            return active
        }
        let latestFailed = tasks
            .filter { $0.type == .weeklyDigest && $0.meetingId == sentinel && $0.status == .failed }
            .max { $0.createdAt < $1.createdAt }
        // A failed row from BEFORE the currently-loaded review is stale — a
        // Retry that succeeded would otherwise leave the error card stacked on
        // top of the fresh review forever (terminal rows are never pruned).
        if let latestFailed, let record, record.createdAt > latestFailed.createdAt {
            return nil
        }
        return latestFailed
    }

    private enum DigestState: Equatable {
        case none
        case running(stage: String?)
        case retrying(error: String)
        case queuedUserInitiated(currentTaskName: String?)
        case queuedGoverned(currentTaskName: String?)
        case failed(error: String)
    }

    private var digestState: DigestState {
        guard let task = digestTask else { return .none }
        let tq = appState.taskQueueManager
        switch task.status {
        case .running:
            let isCurrent = tq.currentTask?.id == task.id
            return .running(stage: isCurrent ? tq.currentProgress?.stage : nil)
        case .pending:
            if let err = task.error, !err.isEmpty { return .retrying(error: err) }
            let currentName = tq.currentTask?.displayName
            return task.isUserInitiated
                ? .queuedUserInitiated(currentTaskName: currentName)
                : .queuedGoverned(currentTaskName: currentName)
        case .failed:
            return .failed(error: task.error ?? "Generation failed. Try again.")
        case .completed:
            return .none
        }
    }

    /// A pending/running row exists for this week — Generate/Refresh is disabled
    /// (clicking again would double-enqueue; use the state's own action button).
    private var isActive: Bool {
        digestTask.map { $0.status == .pending || $0.status == .running } ?? false
    }

    private var isNoneState: Bool { digestState == .none }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            content
        }
        .task(id: selectedWeek) { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .weeklyDigestCompleted)) { _ in
            Task { await load() }
        }
    }

    // MARK: - Header (section title + week picker + generate)

    private var header: some View {
        HStack(spacing: 12) {
            SectionHeader(title: "Weekly Review")

            Spacer()

            HStack(spacing: 4) {
                Button { shiftWeek(-1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Previous week")
                Text(weekLabel(selectedWeek))
                    .font(.callout.weight(.medium).monospacedDigit())
                    .foregroundStyle(Color.appTextSecondary)
                    .frame(minWidth: 140)
                    .multilineTextAlignment(.center)
                Button { shiftWeek(1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.plain)
                    .disabled(isCurrentWeekOrLater)
                    .accessibilityLabel("Next week")
            }

            Button {
                generate()
            } label: {
                Label(record == nil ? "Generate" : "Refresh",
                      systemImage: isActive ? "hourglass" : "arrow.clockwise")
            }
            .controlSize(.small)
            .disabled(isActive || !hasMeetings)
            .help(hasMeetings ? "" : "Nothing to review — no meetings this week")
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && record == nil {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if let record {
            VStack(alignment: .leading, spacing: 16) {
                if !isNoneState { statusCard }
                MarkdownRenderer(text: record.content, baseFontSize: 14, headingStyle: .neutral)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if isNoneState {
            emptyState
        } else {
            statusCard
        }
    }

    /// Renders whichever derived queue state is live. Returns nothing for
    /// `.none` (the caller decides what to show when there's no task).
    @ViewBuilder
    private var statusCard: some View {
        switch digestState {
        case .none:
            EmptyView()

        case .running(let stage):
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(stage ?? "Writing your weekly review…")
                    .font(.callout)
                    .foregroundStyle(Color.appTextSecondary)
            }
            .cardChrome()

        case .retrying(let error):
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "arrow.clockwise")
                    .foregroundStyle(Color.appTextTertiary)
                    .accessibilityHidden(true)
                // First sentence only — a multi-sentence error inside
                // parentheses reads as a run-on contradiction.
                Text("Last attempt failed (\(firstSentence(of: error))) — retrying automatically.")
                    .font(.callout)
                    .foregroundStyle(Color.appTextSecondary)
            }
            .accessibilityElement(children: .combine)
            .cardChrome()

        case .queuedUserInitiated(let currentTaskName):
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "clock")
                    .foregroundStyle(Color.appTextTertiary)
                    .accessibilityHidden(true)
                // Not "next" — pending pipeline rows (summary/cleanup) outrank
                // the manual tier, so promise sequence, not position.
                Text(currentTaskName.map {
                    "Queued behind the current task (\($0)). It will run as soon as current processing finishes."
                } ?? "Queued — it will run as soon as current processing finishes.")
                    .font(.callout)
                    .foregroundStyle(Color.appTextSecondary)
            }
            .accessibilityElement(children: .combine)
            .cardChrome()

        case .queuedGoverned(let currentTaskName):
            VStack(alignment: .leading, spacing: 8) {
                // Combine the prose for VoiceOver but keep the button its own
                // element — combining the whole card would swallow it.
                VStack(alignment: .leading, spacing: 8) {
                    Text("Queued — waiting for a quiet moment. Background AI pauses while you're recording, using AI chat, on battery, near a meeting start, or under thermal pressure; it will complete automatically.")
                        .font(.callout)
                        .foregroundStyle(Color.appTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let currentTaskName {
                        Text("Will run after: \(currentTaskName)")
                            .font(.caption)
                            .foregroundStyle(Color.appTextTertiary)
                    }
                }
                .accessibilityElement(children: .combine)
                Button("Generate now") { generate() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help("Runs immediately — even during a recording.")
            }
            .cardChrome()

        case .failed(let error):
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(Color.appTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                Button("Retry") { generate() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .cardChrome()
        }
    }

    /// First sentence of an error message, for inline embedding.
    private func firstSentence(of text: String) -> String {
        if let dot = text.firstIndex(of: ".") {
            return String(text[..<dot])
        }
        return text
    }

    private var emptyState: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "calendar.badge.checkmark")
                .font(.system(size: 28))
                .foregroundStyle(Color.appTextTertiary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                if hasMeetings {
                    Text("No review for this week yet")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Color.appTextSecondary)
                    Text("Generate a retrospective of the meetings, decisions, and open threads from \(weekLabel(selectedWeek)).")
                        .font(.subheadline)
                        .foregroundStyle(Color.appTextTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Generate Weekly Review") { generate() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .padding(.top, 2)
                } else {
                    Text("Nothing to review — no meetings this week")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Color.appTextSecondary)
                    Text("Weekly reviews summarize the meetings you recorded during \(weekLabel(selectedWeek)). This week has none yet.")
                        .font(.subheadline)
                        .foregroundStyle(Color.appTextTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .cardChrome()
    }

    // MARK: - Actions

    private func shiftWeek(_ delta: Int) {
        guard let range = WeeklyDigest.range(forISOWeek: selectedWeek) else { return }
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = .current
        guard let shifted = cal.date(byAdding: .day, value: 7 * delta, to: range.start) else { return }
        let newWeek = WeeklyDigest.isoWeek(for: shifted)
        // Don't navigate past the current calendar week.
        if newWeek <= WeeklyDigest.isoWeek() { selectedWeek = newWeek }
    }

    /// Enqueue (or expedite) generation for the selected week. All paths route
    /// through here — the header button, "Generate now", and "Retry" — because
    /// `enqueueWeeklyReviewGeneration` is week-scoped: a same-week pending row is
    /// expedited, a terminal/absent one is freshly enqueued. No poll follows:
    /// the derived state re-renders from the observable queue.
    private func generate() {
        appState.enqueueWeeklyReviewGeneration(isoWeek: selectedWeek)
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        let repo = WeeklyDigestRepository(database: appState.database)
        record = try? await repo.digest(isoWeek: selectedWeek)
        hasMeetings = await weekHasMeetings(selectedWeek)

        // `targetReviewWeek()` names the week the CADENCE targets, which is
        // empty until that week's review is written. Embedded on Home nobody
        // drives the picker, so a first paint would show an empty state while
        // a perfectly good review sat one week back. Jump to the newest stored
        // week instead — once, and only when this week has neither a review
        // nor a live generation to show.
        let isFirstLoad = !didInitialFallback
        didInitialFallback = true
        if isFirstLoad, record == nil, digestTask == nil,
           let newest = try? await repo.newest(), newest.isoWeek != selectedWeek {
            selectedWeek = newest.isoWeek   // retriggers `.task(id:)`
        }
    }

    /// Cheap presence check mirroring the generator's own window filter
    /// (`generateWeeklyDigest`) — reuses the meeting repository the generator
    /// reads, so "disable Generate" and "the guard throws" agree.
    private func weekHasMeetings(_ week: String) async -> Bool {
        guard let wr = WeeklyDigest.range(forISOWeek: week) else { return true }
        let all = (try? await appState.meetingRepository.allActiveMeetings()) ?? []
        return all.contains { $0.effectiveDate >= wr.start && $0.effectiveDate < wr.end }
    }

    // MARK: - Formatting

    /// "Jun 30 – Jul 6" for a week id, or the raw id if it can't be ranged.
    private func weekLabel(_ id: String) -> String {
        guard let range = WeeklyDigest.range(forISOWeek: id) else { return id }
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = .current
        let lastDay = cal.date(byAdding: .day, value: -1, to: range.end) ?? range.end
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d"
        fmt.locale = Locale.current
        return "\(fmt.string(from: range.start)) – \(fmt.string(from: lastDay))"
    }
}

private extension View {
    /// Shared surface chrome for the derived-state status cards.
    func cardChrome() -> some View {
        self
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color.appSurfaceSecondary.opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

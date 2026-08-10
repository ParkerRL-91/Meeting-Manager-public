import SwiftUI

/// Context-sensitive "New Meeting" control (TASK-121, restructured from the
/// TASK-119 split button). The whole control is ONE region:
///
/// - When the app can map the click to something — any cached candidate
///   (nearby recordable event, reopenable meeting) OR a live recording — the
///   control is a `Menu`. Clicking it opens the picker so the calendar bind is
///   visible: pick a specific event, resume, or start a blank unlinked meeting.
///   While recording, the rows become "Switch to: …" actions.
/// - When there are no candidates and nothing is recording, the control is a
///   plain `Button` whose action is the host's `primaryAction` — the silent
///   smart-match fast path (`startNewMeeting()`), which self-heals under a stale
///   cache and preserves the TASK-032 re-attach path.
///
/// The cached `appState.newMeetingCandidates` decides Menu-vs-Button *shape*
/// synchronously at render time; the menu's rows still load fresh from
/// `AppState.newMeetingOptions()` when it opens, so a stale cache can never
/// produce a dead menu (the blank "New Meeting — no calendar link" row is
/// always present).
struct NewMeetingButton: View {
    enum Style { case full, compact, prominent }

    let style: Style
    /// Runs on a plain-click (no-candidate) fast path, and on the preview
    /// "(default)" row. Each host preserves its own exact route (sidebar calls
    /// `startNewMeeting()`, popover/Home post the app-wide `.createNewMeeting`);
    /// both end at `startNewMeeting()`.
    let primaryAction: () -> Void
    /// Runs after any menu-row action fires (e.g. dismiss the popover).
    var onSelect: () -> Void = {}

    @Environment(AppState.self) private var appState
    @State private var options: AppState.NewMeetingOptions?
    /// Hover highlight for the `.compact` menu-bar-popover row (TASK-126) so it
    /// matches the sibling menu-zone rows' hover. Compact only.
    @State private var compactHovering = false

    /// Menu when the click maps to something; plain Button otherwise.
    private var showsMenu: Bool {
        appState.isRecording || !appState.newMeetingCandidates.isEmpty
    }

    var body: some View {
        switch style {
        case .full:      fullControl
        case .compact:   compactControl
        case .prominent: prominentControl
        }
    }

    // MARK: - Full (sidebar)

    private var fullControl: some View {
        Group {
            if showsMenu {
                Menu { menuContent } label: { fullLabel }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
            } else {
                Button(action: primaryAction) { fullLabel }
                    .buttonStyle(.plain)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4]))
                .foregroundStyle(Color.appBorderStrongest)
        )
        .help(helpText)
        .accessibilityLabel("New meeting")
        .accessibilityHint(accessibilityHint)
    }

    private var fullLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .semibold))
            Text("New Meeting")
                .font(.system(size: 12.5, weight: .medium))
            // Menu mode must be visually distinct from instant-start mode —
            // the two behaviors differ in side effects (a click either opens
            // the picker or begins a recording).
            if showsMenu {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.appTextTertiary)
            }
        }
        .foregroundStyle(Color.appTextSecondary)
        .frame(maxWidth: .infinity)
        .frame(height: 30)
        .contentShape(Rectangle())
    }

    // MARK: - Compact (menu bar popover)

    private var compactControl: some View {
        Group {
            if showsMenu {
                Menu { menuContent } label: { compactLabel }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
            } else {
                Button(action: primaryAction) { compactLabel }
                    .buttonStyle(.plain)
            }
        }
        .help(helpText)
        .accessibilityLabel("New meeting")
        .accessibilityHint(accessibilityHint)
    }

    private var compactLabel: some View {
        HStack(spacing: 11) {
            Image(systemName: "plus.rectangle")
                .font(.system(size: 14))
                .foregroundStyle(Color.appTextSecondary)
                .frame(width: 18)
            Text("New Meeting")
                .font(.system(size: 13))
                .foregroundStyle(Color.appTextPrimary)
            Spacer()
            // The ⌘N hint only makes sense on the plain-click fast path — in menu
            // mode a click opens the picker, so showing "⌘N" would imply click ≡ ⌘N.
            // The chevron makes menu mode visually distinct (side effects differ:
            // picker vs instant recording start).
            if showsMenu {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.appTextTertiary)
            } else {
                Text("\u{2318}N")
                    .font(.system(size: 11).monospaced())
                    .foregroundStyle(Color.appTextMuted)
            }
        }
        .contentShape(Rectangle())
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(compactHovering ? Color.appSurfaceSecondary : Color.clear)
        )
        .onHover { compactHovering = $0 }
    }

    // MARK: - Prominent (Home header)

    private var prominentControl: some View {
        Group {
            if showsMenu {
                Menu { menuContent } label: { prominentLabel }
                    .menuStyle(.button)
            } else {
                Button(action: primaryAction) { prominentLabel }
            }
        }
        .buttonStyle(.borderedProminent)
        .tint(Color.appAccent)
        .controlSize(.regular)
        .help(helpText)
        .accessibilityLabel("New meeting")
        .accessibilityHint(accessibilityHint)
    }

    private var prominentLabel: some View {
        Label("New Meeting", systemImage: "plus")
            .font(.subheadline.weight(.medium))
    }

    // MARK: - Help / accessibility (per mode)

    private var helpText: String {
        showsMenu ? "Choose which meeting to record" : "New Meeting (\u{2318}N)"
    }

    private var accessibilityHint: String {
        if appState.isRecording {
            return "Opens a menu to switch the current recording to another meeting."
        }
        return showsMenu
            ? "Opens a menu to pick which meeting to record or start a blank one."
            : "Starts a new meeting recording."
    }

    // MARK: - Menu content (loaded async on open)

    @ViewBuilder private var menuContent: some View {
        Group {
            if let options {
                // Branch on LIVE recording state — the cached options struct can
                // be stale for a beat when the menu reopens across a recording
                // transition, which would render start-rows during a recording.
                if appState.isRecording {
                    switchRows(options)
                } else {
                    startRows(options)
                }
            } else {
                Text("Loading\u{2026}")
            }
        }
        .task { options = await appState.newMeetingOptions() }
    }

    // MARK: - Idle rows

    @ViewBuilder private func startRows(_ o: AppState.NewMeetingOptions) -> some View {
        // Row 1 — smart-match preview: exactly what a plain click binds to.
        switch o.previewTarget {
        case .reopen(let m):
            Button("Resume \(m.title)  (default)") { primaryAction(); onSelect() }
                .accessibilityLabel("Resume \(m.title), default")
        case .scheduled(let m):
            Button("\(recordLabel(m))  (default)") { primaryAction(); onSelect() }
                .accessibilityLabel("\(recordLabel(m)), default")
        case .adHoc:
            EmptyView()
        }

        // Nearby recordable calendar events (±30 min), minus the preview row.
        // Capped + sorted by proximity so a stacked calendar day can't produce a
        // huge menu (row cap 5 total; preview + reopenable always survive).
        ForEach(cappedNearby(o)) { m in
            Button(recordLabel(m)) { appState.startMeeting(boundTo: m); onSelect() }
        }

        // Resume row if a distinct reopenable meeting exists (usually none —
        // reopenable wins the preview row when present).
        if let r = o.reopenable {
            Button("Resume \(r.title)") { appState.startMeeting(boundTo: r); onSelect() }
        }

        // No leading divider when the fresh fetch came back empty (stale cache
        // opened the menu but there's nothing above the blank row).
        if !isAdHoc(o.previewTarget) || !o.nearbyEvents.isEmpty || o.reopenable != nil {
            Divider()
        }

        Button(blankLabel(isDefault: isAdHoc(o.previewTarget))) {
            appState.startBlankMeeting(); onSelect()
        }
        .accessibilityLabel(blankLabel(isDefault: isAdHoc(o.previewTarget)))
    }

    // MARK: - While-recording rows (switch actions)

    @ViewBuilder private func switchRows(_ o: AppState.NewMeetingOptions) -> some View {
        let candidates = switchCandidates(o)
        ForEach(candidates) { m in
            Button("Switch to: \(titleTime(m)) — stops current recording") {
                appState.acceptSwitchSuggestion(overrideMeeting: m); onSelect()
            }
            .accessibilityLabel("Switch to \(titleTime(m)), stops current recording")
        }
        if !candidates.isEmpty { Divider() }
        Button("Switch to blank meeting — stops current recording") {
            appState.switchToBlankMeeting(); onSelect()
        }
        .accessibilityLabel("Switch to blank meeting, stops current recording")
    }

    // MARK: - Helpers

    /// Nearby events capped so the total candidate rows stay ≤ 5, sorted by
    /// |now − scheduledStart|. The preview row and a distinct reopenable row are
    /// reserved (they always survive the cap); the remainder is filled by the
    /// closest nearby events.
    private func cappedNearby(_ o: AppState.NewMeetingOptions) -> [Meeting] {
        let reserved = (o.previewMeeting != nil ? 1 : 0) + (o.reopenable != nil ? 1 : 0)
        let limit = max(0, 5 - reserved)
        return Array(
            o.nearbyEvents
                .sorted { AppState.candidateProximity($0) < AppState.candidateProximity($1) }
                .prefix(limit)
        )
    }

    private func switchCandidates(_ o: AppState.NewMeetingOptions) -> [Meeting] {
        var result: [Meeting] = []
        if let preview = o.previewMeeting { result.append(preview) }
        result.append(contentsOf: o.nearbyEvents)
        if let r = o.reopenable { result.append(r) }
        var seen = Set<String>()
        let deduped = result.filter { seen.insert($0.id).inserted }
        return Array(
            deduped
                .sorted { AppState.candidateProximity($0) < AppState.candidateProximity($1) }
                .prefix(5)
        )
    }

    private func recordLabel(_ m: Meeting) -> String {
        if let t = timeString(m) { return "Record: \(m.title) (\(t))" }
        return "Record: \(m.title)"
    }

    private func titleTime(_ m: Meeting) -> String {
        if let t = timeString(m) { return "\(m.title) (\(t))" }
        return m.title
    }

    private func timeString(_ m: Meeting) -> String? {
        guard let d = m.scheduledStartDate else { return nil }
        return d.formatted(date: .omitted, time: .shortened)
    }

    private func blankLabel(isDefault: Bool) -> String {
        isDefault
            ? "New Meeting — no calendar link  (default)"
            : "New Meeting — no calendar link"
    }

    private func isAdHoc(_ target: AppState.NewMeetingTarget) -> Bool {
        if case .adHoc = target { return true }
        return false
    }
}

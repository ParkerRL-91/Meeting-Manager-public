import SwiftUI
import AppKit
import os

/// Full-page daily briefing view showing all of today's meetings with prep context
/// and an optional AI-generated narrative overview.
struct DailyBriefView: View {

    // MARK: - State

    @Environment(AppState.self) private var appState

    @State private var dailyBrief: DailyBrief?
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var expandedMeetingIds: Set<String> = []

    // Tick every 60 seconds so countdown labels ("In 5 min", "In progress") stay current
    @State private var now = Date()
    private let timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    private let service = DailyBriefService()
    private let date: Date

    init(date: Date = Date()) {
        self.date = date
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerSection
                    .padding(.horizontal, 20)
                    .padding(.top, 20)

                if isLoading {
                    loadingState
                } else if let error = loadError {
                    errorState(error)
                } else if let brief = dailyBrief {
                    if brief.meetings.isEmpty {
                        emptyState
                    } else {
                        meetingsList(brief: brief)

                        if let aiText = appState.dailyBriefAIText {
                            aiBriefSection(text: aiText)
                                .padding(.horizontal, 20)
                        } else if appState.isGeneratingDailyBrief {
                            generatingPlaceholder
                                .padding(.horizontal, 20)
                        } else if !isAIConfigured {
                            aiSetupCard
                                .padding(.horizontal, 20)
                        }

                        if appState.dailyBriefQueued {
                            HStack(spacing: 6) {
                                Image(systemName: "clock.badge.checkmark")
                                Text("Daily brief queued — it will generate automatically once the current transcriptions finish.")
                            }
                            .font(.caption)
                            .foregroundStyle(Color.appTextSecondary)
                            .padding(.horizontal, 20)
                        } else if let error = appState.dailyBriefError {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(Color.appRecording)
                                .padding(.horizontal, 20)
                        }
                    }
                }

                Spacer(minLength: 40)
            }
        }
        .background(Color.appBackground)
        .task {
            // Kick the Ollama status check in parallel so the "Set up AI"
            // CTA doesn't appear stale on first paint. The brief itself
            // doesn't need this to load.
            async let _ = appState.ollamaService.refreshStatus()
            await loadBrief()
            // If the AI brief hasn't been generated yet for today, kick it
            // off now. The scheduler also fires from calendar sync and the
            // hourly safety net, but a user opening the view shouldn't have
            // to wait for either of those.
            if appState.dailyBriefAIText == nil && !appState.isGeneratingDailyBrief {
                await appState.maybeRegenerateDailyBrief(brief: dailyBrief, force: false)
            }
        }
        .onReceive(timer) { date in
            now = date
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Daily Brief")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Color.appTextPrimary)
                    .tracking(-0.4)
                Text(date, format: .dateTime.weekday(.wide).month(.wide).day())
                    .font(.system(size: 13))
                    .foregroundStyle(Color.appTextTertiary)
            }

            Spacer()

            if let brief = dailyBrief, !brief.meetings.isEmpty {
                // Meetings count chip
                HStack(spacing: 5) {
                    Image(systemName: "calendar")
                        .font(.system(size: 11))
                    Text("\(brief.meetings.count) \(brief.meetings.count == 1 ? "meeting" : "meetings")")
                        .font(.system(size: 12))
                }
                .foregroundStyle(Color.appTextTertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.appSurfaceSecondary)
                .overlay(
                    Capsule().strokeBorder(Color.appBorderStrong, lineWidth: 1)
                )
                .clipShape(Capsule())

                generateButton
            }
        }
    }

    private func statBadge(value: Int, label: String, icon: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 11))
            Text("\(value) \(label)")
                .font(.caption.weight(.medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.12))
        .clipShape(Capsule())
    }

    /// True when AI is set up. The previous version of this check gated on a
    /// live `ollamaService.isReachable` ping that was never refreshed at app
    /// launch, so users with on-device AI configured saw "Set up AI →" until
    /// they opened the On-Device settings tab (which forced a refresh). The
    /// check now also trusts the user's explicit setting choice — Ollama
    /// reachability is verified again at brief-generation time, so a momentary
    /// network blip can't strand the user with a misleading CTA.
    private var isAIConfigured: Bool {
        if let key = try? KeychainHelper.loadString(forKey: KeychainHelper.Key.claudeAPIKey),
           !key.isEmpty {
            Logger.ai.debug("DailyBrief.isAIConfigured: true (Claude key present)")
            return true
        }
        if appState.settings.useLocalLLM {
            Logger.ai.debug("DailyBrief.isAIConfigured: true (settings.useLocalLLM=true)")
            return true
        }
        let reachable = appState.ollamaService.isReachable
        Logger.ai.debug("DailyBrief.isAIConfigured: \(reachable, privacy: .public) (no Claude key, useLocalLLM=false; Ollama reachable=\(reachable, privacy: .public))")
        return reachable
    }

    private var generateButton: some View {
        Button {
            Task {
                await appState.maybeRegenerateDailyBrief(brief: dailyBrief, force: true)
            }
        } label: {
            HStack(spacing: 6) {
                if appState.isGeneratingDailyBrief {
                    ProgressView().controlSize(.mini).tint(.white)
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12))
                }
                Text(buttonLabel)
                    .font(.system(size: 12.5, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Color.appAccent)
            .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .disabled(appState.isGeneratingDailyBrief)
    }

    private var buttonLabel: String {
        if appState.isGeneratingDailyBrief { return "Generating…" }
        if !isAIConfigured { return "Set up AI →" }
        return appState.dailyBriefAIText == nil ? "Generate AI brief" : "Regenerate"
    }

    private var generatingPlaceholder: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text("Writing today's brief…")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.appTextPrimary)
                Text("This runs in the background — feel free to keep working.")
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)
            }
            Spacer()
        }
        .padding(14)
        .background(Color.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.appBorderStrong, lineWidth: 1)
        )
    }

    private var aiSetupCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.title3)
                .foregroundStyle(Color.appAccent)

            VStack(alignment: .leading, spacing: 2) {
                Text("AI summaries aren't set up yet.")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.appTextPrimary)
            }

            Spacer()

            Button("Add Claude API Key →") {
                appState.pendingSettingsTab = 4
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.appAccent)
            .controlSize(.small)
        }
        .padding(14)
        .background(Color.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.appAccent.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - Loading / Error / Empty

    private var loadingState: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Loading your day...")
                .font(.subheadline)
                .foregroundStyle(Color.appTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(Color.appWarning)
            Text("Couldn't load brief")
                .font(.headline)
                .foregroundStyle(Color.appTextPrimary)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Color.appTextSecondary)
                .multilineTextAlignment(.center)
            Button("Try Again") {
                Task { await loadBrief() }
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "calendar")
                .font(.system(size: 52))
                .foregroundStyle(Color.appTextTertiary)
            Text("No meetings today")
                .font(.title3.weight(.medium))
                .foregroundStyle(Color.appTextPrimary)
            Text("Enjoy your free day!")
                .font(.subheadline)
                .foregroundStyle(Color.appTextSecondary)

            // PRJ-014: discoverability hook — the KB sidebar item is hidden
            // until a folder is configured, so offer a way in from here.
            if !appState.kbConfigured {
                Button {
                    appState.pendingSettingsTab = 9   // Knowledge Base tab
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Text("Connect a Knowledge Base to ground briefs in your own documents →")
                        .font(.caption)
                        .foregroundStyle(Color.appAccent)
                        .multilineTextAlignment(.center)
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
                .frame(maxWidth: 360)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    // MARK: - Meetings List (timeline)

    private func meetingsList(brief: DailyBrief) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Today's schedule")
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(Color.appTextMuted)
                .textCase(.uppercase)
                .tracking(0.6)
                .padding(.horizontal, 32)
                .padding(.bottom, 12)

            // Timeline: time rail + rows
            ZStack(alignment: .topLeading) {
                // Vertical time rail line at x=64+17/2 ≈ 72.5
                Rectangle()
                    .fill(Color.appSeparator)
                    .frame(width: 1)
                    .padding(.leading, 72)
                    .padding(.top, 8)

                VStack(spacing: 16) {
                    ForEach(brief.meetings, id: \.meeting.id) { entry in
                        timelineRow(entry: entry)
                    }
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private func timelineRow(entry: DailyBriefEntry) -> some View {
        let isExpanded = Binding<Bool>(
            get: { expandedMeetingIds.contains(entry.meeting.id) },
            set: { newValue in
                withAnimation(.easeInOut(duration: 0.2)) {
                    if newValue { expandedMeetingIds.insert(entry.meeting.id) }
                    else { expandedMeetingIds.remove(entry.meeting.id) }
                }
            }
        )
        let dotColor = categoryColor(for: entry.category)

        return HStack(alignment: .top, spacing: 0) {
            // Time column — 56px, right-aligned, monospaced
            VStack(alignment: .trailing, spacing: 2) {
                if let start = entry.meeting.scheduledStartDate ?? entry.meeting.startDate {
                    Text(start, format: .dateTime.hour().minute())
                        .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.appTextSecondary)
                }
                if let end = entry.meeting.scheduledEndDate {
                    Text(end, format: .dateTime.hour().minute())
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Color.appTextMuted)
                }
            }
            .frame(width: 56, alignment: .trailing)
            .padding(.top, 2)

            // Dot — 17px wide, centered
            ZStack {
                Circle()
                    .fill(Color.appBackground)
                    .frame(width: 15, height: 15)
                Circle()
                    .fill(dotColor)
                    .frame(width: 9, height: 9)
                    .shadow(color: dotColor.opacity(0), radius: 3)
            }
            .frame(width: 17)
            .padding(.horizontal, 4)
            .padding(.top, 4)

            // Card
            MeetingPrepCardView(
                meeting: entry.meeting,
                prepBrief: entry.prepBrief,
                now: now,
                isExpanded: isExpanded
            )
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(dotColor)
                    .frame(width: 2)
                    .clipShape(RoundedRectangle(cornerRadius: 1))
            }
        }
    }

    private func categoryColor(for category: MeetingPrepCategory) -> Color {
        switch category {
        case .carryOver: return Color.appRecording
        case .followUp:  return Color.appWarning
        case .new:       return Color.appAccentMid
        }
    }

    private func categoryDot(for category: MeetingPrepCategory) -> some View {
        let color = categoryColor(for: category)
        return Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .shadow(color: color.opacity(0.4), radius: 2, x: 0, y: 0)
    }

    // MARK: - AI Brief Section

    private func aiBriefSection(text: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Card header bar — matches MeetingPrepCardView's header style
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.appTextTertiary)
                Text("AI Briefing")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(Color.appTextTertiary)
                    .textCase(.uppercase)
                    .tracking(0.7)
                Spacer()
                CopyButton(text: { text }, label: "Copy")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.appSurfaceSecondary)

            Divider().background(Color.appSeparator)

            // Content
            MarkdownRenderer(text: text, baseFontSize: 14, headingStyle: .neutral)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(Color.appSurface)

            if appState.dailyBriefGeneratedAt != nil || appState.dailyBriefModel != nil {
                Divider().background(Color.appSeparator)
                HStack(spacing: 6) {
                    if let generatedAt = appState.dailyBriefGeneratedAt {
                        Text("Updated \(generatedAt, format: .relative(presentation: .named))")
                    }
                    if appState.dailyBriefGeneratedAt != nil, appState.dailyBriefModel != nil {
                        Text("·")
                    }
                    if let model = appState.dailyBriefModel {
                        Text("via \(model)")
                    }
                    Spacer()
                    if appState.isGeneratingDailyBrief {
                        ProgressView().controlSize(.mini)
                        Text("regenerating…")
                    }
                }
                .font(.caption2)
                .foregroundStyle(Color.appTextMuted)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.appSurfaceSecondary.opacity(0.5))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.appBorderStrong, lineWidth: 1)
        )
    }

    // MARK: - Data Loading

    @MainActor
    private func loadBrief() async {
        isLoading = true
        loadError = nil
        do {
            let brief = try await service.buildBrief(for: date)
            dailyBrief = brief
            // Update sidebar badge
            appState.dailyBriefMeetingsNeedingPrep = brief.meetingsNeedingPrep
        } catch {
            loadError = error.localizedDescription
            Logger.general.error("DailyBriefView: failed to load brief: \(error.localizedDescription)")
        }
        isLoading = false
    }

}

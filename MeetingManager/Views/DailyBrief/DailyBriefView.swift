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

    // AI brief
    @State private var aiBriefText: String?
    @State private var isGeneratingBrief = false
    @State private var aiError: String?

    // Tick every 60 seconds so countdown labels ("In 5 min", "In progress") stay current
    @State private var now = Date()
    private let timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    private static let noAIServiceError = "no_ai_service"

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

                        if let aiText = aiBriefText {
                            aiBriefSection(text: aiText)
                                .padding(.horizontal, 20)
                        }

                        if let error = aiError {
                            if error == Self.noAIServiceError {
                                aiSetupCard
                                    .padding(.horizontal, 20)
                            } else {
                                Text(error)
                                    .font(.caption)
                                    .foregroundStyle(Color.appRecording)
                                    .padding(.horizontal, 20)
                            }
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
            Task { await generateAIBrief() }
        } label: {
            HStack(spacing: 6) {
                if isGeneratingBrief {
                    ProgressView().controlSize(.mini).tint(.white)
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12))
                }
                Text(isGeneratingBrief ? "Generating…" : (isAIConfigured ? (aiBriefText == nil ? "Generate AI brief" : "Regenerate") : "Set up AI →"))
                    .font(.system(size: 12.5, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Color.appAccent)
            .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .disabled(isGeneratingBrief)
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

    // MARK: - AI Generation

    @MainActor
    private func generateAIBrief() async {
        guard let brief = dailyBrief, !brief.meetings.isEmpty else { return }
        isGeneratingBrief = true
        aiError = nil

        let prompt = buildPrompt(for: brief)
        let system = """
            You are a chief-of-staff preparing a morning briefing. \
            Respond in clean Markdown. Use ## for section headings, \
            bullet lists for items, and **bold** for names and key phrases. \
            Never use raw asterisks or hashes in prose. Be direct and specific — \
            no pleasantries, no filler.
            """

        do {
            let hasClaudeKey: Bool
            if let apiKey = try? KeychainHelper.loadString(forKey: KeychainHelper.Key.claudeAPIKey),
               !apiKey.isEmpty {
                hasClaudeKey = true
            } else {
                hasClaudeKey = false
            }

            if hasClaudeKey {
                let claude = ClaudeService()
                aiBriefText = try await claude.sendMessage(
                    systemPrompt: system,
                    userPrompt: prompt,
                    model: appState.settings.claudeModel
                )
            } else if appState.ollamaService.isReachable {
                aiBriefText = try await appState.ollamaService.generate(
                    systemPrompt: system,
                    userPrompt: prompt,
                    model: appState.settings.ollamaModel
                )
            } else {
                aiError = Self.noAIServiceError
            }
        } catch {
            aiError = error.localizedDescription
            Logger.ai.error("DailyBriefView: AI brief generation failed: \(error.localizedDescription)")
        }

        isGeneratingBrief = false
    }

    private func buildPrompt(for brief: DailyBrief) -> String {
        let dateStr = date.formatted(date: .long, time: .omitted)
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "h:mm a"

        var lines: [String] = [
            "## Today: \(dateStr)",
            "",
            "### Schedule",
        ]

        for entry in brief.meetings {
            let meeting = entry.meeting
            let timeStr: String
            if let start = meeting.scheduledStartDate ?? meeting.startDate,
               let end = meeting.scheduledEndDate {
                timeStr = "\(timeFormatter.string(from: start))–\(timeFormatter.string(from: end))"
            } else if let start = meeting.scheduledStartDate ?? meeting.startDate {
                timeStr = timeFormatter.string(from: start)
            } else {
                timeStr = "Time TBD"
            }

            let participants = entry.prepBrief.participants.prefix(4).joined(separator: ", ")
            var row = "- **\(timeStr)** — \(meeting.title)"
            if !participants.isEmpty { row += " · \(participants)" }
            switch entry.category {
            case .carryOver:
                let n = entry.prepBrief.openActionItems.count
                row += " ⚠️ \(n) open item\(n == 1 ? "" : "s")"
            case .followUp:
                row += " (follow-up)"
            case .new:
                break
            }
            lines.append(row)

            // Prior context excerpt
            if let prev = entry.prepBrief.previousSession {
                let excerpt = prev.summaryExcerpt?.prefix(120) ?? ""
                if !excerpt.isEmpty {
                    lines.append("  - *Last time (\(prev.date.formatted(date: .abbreviated, time: .omitted))): \(excerpt)…*")
                }
            }
        }

        if brief.totalOpenItems > 0 {
            lines.append("")
            lines.append("### Open Action Items")
            for entry in brief.meetings {
                for item in entry.prepBrief.openActionItems.prefix(4) {
                    var itemLine = "- "
                    if let assignee = item.assignee { itemLine += "**\(assignee)** — " }
                    itemLine += item.title
                    itemLine += " *(from \(entry.meeting.title))*"
                    lines.append(itemLine)
                }
            }
        }

        lines.append(contentsOf: [
            "",
            "---",
            "",
            "Write a daily brief in **exactly this structure**, in Markdown:",
            "",
            "## One-line read",
            "A single sentence: the most important thing about today.",
            "",
            "## What needs attention",
            "2–4 bullets — only items that require action or prep before a meeting.",
            "Each bullet names the meeting, the issue, and what to do about it.",
            "Skip entirely if there are no carry-over items.",
            "",
            "## Meeting-by-meeting",
            "One tight bullet per meeting: time, title, and the single most useful thing to know walking in.",
            "If there's no prior context, say \"First conversation — no prior context.\"",
            "",
            "## Day-end goals",
            "2–3 bullets on what a successful day looks like by 5pm, given today's schedule.",
            "",
            "Rules: be specific, use exact names from the schedule, no filler phrases.",
            "Length: 150–300 words total."
        ])

        return lines.joined(separator: "\n")
    }
}

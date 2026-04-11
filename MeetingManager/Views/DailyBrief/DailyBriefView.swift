import SwiftUI
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
            await loadBrief()
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Daily Brief")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Color.appTextPrimary)
                Text(date, format: .dateTime.weekday(.wide).month(.wide).day())
                    .font(.subheadline)
                    .foregroundStyle(Color.appTextSecondary)
            }

            Spacer()

            // Stats badges
            if let brief = dailyBrief, !brief.meetings.isEmpty {
                HStack(spacing: 8) {
                    statBadge(
                        value: brief.meetings.count,
                        label: brief.meetings.count == 1 ? "meeting" : "meetings",
                        icon: "calendar",
                        color: Color.appAccent
                    )

                    if brief.totalOpenItems > 0 {
                        statBadge(
                            value: brief.totalOpenItems,
                            label: brief.totalOpenItems == 1 ? "open item" : "open items",
                            icon: "checkmark.circle",
                            color: Color.appWarning
                        )
                    }
                }
            }

            // Generate AI Brief button
            if let brief = dailyBrief, !brief.meetings.isEmpty {
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

    private var generateButton: some View {
        Button {
            Task { await generateAIBrief() }
        } label: {
            if isGeneratingBrief {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Generating...")
                        .font(.subheadline.weight(.medium))
                }
            } else {
                Label(aiBriefText == nil ? "Generate AI Brief" : "Regenerate", systemImage: "sparkles")
                    .font(.subheadline.weight(.medium))
            }
        }
        .buttonStyle(.borderedProminent)
        .tint(Color.appAccent)
        .controlSize(.regular)
        .disabled(isGeneratingBrief)
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

    // MARK: - Meetings List

    private func meetingsList(brief: DailyBrief) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Today's Schedule")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.appTextTertiary)
                .textCase(.uppercase)
                .tracking(0.8)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)

            VStack(spacing: 8) {
                ForEach(brief.meetings, id: \.meeting.id) { entry in
                    briefEntryRow(entry: entry)
                }
            }
            .padding(.horizontal, 20)
        }
    }

    /// Renders a single brief entry row with category dot overlay + inline expansion.
    private func briefEntryRow(entry: DailyBriefEntry) -> some View {
        let isExpanded = Binding<Bool>(
            get: { expandedMeetingIds.contains(entry.meeting.id) },
            set: { newValue in
                withAnimation(.easeInOut(duration: 0.2)) {
                    if newValue {
                        expandedMeetingIds.insert(entry.meeting.id)
                    } else {
                        expandedMeetingIds.remove(entry.meeting.id)
                    }
                }
            }
        )

        return ZStack(alignment: .leading) {
            MeetingPrepCardView(
                meeting: entry.meeting,
                prepBrief: entry.prepBrief,
                now: Date(),
                isExpanded: isExpanded
            )

            // Category status dot overlaid near the time column
            categoryDot(for: entry.category)
                .offset(x: 6, y: -12)
        }
    }

    private func categoryDot(for category: MeetingPrepCategory) -> some View {
        let color: Color
        switch category {
        case .carryOver: color = Color.appRecording    // red/orange — needs attention
        case .followUp:  color = Color.appWarning      // yellow — has context
        case .new:       color = Color.appSuccess      // green — fresh
        }
        return Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .shadow(color: color.opacity(0.4), radius: 2, x: 0, y: 0)
    }

    // MARK: - AI Brief Section

    private func aiBriefSection(text: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("AI Briefing", systemImage: "sparkles")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.appTextTertiary)
                    .textCase(.uppercase)
                    .tracking(0.8)

                Spacer()

                CopyButton(text: { text }, label: "Copy")
            }

            Text(text)
                .font(.body)
                .foregroundStyle(Color.appTextPrimary)
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Color.appSurface)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
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

    // MARK: - AI Generation (T-017)

    @MainActor
    private func generateAIBrief() async {
        guard let brief = dailyBrief, !brief.meetings.isEmpty else { return }
        isGeneratingBrief = true
        aiError = nil

        let prompt = buildPrompt(for: brief)
        let system = "You are a meeting preparation assistant. Write clear, concise briefings."

        do {
            // Try Claude first (if API key exists), fall back to Ollama
            let hasClaudeKey: Bool
            if let apiKey = try? KeychainHelper.loadString(forKey: KeychainHelper.Key.claudeAPIKey),
               let key = apiKey, !key.isEmpty {
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
                aiError = "No AI service available. Configure a Claude API key in Settings, or start Ollama."
            }
        } catch {
            aiError = error.localizedDescription
            Logger.ai.error("DailyBriefView: AI brief generation failed: \(error.localizedDescription)")
        }

        isGeneratingBrief = false
    }

    private func buildPrompt(for brief: DailyBrief) -> String {
        let dateStr = date.formatted(date: .long, time: .omitted)
        var lines: [String] = [
            "You are a meeting preparation assistant. Write a 3-5 sentence briefing for today.",
            "",
            "Today's date: \(dateStr)",
            "Today's meetings:"
        ]

        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "h:mm a"

        for (index, entry) in brief.meetings.enumerated() {
            let meeting = entry.meeting
            let timeStr: String
            if let start = meeting.scheduledStartDate ?? meeting.startDate {
                timeStr = timeFormatter.string(from: start)
            } else {
                timeStr = "Time TBD"
            }

            let participantCount = entry.prepBrief.participants.count
            let participantNote = participantCount == 1 ? "1 participant" : "\(participantCount) participants"

            let contextNote: String
            switch entry.category {
            case .carryOver:
                let itemCount = entry.prepBrief.openActionItems.count
                contextNote = "carry-over: \(itemCount) open \(itemCount == 1 ? "item" : "items") from last time"
            case .followUp:
                contextNote = "follow-up to a previous meeting"
            case .new:
                contextNote = "new conversation"
            }

            lines.append("\(index + 1). \(timeStr) - \(meeting.title) (\(participantNote)) - \(contextNote)")
        }

        if brief.totalOpenItems > 0 {
            lines.append("")
            lines.append("Open action items:")
            for entry in brief.meetings {
                for item in entry.prepBrief.openActionItems.prefix(5) {
                    var itemLine = "- "
                    if let assignee = item.assignee { itemLine += "\(assignee): " }
                    itemLine += item.title
                    itemLine += " (from \(entry.meeting.title))"
                    lines.append(itemLine)
                }
            }
        }

        lines.append("")
        lines.append("Write a concise briefing highlighting what needs attention today.")

        return lines.joined(separator: "\n")
    }
}

import SwiftUI
import AppKit

/// Collapsible AI-briefing block on the merged Home page. Ported wholesale from
/// the former `DailyBriefView` AI section: narrative via `MarkdownRenderer`, KB
/// references, Copy, Generate/Regenerate with its 4-state label, freshness
/// footer, generating placeholder, queued/error lines, and the AI-setup card.
///
/// Unlike the old view, this section has NO auto-generation kick and does NOT
/// ping Ollama — generation happens only via the launch/sync/hourly scheduler
/// and the explicit Generate/Regenerate button (see AppState.maybeRegenerateDailyBrief).
struct HomeAIBriefingSection: View {
    let brief: DailyBrief?
    @Environment(AppState.self) private var appState
    @AppStorage("home.aiBriefingCollapsed") private var collapsed: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if !collapsed {
                content
            } else {
                // Queued/error must stay visible while collapsed — a Regenerate
                // that fails from the collapsed header would otherwise fail
                // silently (the button just reverts to "Regenerate").
                statusLines
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { collapsed.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(Color.appTextTertiary)
                    Text("AI Briefing")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.appTextTertiary)
                        .textCase(.uppercase)
                        .tracking(0.8)
                    // Collapsed header carries the freshness signal so the
                    // user knows there's content (and how stale) without
                    // expanding.
                    if collapsed, let generatedAt = appState.dailyBriefGeneratedAt {
                        Text("· updated \(generatedAt.formatted(.relative(presentation: .named)))")
                            .font(.caption2)
                            .foregroundStyle(Color.appTextTertiary)
                            .textCase(nil)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            generateButton
        }
    }

    private var generateButton: some View {
        Button {
            Task {
                await appState.maybeRegenerateDailyBrief(brief: brief, force: true)
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
        if !appState.isAIWorkConfigured { return "Set up AI →" }
        return appState.dailyBriefAIText == nil ? "Generate AI brief" : "Regenerate"
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let aiText = appState.dailyBriefAIText {
            aiBriefCard(text: aiText)
        } else if appState.isGeneratingDailyBrief {
            generatingPlaceholder
        } else if !appState.isAIWorkConfigured {
            aiSetupCard
        } else {
            // AI is configured, nothing is running, and today has no brief:
            // without this the section rendered a header and a Generate button
            // over an empty body, which reads as a bug rather than a state.
            Text("No brief generated yet today — use Generate above.")
                .font(.caption)
                .foregroundStyle(Color.appTextSecondary)
        }

        statusLines
    }

    /// Queued/error lines — rendered both inside the expanded content and
    /// below the header while collapsed.
    @ViewBuilder
    private var statusLines: some View {
        if appState.dailyBriefQueued {
            HStack(spacing: 6) {
                Image(systemName: "clock.badge.checkmark")
                Text("Daily brief queued — it will generate automatically once the current transcriptions finish.")
            }
            .font(.caption)
            .foregroundStyle(Color.appTextSecondary)
        } else if let error = appState.dailyBriefError {
            Text(error)
                .font(.caption)
                .foregroundStyle(Color.appRecording)
        }
    }

    private func aiBriefCard(text: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
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

            MarkdownRenderer(text: text, baseFontSize: 14, headingStyle: .neutral)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(Color.appSurface)

            // PRJ-014: KB documents fed to the model as background for this brief.
            if !appState.dailyBriefKBSources.isEmpty {
                Divider().background(Color.appSeparator)
                KBReferencesView(kbSources: appState.dailyBriefKBSources)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.appSurface)
            }

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

            // Provider-agnostic: the same card shows for a user whose intended
            // provider is Gemini, Ollama, OpenAI or Z.ai, and the tab it opens
            // is the provider picker, not a Claude-specific field.
            Button("Choose an AI provider →") {
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
}

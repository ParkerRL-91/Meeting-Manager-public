import SwiftUI

/// Compact context card mounted between ParticipantBar and the tab picker.
/// Shows the LLM-synthesized pre-meeting brief as the primary content
/// ("Last week you talked to John and concluded you should mow the lawn"),
/// with a small disclosure footer that lists the source meetings on demand.
///
/// Intentionally short — caps at ~110pt collapsed and grows only when the user
/// expands the source list. Falls back to the legacy meeting-list layout when
/// the cached context is from a pre-v3.4 enrichment run that has no brief.
struct RelatedMeetingsSection: View {
    let contextJSON: String?
    var onSelectMeeting: ((String) -> Void)?

    /// Whole-body collapse. Persisted via @AppStorage so the user's preference
    /// survives navigation between meetings.
    @AppStorage("contextCardExpanded") private var isExpanded: Bool = true
    @State private var isSourcesExpanded = false

    private var cached: CachedContext {
        RelevantMeetingService.parseCachedContext(from: contextJSON)
    }

    var body: some View {
        let ctx = cached
        if ctx.brief != nil || !ctx.relatedMeetings.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                content(for: ctx)
                Divider()
            }
        }
    }

    @ViewBuilder
    private func content(for ctx: CachedContext) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header — clicking anywhere on this row collapses/expands the
            // whole brief.
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.caption)
                        .foregroundStyle(Color.appAccentLight)
                    Text("CONTEXT")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.appAccentLight)
                        .tracking(0.6)
                    Spacer()
                    if !ctx.relatedMeetings.isEmpty, isExpanded {
                        // Sources subtoggle is only visible when the body is
                        // expanded — it has no meaning when the body is hidden.
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                isSourcesExpanded.toggle()
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text("\(ctx.relatedMeetings.count) source\(ctx.relatedMeetings.count == 1 ? "" : "s")")
                                    .font(.caption2)
                                Image(systemName: isSourcesExpanded ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 9, weight: .semibold))
                            }
                            .foregroundStyle(Color.appTextTertiary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(isSourcesExpanded ? "Hide source meetings" : "Show source meetings")
                    }
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.appTextTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Collapse context" : "Expand context")

            if isExpanded {
                // Body wrapped in a capped-height ScrollView so the context
                // card never dominates the live meeting view. Default cap
                // (240pt) is roughly half the screen height of a typical
                // recording window — enough to read the brief, not enough
                // to bury the notes pane below. When the brief is long,
                // the user scrolls inside the card.
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let brief = ctx.brief, !brief.isEmpty {
                            // Parse the brief using the same SummaryParser
                            // used post-meeting, so we get the same coloured-
                            // dot section labels (KEY POINTS / DECISIONS /
                            // FOLLOW-UPS / etc.) and bold-entity-on-grey-body
                            // typography. When the brief is too unstructured
                            // for the parser to find sections, fall back to
                            // a plain Markdown render — better one-style miss
                            // than blanking the brief entirely.
                            let parsed = SummaryParser.parse(brief)
                            let usefulSections = parsed.sections.filter { !$0.items.isEmpty }
                            if !usefulSections.isEmpty {
                                SkimFirstSectionGrid(sections: usefulSections)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                MarkdownRenderer(text: brief, baseFontSize: 14)
                                    .foregroundStyle(Color.appTextPrimary)
                                    .textSelection(.enabled)
                                    .lineLimit(nil)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        } else {
                            Text("Prior context from \(ctx.relatedMeetings.count) meeting\(ctx.relatedMeetings.count == 1 ? "" : "s") — open a source to review.")
                                .font(.system(size: 13, design: .serif))
                                .foregroundStyle(Color.appTextSecondary)
                                .lineLimit(2)
                        }

                        if isSourcesExpanded, !ctx.relatedMeetings.isEmpty {
                            VStack(spacing: 4) {
                                ForEach(ctx.relatedMeetings) { related in
                                    RelatedMeetingRow(meeting: related) {
                                        onSelectMeeting?(related.meetingId)
                                    }
                                }
                            }
                            .padding(.top, 4)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                }
                .frame(maxHeight: 160)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }
}

// MARK: - Related Meeting Row

private struct RelatedMeetingRow: View {
    let meeting: RelevantMeeting
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 10) {
                // Date badge
                VStack(spacing: 0) {
                    Text(meeting.date.formatted(.dateTime.month(.abbreviated)))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.appAccent)
                    Text(meeting.date.formatted(.dateTime.day()))
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.appTextPrimary)
                }
                .frame(width: 32)

                Text(meeting.title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.appTextPrimary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.appTextTertiary)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .background(Color.appSurfaceSecondary.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

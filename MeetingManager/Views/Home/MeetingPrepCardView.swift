import SwiftUI

/// Upcoming meeting card with expandable prep brief.
/// Collapsed: shows participant avatars, open items badge, and summary excerpt.
/// Expanded: shows full participant list, action items, related meetings, and Join button.
struct MeetingPrepCardView: View {
    let meeting: Meeting
    let prepBrief: MeetingPrepBrief?
    let now: Date
    @Binding var isExpanded: Bool

    @Environment(AppState.self) private var appState

    // MARK: - Computed

    private var scheduledDate: Date? {
        meeting.scheduledStartDate ?? meeting.startDate
    }

    private var statusLabel: String {
        if meeting.isReopenable { return "Ended" }
        if meeting.status == .complete { return "Complete" }
        if meeting.status == .cancelled { return "Cancelled" }
        guard let date = scheduledDate else { return "" }
        let diff = date.timeIntervalSince(now)
        if diff <= 0 { return "In progress" }
        let mins = Int(diff / 60)
        if mins == 0 { return "Starting now" }
        if mins < 60 { return "In \(mins) min" }
        let hrs = mins / 60
        let rem = mins % 60
        return rem == 0 ? "In \(hrs)h" : "In \(hrs)h \(rem)m"
    }

    private var statusColor: Color {
        if meeting.isReopenable { return Color.appSuccess }
        if meeting.status == .complete { return Color.appTextTertiary }
        guard let date = scheduledDate else { return Color.appSuccess }
        let mins = Int(date.timeIntervalSince(now) / 60)
        if mins <= 5 { return Color.appRecording }
        if mins <= 60 { return Color.appWarning }
        return Color.appTextSecondary
    }

    private var isWithinHour: Bool {
        guard let date = scheduledDate else { return false }
        return date.timeIntervalSince(now) <= 3600
    }

    private var ctaInfo: (label: String, tint: Color)? {
        guard !meeting.isAllDay else { return nil }
        if meeting.isReopenable { return ("Re-open", Color.appAccent) }
        guard meeting.status != .complete, meeting.status != .cancelled else { return nil }
        guard let start = scheduledDate else { return nil }
        let diff = start.timeIntervalSince(now)
        if diff > 3600 { return ("Start now", Color.appAccent) }
        return ("Record now", isWithinHour ? Color.appWarning : Color.appRecording)
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Top row — always visible
            collapsedRow

            // Expanded content
            if isExpanded, let brief = prepBrief, brief.hasContext {
                Divider()
                    .padding(.horizontal, 16)
                expandedContent(brief: brief)
            }
        }
        .background(Color.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture {
            appState.selectedMeetingId = meeting.id
        }
    }

    // MARK: - Collapsed Row

    private var collapsedRow: some View {
        HStack(spacing: 14) {
            // Time column
            VStack(alignment: .trailing, spacing: 2) {
                if let date = scheduledDate {
                    Text(date, format: .dateTime.hour().minute())
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Color.appTextPrimary)
                    if let end = meeting.scheduledEndDate {
                        Text(end, format: .dateTime.hour().minute())
                            .font(.caption2)
                            .foregroundStyle(Color.appTextTertiary)
                    }
                }
            }
            .frame(width: 52, alignment: .trailing)

            // Left accent bar
            RoundedRectangle(cornerRadius: 2)
                .fill(isWithinHour ? statusColor : Color.appAccent)
                .frame(width: 3, height: 38)

            // Title + prep context preview
            VStack(alignment: .leading, spacing: 5) {
                Text(meeting.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.appTextPrimary)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    // Participant avatars
                    if !meeting.participantList.isEmpty {
                        HStack(spacing: -6) {
                            ForEach(Array(meeting.participantList.prefix(3).enumerated()), id: \.offset) { idx, name in
                                InitialsAvatar(name: name, size: 20, index: idx)
                            }
                            if meeting.participantList.count > 3 {
                                Text("+\(meeting.participantList.count - 3)")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(Color.appTextSecondary)
                                    .padding(.leading, 4)
                            }
                        }
                    }

                    // Open items badge
                    if let brief = prepBrief, !brief.openActionItems.isEmpty {
                        HStack(spacing: 3) {
                            Image(systemName: "checkmark.circle")
                                .font(.system(size: 10))
                            Text("\(brief.openActionItems.count) open")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundStyle(Color.appWarning)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.appWarning.opacity(0.12))
                        .clipShape(Capsule())
                    }

                    // Summary excerpt
                    if let excerpt = prepBrief?.lastSummaryExcerpt {
                        Text(excerpt)
                            .font(.caption)
                            .foregroundStyle(Color.appTextTertiary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer()

            // Status + CTA + expand chevron
            VStack(alignment: .trailing, spacing: 4) {
                if !statusLabel.isEmpty {
                    Text(statusLabel)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(statusColor)
                }

                HStack(spacing: 6) {
                    if let cta = ctaInfo {
                        Button(cta.label) {
                            if meeting.isReopenable {
                                appState.startOrReopenRecording(for: meeting)
                            } else {
                                appState.startRecording(for: meeting)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(cta.tint)
                        .controlSize(.mini)
                    }

                    if prepBrief?.hasContext == true {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isExpanded.toggle()
                            }
                        } label: {
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.caption2)
                                .foregroundStyle(Color.appTextTertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Expanded Content

    private func expandedContent(brief: MeetingPrepBrief) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Full participant list
            if brief.participants.count > 3 {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Participants")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.appTextTertiary)
                        .textCase(.uppercase)
                        .tracking(0.5)

                    FlowLayout(spacing: 6) {
                        ForEach(Array(brief.participants.enumerated()), id: \.offset) { idx, name in
                            HStack(spacing: 4) {
                                InitialsAvatar(name: name, size: 16, index: idx)
                                Text(name)
                                    .font(.caption)
                                    .foregroundStyle(Color.appTextPrimary)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.appBackground.opacity(0.6))
                            .clipShape(Capsule())
                        }
                    }
                }
            }

            // Open action items
            if !brief.openActionItems.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Open Items")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.appTextTertiary)
                        .textCase(.uppercase)
                        .tracking(0.5)

                    ForEach(brief.openActionItems.prefix(5)) { item in
                        HStack(spacing: 8) {
                            Image(systemName: "circle")
                                .font(.system(size: 10))
                                .foregroundStyle(Color.appWarning)

                            Text(item.title)
                                .font(.caption)
                                .foregroundStyle(Color.appTextPrimary)
                                .lineLimit(1)

                            Spacer()

                            if let assignee = item.assignee {
                                Text(assignee)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(Color.appTextSecondary)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(Color.appTextTertiary.opacity(0.15))
                                    .clipShape(Capsule())
                            }
                        }
                    }

                    if brief.openActionItems.count > 5 {
                        Text("+\(brief.openActionItems.count - 5) more")
                            .font(.caption)
                            .foregroundStyle(Color.appTextSecondary)
                    }
                }
            }

            // Related meetings
            if !brief.relatedMeetings.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Related Meetings")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.appTextTertiary)
                        .textCase(.uppercase)
                        .tracking(0.5)

                    ForEach(brief.relatedMeetings.prefix(3)) { related in
                        HStack(spacing: 8) {
                            Text(related.date, format: .dateTime.month(.abbreviated).day())
                                .font(.system(size: 10, weight: .medium).monospacedDigit())
                                .foregroundStyle(Color.appAccent)
                                .frame(width: 44, alignment: .leading)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(related.title)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(Color.appTextPrimary)
                                    .lineLimit(1)
                                Text(related.summaryExcerpt)
                                    .font(.caption)
                                    .foregroundStyle(Color.appTextTertiary)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
            }

            // Action buttons
            HStack(spacing: 8) {
                if let link = brief.meetLink, let url = URL(string: link) {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Label("Join Meeting", systemImage: "video")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.appAccent)
                    .controlSize(.small)
                }

                Button {
                    appState.selectedMeetingId = meeting.id
                } label: {
                    Label("View Details", systemImage: "doc.text")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - Flow Layout

/// Simple flow layout that wraps items to the next line.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > maxWidth && currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: maxWidth, height: currentY + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var currentX: CGFloat = bounds.minX
        var currentY: CGFloat = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > bounds.maxX && currentX > bounds.minX {
                currentX = bounds.minX
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: currentX, y: currentY), proposal: .unspecified)
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

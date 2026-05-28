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
        // "In progress" must mean actually recording — not just "scheduled
        // start time has passed". A scheduled meeting whose start time has
        // passed but where no recording is running is either Now (still in
        // its window) or Missed (past its end).
        if meeting.status == .recording { return "In progress" }
        if meeting.isReopenable { return "Ended" }
        if meeting.status == .complete { return "Complete" }
        if meeting.status == .cancelled { return "Cancelled" }
        guard let date = scheduledDate else { return "" }
        let diff = date.timeIntervalSince(now)
        if diff <= 0 {
            // Past start time, not recording. Within the scheduled window?
            if let endDate = meeting.scheduledEndDate, now < endDate {
                return "Now"
            }
            return "Missed"
        }
        let mins = Int(diff / 60)
        if mins == 0 { return "Starting now" }
        if mins < 60 { return "In \(mins) min" }
        let hrs = mins / 60
        let rem = mins % 60
        return rem == 0 ? "In \(hrs)h" : "In \(hrs)h \(rem)m"
    }

    private var statusColor: Color {
        if meeting.status == .recording { return Color.appRecording }
        if meeting.isReopenable { return Color.appSuccess }
        if meeting.status == .complete { return Color.appTextTertiary }
        guard let date = scheduledDate else { return Color.appSuccess }
        let diff = date.timeIntervalSince(now)
        if diff <= 0 {
            // Past start, not recording — Now (in window) is amber, Missed is muted
            if let endDate = meeting.scheduledEndDate, now < endDate {
                return Color.appWarning
            }
            return Color.appTextTertiary
        }
        let mins = Int(diff / 60)
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
        if meeting.status == .recording { return nil }      // already recording — no CTA
        if meeting.isReopenable { return ("Re-open", Color.appAccent) }
        guard meeting.status != .complete, meeting.status != .cancelled else { return nil }
        guard let start = scheduledDate else { return nil }
        let diff = start.timeIntervalSince(now)

        // Has an audio file already (was recorded once and stopped) →
        // continue rather than start fresh.
        if meeting.audioFilePath != nil { return ("Continue Recording", Color.appAccent) }

        if diff > 3600 { return ("Start Early", Color.appAccent) }
        if diff > 0    { return ("Start Early", Color.appWarning) }

        // Past start — within the scheduled window we still want to nudge,
        // past the end window we don't.
        if let endDate = meeting.scheduledEndDate, now < endDate {
            return ("Record now", Color.appRecording)
        }
        // Missed — show a low-key "Record" so a late capture is still possible.
        return ("Record", Color.appTextTertiary)
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
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(Color.appTextSecondary)
                                    .padding(.leading, 4)
                            }
                        }
                    }

                    // Open items badge
                    if let brief = prepBrief, !brief.openActionItems.isEmpty {
                        HStack(spacing: 3) {
                            Image(systemName: "checkmark.circle")
                                .font(.caption2)
                            Text("\(brief.openActionItems.count) open")
                                .font(.caption2.weight(.medium))
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
                                .padding(12)
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                        .accessibilityLabel(isExpanded ? "Collapse prep details" : "Expand prep details")
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Expanded Content

    /// Lowercased identifiers (email or name) for the local user so the
    /// Attendee Profile card skips themselves.
    private var localUserIdentifiers: Set<String> {
        var ids: Set<String> = []
        if let email = appState.googleAuthManager.userEmail?
            .lowercased().trimmingCharacters(in: .whitespaces), !email.isEmpty {
            ids.insert(email)
        }
        let fullName = NSFullUserName().lowercased().trimmingCharacters(in: .whitespaces)
        if !fullName.isEmpty { ids.insert(fullName) }
        return ids
    }

    private func expandedContent(brief: MeetingPrepBrief) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Apollo: when the integration is configured and the key has
            // been validated, surface attendee profiles inside the expanded
            // prep card. Doesn't replace existing prep context (related
            // meetings + open items still appear below) — adds richer
            // attendee identity above them.
            if appState.settings.apolloProfilePrepEnabled,
               appState.settings.apolloKeyValidated,
               !brief.participants.isEmpty {
                AttendeeProfileSection(
                    participants: brief.participants,
                    excludeIdentifiers: localUserIdentifiers
                )
            }

            // P5-T02: Series awareness — "Last time:" line.
            if let prev = brief.previousSession {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.uturn.backward.circle")
                        .font(.caption2)
                        .foregroundStyle(Color.appAccent)
                    Text("Last time (\(prev.date, format: .dateTime.month(.abbreviated).day())):")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.appTextSecondary)
                    Text(prev.summaryExcerpt ?? "No summary")
                        .font(.caption)
                        .foregroundStyle(Color.appTextTertiary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }

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
                                .font(.caption2)
                                .foregroundStyle(Color.appWarning)

                            Text(item.title)
                                .font(.caption)
                                .foregroundStyle(Color.appTextPrimary)
                                .lineLimit(1)

                            Spacer()

                            if let assignee = item.assignee {
                                Text(assignee)
                                    .font(.caption2.weight(.medium))
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
                                .font(.caption2.weight(.medium).monospacedDigit())
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

            // Template chips — Meeting type picker, persists to meeting.templateId
            VStack(alignment: .leading, spacing: 6) {
                Text("Template")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.appTextTertiary)
                    .textCase(.uppercase)
                    .tracking(0.5)

                MeetingTemplatePickerView(
                    selectedTemplateId: Binding(
                        get: { meeting.templateId },
                        set: { newId in
                            Task {
                                var updated = meeting
                                updated.templateId = newId
                                try? await appState.meetingRepository.update(updated)
                            }
                        }
                    ),
                    compact: true
                )
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
// FlowLayout defined in ParticipantBar.swift (module-level)

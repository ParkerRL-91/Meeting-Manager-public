import SwiftUI

/// Collapsible section showing relevant past meetings with participant overlap or similar topics.
/// Displayed at the top of MeetingDetailView between ParticipantBar and the tab picker.
struct RelatedMeetingsSection: View {
    let contextJSON: String?
    var onSelectMeeting: ((String) -> Void)?

    @State private var isExpanded = false

    private var relatedMeetings: [RelevantMeeting] {
        RelevantMeetingService.parseContext(from: contextJSON)
    }

    var body: some View {
        if !relatedMeetings.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                // Header with expand/collapse toggle
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.caption)
                            .foregroundStyle(Color.appTextTertiary)
                        Text("Related Meetings")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.appTextTertiary)
                        Text("(\(relatedMeetings.count))")
                            .font(.caption)
                            .foregroundStyle(Color.appTextTertiary)
                        Spacer()
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.appTextTertiary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isExpanded {
                    VStack(spacing: 4) {
                        ForEach(relatedMeetings) { related in
                            RelatedMeetingRow(meeting: related) {
                                onSelectMeeting?(related.meetingId)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                Divider()
            }
        }
    }
}

// MARK: - Related Meeting Row

private struct RelatedMeetingRow: View {
    let meeting: RelevantMeeting
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                // Date badge
                VStack(spacing: 0) {
                    Text(meeting.date.formatted(.dateTime.month(.abbreviated)))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.appAccent)
                    Text(meeting.date.formatted(.dateTime.day()))
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.appTextPrimary)
                }
                .frame(width: 36)

                VStack(alignment: .leading, spacing: 2) {
                    Text(meeting.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.appTextPrimary)
                        .lineLimit(1)
                    Text(meeting.summaryExcerpt)
                        .font(.caption)
                        .foregroundStyle(Color.appTextSecondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(Color.appSurfaceSecondary.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

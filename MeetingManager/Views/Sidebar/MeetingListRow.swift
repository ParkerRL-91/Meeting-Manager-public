import SwiftUI

struct MeetingListRow: View {
    let meeting: Meeting

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(meeting.title)
                    .font(.body)
                    .fontWeight(.medium)
                    .foregroundStyle(Color.appTextPrimary)
                    .lineLimit(1)

                Text(DateFormatting.relativeDate(from: meeting.effectiveDate)
                     + " at "
                     + DateFormatting.timeOnly(from: meeting.effectiveDate))
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                StatusBadge(status: meeting.status)

                if meeting.duration != nil {
                    Text(meeting.formattedDuration)
                        .font(.caption2)
                        .foregroundStyle(Color.appTextTertiary)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - Previews

#Preview("Scheduled Meeting") {
    MeetingListRow(meeting: Meeting(
        title: "Weekly Standup",
        scheduledStartDate: Date().addingTimeInterval(3600),
        status: .scheduled
    ))
    .padding()
    .frame(width: 320)
}

#Preview("Completed Meeting") {
    MeetingListRow(meeting: Meeting(
        title: "Design Review",
        startDate: Date().addingTimeInterval(-7200),
        endDate: Date().addingTimeInterval(-3600),
        status: .complete
    ))
    .padding()
    .frame(width: 320)
}

#Preview("Recording Meeting") {
    MeetingListRow(meeting: Meeting(
        title: "Sprint Planning",
        startDate: Date().addingTimeInterval(-1800),
        status: .recording
    ))
    .padding()
    .frame(width: 320)
}

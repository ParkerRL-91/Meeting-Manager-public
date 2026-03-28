import SwiftUI

struct MeetingMetadataHeader: View {
    let meeting: Meeting
    var onEdit: (() -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(meeting.title)
                        .font(.title2)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.appTextPrimary)
                        .lineLimit(2)

                    if let onEdit {
                        Button {
                            onEdit()
                        } label: {
                            Image(systemName: "pencil")
                                .font(.caption)
                                .foregroundStyle(Color.appTextSecondary)
                        }
                        .buttonStyle(.plain)
                        .help("Edit meeting")
                    }
                }

                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                        .imageScale(.small)
                    Text(DateFormatting.relativeDate(from: meeting.effectiveDate))

                    Text("at")
                        .foregroundStyle(Color.appTextTertiary)

                    Image(systemName: "clock")
                        .imageScale(.small)
                    Text(DateFormatting.timeOnly(from: meeting.effectiveDate))
                }
                .font(.subheadline)
                .foregroundStyle(Color.appTextSecondary)
            }

            Spacer()

            StatusBadge(status: meeting.status)

            if meeting.duration != nil {
                Text(meeting.formattedDuration)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(Color.appTextSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.appSurfaceSecondary)
                    .clipShape(Capsule())
            }
        }
        .padding(16)
        .background(Color.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 16)
        .padding(.top, 16)
    }
}

// MARK: - Previews

#Preview("Completed Meeting") {
    MeetingMetadataHeader(meeting: Meeting(
        title: "Weekly Design Sync",
        startDate: Date().addingTimeInterval(-7200),
        endDate: Date().addingTimeInterval(-3600),
        scheduledStartDate: Date().addingTimeInterval(-7200),
        status: .complete
    ))
    .padding()
    .background(Color.appBackground)
}

#Preview("Recording Meeting") {
    MeetingMetadataHeader(meeting: Meeting(
        title: "Sprint Planning - Q2 Roadmap Review",
        startDate: Date().addingTimeInterval(-1800),
        status: .recording
    ))
    .padding()
    .background(Color.appBackground)
}

#Preview("Scheduled Meeting") {
    MeetingMetadataHeader(meeting: Meeting(
        title: "1:1 with Manager",
        scheduledStartDate: Date().addingTimeInterval(3600),
        scheduledEndDate: Date().addingTimeInterval(5400),
        status: .scheduled
    ))
    .padding()
    .background(Color.appBackground)
}

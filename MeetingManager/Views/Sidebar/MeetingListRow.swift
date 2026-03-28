import SwiftUI

struct MeetingListRow: View {
    let meeting: Meeting
    var onError: ((String) -> Void)?

    @Environment(AppState.self) private var appState

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
        .contextMenu {
            Button {
                copySummary()
            } label: {
                Label("Copy Summary", systemImage: "doc.on.doc")
            }

            Button {
                shareMeeting()
            } label: {
                Label("Share...", systemImage: "square.and.arrow.up")
            }
        }
        .swipeActions(edge: .leading) {
            Button {
                toggleArchive()
            } label: {
                Label(
                    meeting.status == .archived ? "Unarchive" : "Archive",
                    systemImage: "archivebox"
                )
            }
            .tint(.blue)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                deleteMeeting()
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .tint(.red)
        }
    }

    // MARK: - Actions

    private func toggleArchive() {
        Task {
            do {
                if meeting.status == .archived {
                    try await appState.meetingRepository.unarchive(id: meeting.id)
                } else {
                    try await appState.meetingRepository.archive(id: meeting.id)
                }
                appState.loadMeetings()
            } catch {
                onError?("Failed to toggle archive: \(error.localizedDescription)")
            }
        }
    }

    private func copySummary() {
        Task {
            guard let summary = try? await appState.summaryRepository.latestSummary(meetingId: meeting.id) else { return }
            let exportService = ExportService()
            let markdown = exportService.exportSummaryMarkdown(meeting: meeting, summary: summary)
            ShareService.copyToClipboard(markdown)
        }
    }

    private func shareMeeting() {
        Task {
            guard let summary = try? await appState.summaryRepository.latestSummary(meetingId: meeting.id) else { return }
            let exportService = ExportService()
            let content = exportService.exportSummaryMarkdown(meeting: meeting, summary: summary)
            ShareService.share(content)
        }
    }

    private func deleteMeeting() {
        Task {
            do {
                try await appState.meetingRepository.delete(meeting)
                if appState.selectedMeetingId == meeting.id {
                    appState.selectedMeetingId = nil
                }
                appState.loadMeetings()
            } catch {
                onError?("Failed to delete meeting: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Previews

#Preview("Scheduled Meeting") {
    MeetingListRow(meeting: Meeting(
        title: "Weekly Standup",
        scheduledStartDate: Date().addingTimeInterval(3600),
        status: .scheduled
    ))
    .environment(AppState())
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
    .environment(AppState())
    .padding()
    .frame(width: 320)
}

#Preview("Recording Meeting") {
    MeetingListRow(meeting: Meeting(
        title: "Sprint Planning",
        startDate: Date().addingTimeInterval(-1800),
        status: .recording
    ))
    .environment(AppState())
    .padding()
    .frame(width: 320)
}

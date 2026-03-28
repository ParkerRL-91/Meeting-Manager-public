import SwiftUI

struct MeetingDetailView: View {
    let meetingId: String

    @Environment(AppState.self) private var appState
    @State private var meeting: Meeting?
    @State private var selectedTab: DetailTab = .summary

    enum DetailTab: String, CaseIterable {
        case summary, transcript, notes

        var label: String { rawValue.capitalized }

        var icon: String {
            switch self {
            case .summary: return "doc.text"
            case .transcript: return "text.quote"
            case .notes: return "note.text"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let meeting {
                MeetingMetadataHeader(meeting: meeting)

                Picker("Tab", selection: $selectedTab) {
                    ForEach(DetailTab.allCases, id: \.self) { tab in
                        Label(tab.label, systemImage: tab.icon)
                            .tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                Divider()
                    .foregroundStyle(Color.appSeparator)

                switch selectedTab {
                case .summary:
                    SummaryView(meetingId: meetingId)
                case .transcript:
                    FullTranscriptView(meetingId: meetingId)
                case .notes:
                    NotesReviewView(meetingId: meetingId)
                }
            } else {
                Spacer()
                ProgressView("Loading meeting...")
                    .foregroundStyle(Color.appTextSecondary)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appBackground)
        .task {
            meeting = try? await appState.meetingRepository.find(id: meetingId)
        }
    }
}

// MARK: - Preview

#Preview("Detail View") {
    MeetingDetailView(meetingId: "preview-1")
        .environment(AppState())
        .frame(width: 600, height: 700)
}

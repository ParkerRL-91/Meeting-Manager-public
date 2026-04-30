import SwiftUI

struct NotesReviewView: View {
    let meetingId: String

    @Environment(AppState.self) private var appState
    @State private var notes: [MeetingNote] = []
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading {
                Spacer()
                ProgressView()
                Spacer()
            } else if notes.isEmpty {
                Spacer()
                EmptyStateView(
                    icon: "note.text",
                    title: "No Notes",
                    subtitle: "Notes captured during the meeting will appear here."
                )
                Spacer()
            } else {
                notesList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await loadNotes()
        }
    }

    // MARK: - Notes List

    private var notesList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(notes) { note in
                    noteCard(note)
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private func noteCard(_ note: MeetingNote) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            MarkdownRenderer(text: note.content, baseFontSize: 15)
                .foregroundStyle(Color.appTextPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Image(systemName: "clock")
                    .imageScale(.small)
                Text(DateFormatting.fullDateTime(from: note.createdAt))
            }
            .font(.caption)
            .foregroundStyle(Color.appTextTertiary)
        }
        .padding(12)
        .background(Color.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Data Loading

    private func loadNotes() async {
        isLoading = true
        defer { isLoading = false }
        notes = (try? await appState.noteRepository.notesForMeeting(meetingId)) ?? []
    }
}

// MARK: - Previews

// #Preview("With Notes") {
//     NotesReviewView(meetingId: "preview-1")
//         .environment(AppState())
//         .frame(width: 600, height: 500)
//         .background(Color.appBackground)
// }

// #Preview("Empty") {
//     NotesReviewView(meetingId: "no-notes")
//         .environment(AppState())
//         .frame(width: 600, height: 500)
//         .background(Color.appBackground)
// }

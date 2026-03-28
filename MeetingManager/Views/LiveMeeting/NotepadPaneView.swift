import SwiftUI

/// Right pane: free-form text editor for meeting notes with auto-save.
struct NotepadPaneView: View {
    let meetingId: String
    @Environment(AppState.self) private var appState

    @State private var noteContent: String = ""
    @State private var existingNote: MeetingNote?
    @State private var saveTask: Task<Void, Never>?
    @State private var isSaving = false
    @FocusState private var isEditorFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "note.text")
                    .foregroundStyle(Color.appAccent)
                Text("Notes")
                    .font(.headline)
                    .foregroundStyle(Color.appTextPrimary)
                Spacer()
                if isSaving {
                    Text("Saving...")
                        .font(.caption)
                        .foregroundStyle(Color.appTextTertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // Text editor
            ZStack(alignment: .topLeading) {
                TextEditor(text: $noteContent)
                    .font(.body)
                    .foregroundStyle(Color.appTextPrimary)
                    .scrollContentBackground(.hidden)
                    .focused($isEditorFocused)
                    .padding(8)

                // Placeholder
                if noteContent.isEmpty && !isEditorFocused {
                    Text("Start typing your meeting notes here...\n\n- Action items\n- Key decisions\n- Follow-ups")
                        .font(.body)
                        .foregroundStyle(Color.appTextTertiary)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 16)
                        .allowsHitTesting(false)
                }
            }
            .background(Color.appBackground)
        }
        .background(Color.appBackground)
        .onAppear(perform: loadNote)
        .onChange(of: noteContent) { _, _ in
            scheduleSave()
        }
        .onDisappear {
            saveTask?.cancel()
            // Perform a final synchronous-style save
            saveNoteImmediately()
        }
    }

    // MARK: - Load

    private func loadNote() {
        Task {
            do {
                if let note = try await appState.noteRepository.latestNote(meetingId: meetingId) {
                    await MainActor.run {
                        self.existingNote = note
                        self.noteContent = note.content
                    }
                }
            } catch {
                print("Failed to load note: \(error)")
            }
        }
    }

    // MARK: - Auto-save with Debounce

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return // Cancelled
            }
            await saveNote()
        }
    }

    private func saveNote() async {
        guard !noteContent.isEmpty else { return }
        await MainActor.run { isSaving = true }

        do {
            if var note = existingNote {
                note.content = noteContent
                try await appState.noteRepository.save(&note)
                await MainActor.run { self.existingNote = note }
            } else {
                var note = MeetingNote(meetingId: meetingId, content: noteContent)
                try await appState.noteRepository.save(&note)
                await MainActor.run { self.existingNote = note }
            }
        } catch {
            print("Failed to save note: \(error)")
        }

        await MainActor.run { isSaving = false }
    }

    private func saveNoteImmediately() {
        Task {
            await saveNote()
        }
    }
}

// MARK: - Preview

#Preview {
    NotepadPaneView(meetingId: "preview-123")
        .frame(width: 350, height: 500)
        .environment(AppState())
}

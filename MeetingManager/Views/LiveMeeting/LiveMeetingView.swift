import SwiftUI

/// Live meeting screen — recording controls on top, participants below,
/// notepad as main content, and an optional AI chat sidebar.
/// Transcript runs in background but is not displayed live.
struct LiveMeetingView: View {
    let meetingId: String
    @Environment(AppState.self) private var appState
    @State private var showChat = false
    @State private var meeting: Meeting?

    var body: some View {
        VStack(spacing: 0) {
            RecordingControlBar(meetingId: meetingId)
                .overlay(alignment: .trailing) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showChat.toggle()
                        }
                    } label: {
                        Image(systemName: showChat ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right")
                            .font(.body)
                            .foregroundStyle(showChat ? Color.appAccent : Color.appTextSecondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Toggle AI Chat (Cmd+J)")
                    .padding(.trailing, 12)
                }
            Divider()

            // Participants bar
            if let meeting {
                ParticipantBar(participants: meeting.participantList)
                if !meeting.participantList.isEmpty {
                    Divider()
                }
            }

            // Main content: notes + optional chat
            if showChat {
                HSplitView {
                    NotepadPaneView(meetingId: meetingId)
                        .frame(minWidth: 350)
                    MeetingChatView(meetingId: meetingId)
                        .frame(minWidth: 260, idealWidth: 320)
                }
            } else {
                NotepadPaneView(meetingId: meetingId)
            }
        }
        .background(Color.appBackground)
        .frame(minWidth: showChat ? 750 : 500, minHeight: 400)
        .toggleOnKeyboardShortcut("j", modifiers: .command, binding: $showChat)
        .task {
            if let active = appState.activeMeeting {
                meeting = active
            } else {
                meeting = try? await appState.meetingRepository.find(id: meetingId)
            }
        }
        .onChange(of: appState.activeMeeting?.id) { _, _ in
            if let active = appState.activeMeeting { meeting = active }
        }
    }
}

// MARK: - Keyboard Shortcut Helper

private extension View {
    /// Adds a global keyboard shortcut that toggles a `Bool` binding.
    func toggleOnKeyboardShortcut(
        _ key: KeyEquivalent,
        modifiers: EventModifiers,
        binding: Binding<Bool>
    ) -> some View {
        self.background(
            Button("") {
                withAnimation(.easeInOut(duration: 0.2)) {
                    binding.wrappedValue.toggle()
                }
            }
            .keyboardShortcut(key, modifiers: modifiers)
            .hidden()
        )
    }
}

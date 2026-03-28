import SwiftUI

/// Flagship live meeting screen with split-screen layout:
/// recording controls on top, real-time transcript on the left, notepad on the right,
/// and an optional AI chat sidebar.
struct LiveMeetingView: View {
    let meetingId: String
    @Environment(AppState.self) private var appState
    @State private var showChat = false

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
            HSplitView {
                TranscriptPaneView(meetingId: meetingId)
                    .frame(minWidth: 300)
                NotepadPaneView(meetingId: meetingId)
                    .frame(minWidth: 250)
                if showChat {
                    MeetingChatView(meetingId: meetingId)
                        .frame(minWidth: 260, idealWidth: 320)
                }
            }
        }
        .background(Color.appBackground)
        .frame(minWidth: showChat ? 960 : 700, minHeight: 400)
        .toggleOnKeyboardShortcut("j", modifiers: .command, binding: $showChat)
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

// MARK: - Preview

// #Preview {
//     LiveMeetingView(meetingId: "preview-123")
//         .frame(width: 900, height: 600)
//         .environment(AppState())
// }

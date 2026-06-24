import SwiftUI

/// Right-side chat sidebar for asking AI questions about the ongoing meeting.
struct MeetingChatView: View {
    let meetingId: String
    @Environment(AppState.self) private var appState

    @State private var messages: [ChatMessage] = []
    @State private var inputText: String = ""
    @State private var chatService: MeetingChatService?
    @State private var chatMessageRepo: ChatMessageRepository?
    @State private var lastFailedQuestion: String?
    @State private var loadTask: Task<Void, Never>?
    @State private var sendTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "bubble.left.and.bubble.right")
                    .foregroundStyle(Color.appAccent)
                Text("AI Chat")
                    .font(.headline)
                    .foregroundStyle(Color.appTextPrimary)
                Spacer()
                Text("\(messages.count) messages")
                    .font(.caption)
                    .foregroundStyle(Color.appTextTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // Messages
            if messages.isEmpty && chatService?.isProcessing != true {
                emptyPlaceholder
            } else {
                messageList
            }

            // Error display
            if let error = chatService?.lastError {
                errorBanner(error)
            }

            Divider()

            // Input bar
            inputBar
        }
        .background(Color.appBackground)
        .onAppear(perform: setup)
        .onDisappear {
            loadTask?.cancel()
            sendTask?.cancel()
        }
    }

    // MARK: - Subviews

    /// Empty state for the in-meeting chat. Renders a single "starter
    /// bubble" that visually mirrors a real assistant message — same
    /// avatar, same surface — so the chat doesn't feel hollow when no
    /// conversation has been started yet. Earlier version used a centered
    /// icon-and-caption block which read as "this is broken / loading"
    /// rather than "ready and waiting."
    private var emptyPlaceholder: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 8) {
                // Assistant-style avatar so the starter bubble visually
                // matches what a real assistant reply will look like once
                // the user starts chatting.
                ZStack {
                    Circle()
                        .fill(Color.appAccent.opacity(0.18))
                        .frame(width: 26, height: 26)
                    Image(systemName: "sparkles")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.appAccentLight)
                }
                .padding(.top, 2)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Assistant")
                        .font(.caption2)
                        .foregroundStyle(Color.appTextTertiary)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Start your chat by replying here.")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.appTextPrimary)
                        Text("Try: \u{201C}What decisions were made?\u{201D} or \u{201C}Summarise the last 5 minutes.\u{201D}")
                            .font(.caption)
                            .foregroundStyle(Color.appTextTertiary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.appSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                Spacer(minLength: 16)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(messages) { message in
                        chatBubble(for: message)
                            .id(message.id)
                    }

                    if chatService?.isProcessing == true {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Thinking...")
                                .font(.caption)
                                .foregroundStyle(Color.appTextSecondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .id("loading")
                    }
                }
                .padding(.vertical, 8)
            }
            .onChange(of: messages.count) {
                withAnimation {
                    if let lastId = messages.last?.id {
                        proxy.scrollTo(lastId, anchor: .bottom)
                    }
                }
            }
            .onChange(of: chatService?.isProcessing) {
                if chatService?.isProcessing == true {
                    withAnimation {
                        proxy.scrollTo("loading", anchor: .bottom)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func chatBubble(for message: ChatMessage) -> some View {
        HStack {
            if message.isUser { Spacer(minLength: 40) }

            VStack(alignment: message.isUser ? .trailing : .leading, spacing: 2) {
                Text(message.isUser ? "You" : "Assistant")
                    .font(.caption2)
                    .foregroundStyle(Color.appTextTertiary)

                Group {
                    if message.isUser {
                        Text(message.content)
                            .font(.system(size: 14))
                            .foregroundStyle(Color.appTextPrimary)
                    } else {
                        MarkdownRenderer(text: message.content, baseFontSize: 14)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    message.isUser
                        ? Color.appAccent.opacity(0.2)
                        : Color.appSurface
                )
                .clipShape(RoundedRectangle(cornerRadius: 10))

                // PRJ-014: KB documents fed to the model as background for this
                // answer. Renders only when non-empty.
                if message.isAssistant, !message.kbSources.isEmpty {
                    KBReferencesView(kbSources: message.kbSources)
                        .padding(.horizontal, 10)
                        .padding(.top, 2)
                }
            }

            if message.isAssistant { Spacer(minLength: 40) }
        }
        .padding(.horizontal, 12)
    }

    private func errorBanner(_ error: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.appWarning)
            Text(error)
                .font(.caption)
                .foregroundStyle(Color.appTextSecondary)
                .lineLimit(2)
            Spacer()
            Button("Retry") {
                retryLastQuestion()
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .foregroundStyle(Color.appAccent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.appSurface)
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Ask about this meeting...", text: $inputText)
                .textFieldStyle(.plain)
                .font(.body)
                .foregroundStyle(Color.appTextPrimary)
                .onSubmit(sendMessage)

            Button(action: sendMessage) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(
                        inputText.trimmingCharacters(in: .whitespaces).isEmpty
                            ? Color.appTextTertiary
                            : Color.appAccent
                    )
            }
            .buttonStyle(.borderless)
            .disabled(inputText.trimmingCharacters(in: .whitespaces).isEmpty || chatService?.isProcessing == true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Actions

    private func setup() {
        let repo = ChatMessageRepository(database: appState.database)
        chatMessageRepo = repo

        let service = MeetingChatService(
            transcriptRepository: appState.transcriptRepository,
            chatMessageRepository: repo
        )
        chatService = service

        loadTask = Task {
            do {
                messages = try await repo.messagesForMeeting(meetingId)
            } catch {
                // Messages will remain empty on failure
            }
        }
    }

    /// Builds a textGenerator closure using the app's central AI routing.
    private func buildTextGenerator() async -> ((String, String) async throws -> String)? {
        if let generator = await appState.makeTextGenerator() { return generator }
        chatService?.lastError = "No AI configured. Choose a provider in Settings → AI."
        return nil
    }

    private func sendMessage() {
        let question = inputText.trimmingCharacters(in: .whitespaces)
        guard !question.isEmpty, let service = chatService, let repo = chatMessageRepo else { return }

        inputText = ""
        lastFailedQuestion = question

        // EXEMPT from TaskQueue: interactive conversational AI chat during live meeting.
        // Scoped to this view; user expects immediate streaming response.
        // Cancellation on view disappear is appropriate (user left the chat panel).
        sendTask = Task {
            guard let textGenerator = await buildTextGenerator() else { return }
            do {
                let meeting = try? await appState.meetingRepository.find(id: meetingId)
                try await service.sendQuery(meetingId: meetingId, question: question, meeting: meeting, textGenerator: textGenerator)
                messages = try await repo.messagesForMeeting(meetingId)
                lastFailedQuestion = nil
            } catch {
                messages = (try? await repo.messagesForMeeting(meetingId)) ?? messages
            }
        }
    }

    private func retryLastQuestion() {
        guard let question = lastFailedQuestion, let service = chatService, let repo = chatMessageRepo else { return }
        service.clearError()

        sendTask = Task { // EXEMPT: same as sendMessage
            guard let textGenerator = await buildTextGenerator() else { return }
            do {
                let meeting = try? await appState.meetingRepository.find(id: meetingId)
                try await service.sendQuery(meetingId: meetingId, question: question, meeting: meeting, textGenerator: textGenerator)
                messages = try await repo.messagesForMeeting(meetingId)
                lastFailedQuestion = nil
            } catch {
                messages = (try? await repo.messagesForMeeting(meetingId)) ?? messages
            }
        }
    }
}

// MARK: - Preview

// #Preview {
//     MeetingChatView(meetingId: "preview-123")
//         .frame(width: 300, height: 500)
//         .environment(AppState())
// }

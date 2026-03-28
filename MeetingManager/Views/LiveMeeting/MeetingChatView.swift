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
    }

    // MARK: - Subviews

    private var emptyPlaceholder: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.largeTitle)
                .foregroundStyle(Color.appTextTertiary)
            Text("Ask questions about the meeting")
                .font(.subheadline)
                .foregroundStyle(Color.appTextSecondary)
            Text("e.g. \"What decisions were made?\"")
                .font(.caption)
                .foregroundStyle(Color.appTextTertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
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

                Text(message.content)
                    .font(.body)
                    .foregroundStyle(Color.appTextPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        message.isUser
                            ? Color.appAccent.opacity(0.2)
                            : Color.appSurface
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 10))
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
            claudeService: ClaudeService(),
            transcriptRepository: appState.transcriptRepository,
            chatMessageRepository: repo
        )
        chatService = service

        Task {
            do {
                messages = try await repo.messagesForMeeting(meetingId)
            } catch {
                // Messages will remain empty on failure
            }
        }
    }

    private func sendMessage() {
        let question = inputText.trimmingCharacters(in: .whitespaces)
        guard !question.isEmpty, let service = chatService, let repo = chatMessageRepo else { return }

        inputText = ""
        lastFailedQuestion = question

        Task {
            do {
                try await service.sendQuery(meetingId: meetingId, question: question)
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

        Task {
            do {
                try await service.sendQuery(meetingId: meetingId, question: question)
                messages = try await repo.messagesForMeeting(meetingId)
                lastFailedQuestion = nil
            } catch {
                messages = (try? await repo.messagesForMeeting(meetingId)) ?? messages
            }
        }
    }
}

// MARK: - Preview

#Preview {
    MeetingChatView(meetingId: "preview-123")
        .frame(width: 300, height: 500)
        .environment(AppState())
}

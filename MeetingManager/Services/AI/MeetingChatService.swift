import Foundation
import os

/// Error types specific to the meeting chat feature.
enum MeetingChatError: LocalizedError {
    case noTranscriptAvailable
    case chatFailed(Error)

    var errorDescription: String? {
        switch self {
        case .noTranscriptAvailable:
            return "No transcript available yet. Start recording to use the chat."
        case .chatFailed(let error):
            return "Chat failed: \(error.localizedDescription)"
        }
    }
}

/// Orchestrates AI-powered Q&A about an ongoing meeting by combining recent
/// transcript context with the user's question and sending it to the Claude API.
@Observable
@MainActor
final class MeetingChatService {

    // MARK: - Public State

    private(set) var isProcessing = false
    var lastError: String?

    // MARK: - Dependencies

    private let transcriptRepository: TranscriptRepository
    private let chatMessageRepository: ChatMessageRepository

    init(
        transcriptRepository: TranscriptRepository,
        chatMessageRepository: ChatMessageRepository
    ) {
        self.transcriptRepository = transcriptRepository
        self.chatMessageRepository = chatMessageRepository
    }

    // MARK: - Public API

    /// Sends a question about the current meeting to an AI, using recent transcript as context.
    ///
    /// - Parameters:
    ///   - meetingId: The meeting to query about.
    ///   - question: The user's question.
    ///   - textGenerator: A closure that takes (systemPrompt, userPrompt) and returns generated text.
    ///   - recentTranscriptMinutes: How many minutes of recent transcript to include (default 10).
    /// - Returns: The assistant's response text.
    @discardableResult
    func sendQuery(
        meetingId: String,
        question: String,
        meeting: Meeting? = nil,
        textGenerator: (String, String) async throws -> String,
        recentTranscriptMinutes: Double = 10
    ) async throws -> String {
        isProcessing = true
        lastError = nil
        defer { isProcessing = false }

        Logger.ai.info("Meeting chat query for \(meetingId): \(question)")

        // 1. Fetch recent transcript segments
        let allSegments = try await transcriptRepository.transcriptsForMeeting(meetingId)

        let transcript: String
        if allSegments.isEmpty {
            transcript = "(No transcript available yet)"
        } else {
            // Filter to recent N minutes based on the latest segment's end time
            let latestTime = allSegments.last?.endTime ?? 0
            let cutoff = max(0, latestTime - (recentTranscriptMinutes * 60))
            let recentSegments = allSegments.filter { $0.startTime >= cutoff }

            transcript = recentSegments.map { segment in
                "[\(segment.formattedTimestamp)] \(segment.speakerDisplayName): \(segment.text)"
            }.joined(separator: "\n")
        }

        // 2. Pull KB excerpts relevant to the user's question + meeting topic.
        // Empty when no KB folder is configured. Capture the structured sources
        // so the chat message can show "Context from your Knowledge Base".
        let kbExcerpts: String
        let kbSources: [KBSourceRef]
        if let meeting {
            (kbExcerpts, kbSources) = await KnowledgeBaseService.shared.retrieve(
                for: meeting,
                chatQuery: question
            )
        } else {
            kbExcerpts = ""
            kbSources = []
        }
        let kbBlock = kbExcerpts.isEmpty ? "" : """

            Excerpts from the user's Knowledge Base, provided as background context for this answer:
            \(kbExcerpts)
            """

        // Meeting metadata header — title, date, participants — so the assistant
        // can answer from the meeting's *context*, not just the raw transcript.
        let meetingBlock: String = {
            guard let meeting else { return "" }
            let parts = meeting.participantList.isEmpty
                ? "Not recorded"
                : meeting.participantList.joined(separator: ", ")
            let when = meeting.startDate ?? meeting.scheduledStartDate
            let whenStr = when?.formatted() ?? "Unknown"
            return """
                Meeting: \(meeting.title)
                When: \(whenStr)
                Participants: \(parts)

                """
        }()

        // 3. Build prompts
        let systemPrompt = """
            You are a helpful meeting assistant. Answer questions about this meeting \
            using the meeting details, transcript, and Knowledge Base context below.

            Formatting rules — always follow these:
            - Respond in Markdown.
            - Use bullet lists for facts, names, action items, and decisions.
            - Use **bold** for names, key phrases, and decisions.
            - Use ## headings when an answer has multiple distinct parts.
            - Keep answers concise — 100–250 words unless depth is clearly needed.
            - Never write walls of unbroken prose.

            \(meetingBlock)Transcript:
            \(transcript)\(kbBlock)
            """

        // 3. Save user message
        var userMessage = ChatMessage(
            meetingId: meetingId,
            role: "user",
            content: question
        )
        try await chatMessageRepository.save(&userMessage)

        // 4. Call AI (Claude or Ollama via textGenerator closure)
        let response: String
        do {
            response = try await textGenerator(systemPrompt, question)
        } catch {
            let chatError = MeetingChatError.chatFailed(error)
            lastError = chatError.localizedDescription
            Logger.ai.error("Meeting chat failed: \(error.localizedDescription)")
            throw chatError
        }

        // 5. Save assistant message
        var assistantMessage = ChatMessage(
            meetingId: meetingId,
            role: "assistant",
            content: response
        )
        assistantMessage.kbSources = kbSources
        try await chatMessageRepository.save(&assistantMessage)

        Logger.ai.info("Meeting chat response saved for \(meetingId)")

        return response
    }

    /// Sends a "catch me up" summary covering everything so far and the current topic.
    @discardableResult
    func catchMeUp(
        meetingId: String,
        meeting: Meeting? = nil,
        textGenerator: (String, String) async throws -> String
    ) async throws -> String {
        let question = "Catch me up: give a brief summary of everything discussed so far and what the current topic is."
        return try await sendQuery(
            meetingId: meetingId,
            question: question,
            meeting: meeting,
            textGenerator: textGenerator,
            recentTranscriptMinutes: .infinity
        )
    }

    /// Clears the error state.
    func clearError() {
        lastError = nil
    }
}

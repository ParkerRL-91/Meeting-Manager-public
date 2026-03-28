import Foundation
import os

/// Orchestrates the end-to-end flow of generating an AI meeting summary:
/// fetching data, building the prompt, calling the Claude API, and persisting the result.
@Observable
@MainActor
final class SummaryGenerator {

    // MARK: - Public State

    private(set) var isGenerating = false
    private(set) var progress: String = ""

    // MARK: - Dependencies

    private let promptManager = PromptManager()

    // MARK: - Summary Generation

    /// Generates a summary for the given meeting.
    ///
    /// - Parameters:
    ///   - meeting: The meeting to summarize.
    ///   - transcriptRepo: Repository providing transcript text.
    ///   - noteRepo: Repository providing user notes.
    ///   - summaryRepo: Repository for persisting the generated summary.
    ///   - claudeService: The Claude API service.
    ///   - settings: The user's app settings.
    /// - Returns: The saved `MeetingSummary`.
    @discardableResult
    func generateSummary(
        for meeting: Meeting,
        transcriptRepo: TranscriptRepository,
        noteRepo: NoteRepository,
        summaryRepo: SummaryRepository,
        claudeService: ClaudeService,
        settings: AppSettings = .default
    ) async throws -> MeetingSummary {
        guard settings.aiEnabled else {
            Logger.ai.info("AI is disabled — skipping summary generation for meeting \(meeting.id)")
            throw ClaudeServiceError.aiDisabled
        }

        isGenerating = true
        progress = "Fetching transcript..."
        defer {
            isGenerating = false
            progress = ""
        }

        Logger.ai.info("Starting summary generation for meeting \(meeting.id)")

        // 1. Fetch transcript and notes
        let transcript = try await transcriptRepo.fullText(meetingId: meeting.id)
        progress = "Fetching notes..."
        let notes = try await noteRepo.combinedNotes(meetingId: meeting.id)

        // 2. Build prompt
        progress = "Building prompt..."
        let template = promptManager.loadTemplate(settings: settings)
        let userPrompt = promptManager.substituteVariables(
            template: template,
            meeting: meeting,
            transcript: transcript,
            notes: notes
        )

        let systemPrompt = "You are a professional meeting assistant. "
            + "Provide clear, well-structured summaries."

        // 3. Call Claude API
        progress = "Generating summary with Claude..."
        let model = settings.claudeModel
        let summaryText = try await claudeService.sendMessage(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            model: model
        )

        // 4. Create and save MeetingSummary
        progress = "Saving summary..."
        var summary = MeetingSummary(
            meetingId: meeting.id,
            promptUsed: userPrompt,
            summaryText: summaryText,
            modelUsed: model,
            generatedAt: Date()
        )
        try await summaryRepo.save(&summary)

        Logger.ai.info("Summary saved for meeting \(meeting.id), id=\(summary.id ?? -1)")

        return summary
    }
}

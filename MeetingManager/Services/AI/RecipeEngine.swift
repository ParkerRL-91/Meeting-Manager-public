import Foundation
import os

/// Executes recipe prompt templates against meeting data using the Claude API.
@Observable
@MainActor
final class RecipeEngine {

    // MARK: - Public State

    private(set) var isProcessing = false
    private(set) var lastError: String?

    // MARK: - Dependencies

    private let promptManager = PromptManager()

    // MARK: - Recipe Execution

    /// Executes a recipe against a meeting, substituting template variables
    /// with meeting data and calling the Claude API.
    ///
    /// - Parameters:
    ///   - recipe: The recipe to execute.
    ///   - meeting: The meeting to run the recipe on.
    ///   - transcriptRepo: Repository providing transcript text.
    ///   - noteRepo: Repository providing user notes.
    ///   - resultRepo: Repository for persisting the generated result.
    ///   - claudeService: The Claude API service.
    ///   - settings: The user's app settings.
    /// - Returns: The generated output text.
    @discardableResult
    func execute(
        recipe: Recipe,
        meeting: Meeting,
        transcriptRepo: TranscriptRepository,
        noteRepo: NoteRepository,
        resultRepo: RecipeResultRepository,
        claudeService: ClaudeService,
        settings: AppSettings = .default
    ) async throws -> String {
        guard settings.aiEnabled else {
            Logger.ai.info("AI is disabled — skipping recipe '\(recipe.name)' for meeting \(meeting.id)")
            throw ClaudeServiceError.aiDisabled
        }

        isProcessing = true
        lastError = nil
        defer { isProcessing = false }

        do {
            Logger.ai.info("Executing recipe '\(recipe.name)' for meeting \(meeting.id)")

            // 1. Fetch transcript and notes
            let transcript = try await transcriptRepo.fullText(meetingId: meeting.id)
            let notes = try await noteRepo.combinedNotes(meetingId: meeting.id)

            // 2. Substitute template variables
            let userPrompt = promptManager.substituteVariables(
                template: recipe.promptTemplate,
                meeting: meeting,
                transcript: transcript,
                notes: notes
            )

            let systemPrompt = "You are a professional meeting assistant. "
                + "Produce clear, well-structured output based on the meeting data provided."

            // 3. Call Claude API
            let model = settings.claudeModel
            let outputText = try await claudeService.sendMessage(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                model: model
            )

            // 4. Save result
            var result = RecipeResult(
                meetingId: meeting.id,
                recipeId: recipe.id,
                outputText: outputText
            )
            try await resultRepo.save(&result)

            Logger.ai.info("Recipe '\(recipe.name)' completed for meeting \(meeting.id), result id=\(result.id ?? -1)")

            return outputText
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }
}

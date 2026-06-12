import Foundation
import os

/// Executes recipe prompt templates against meeting data using the Claude API.
@Observable
@MainActor
final class RecipeEngine {

    // MARK: - Public State

    private(set) var isProcessing = false
    var lastError: String?

    // MARK: - Dependencies

    private let promptManager = PromptManager()

    // MARK: - Recipe Execution

    /// Executes a recipe against a meeting, substituting template variables
    /// with meeting data and calling the provided text generator (Claude or Ollama).
    ///
    /// - Parameters:
    ///   - recipe: The recipe to execute.
    ///   - meeting: The meeting to run the recipe on.
    ///   - transcriptRepo: Repository providing transcript text.
    ///   - noteRepo: Repository providing user notes.
    ///   - resultRepo: Repository for persisting the generated result.
    ///   - textGenerator: A closure that takes (systemPrompt, userPrompt) and returns generated text.
    /// - Returns: The generated output text.
    @discardableResult
    func execute(
        recipe: Recipe,
        meeting: Meeting,
        transcriptRepo: TranscriptRepository,
        noteRepo: NoteRepository,
        resultRepo: RecipeResultRepository,
        receiptsProvider: (() async -> (commitments: String, carried: String))? = nil,
        textGenerator: (String, String) async throws -> String
    ) async throws -> String {
        isProcessing = true
        lastError = nil
        defer { isProcessing = false }

        do {
            Logger.ai.info("Executing recipe '\(recipe.name)' for meeting \(meeting.id)")

            // 1. Fetch transcript and notes
            let transcript = try await transcriptRepo.fullText(meetingId: meeting.id)
            let notes = try await noteRepo.combinedNotes(meetingId: meeting.id)

            // TASK-066: resolve receipts only when the template asks for them.
            var receipts: (commitments: String, carried: String) = ("", "")
            if let receiptsProvider,
               recipe.promptTemplate.contains("{{commitmentsWithReceipts}}")
                || recipe.promptTemplate.contains("{{carriedQuestions}}") {
                receipts = await receiptsProvider()
            }

            // 2. Substitute template variables
            let userPrompt = promptManager.substituteVariables(
                template: recipe.promptTemplate,
                meeting: meeting,
                transcript: transcript,
                notes: notes,
                commitmentsWithReceipts: receipts.commitments,
                carriedQuestions: receipts.carried
            )

            let systemPrompt = "You are a professional meeting assistant. "
                + "Produce clear, well-structured output based on the meeting data provided."

            // 3. Call AI (Claude or Ollama via textGenerator closure)
            let outputText = try await textGenerator(systemPrompt, userPrompt)

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

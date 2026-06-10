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
    ///   - textGenerator: Async closure `(systemPrompt, userPrompt) -> responseText`. May be Claude or a local LLM.
    ///   - modelUsed: Human-readable model identifier stored in the summary record (e.g. "claude-sonnet-4-6").
    ///   - settings: The user's app settings.
    /// - Returns: The saved `MeetingSummary`.
    @discardableResult
    func generateSummary(
        for meeting: Meeting,
        transcriptRepo: TranscriptRepository,
        noteRepo: NoteRepository,
        summaryRepo: SummaryRepository,
        textGenerator: (String, String) async throws -> String,
        modelUsed: String,
        settings: AppSettings = .default
    ) async throws -> MeetingSummary {
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

        // Pull cached related-meetings context so the summary can weave in
        // prior threads ("picks up where last week's pricing review left off").
        // Empty string when no context is cached — substituteVariables handles the fallback.
        let related = RelevantMeetingService.parseContext(from: meeting.contextJSON)
        let priorContext: String
        if related.isEmpty {
            priorContext = ""
        } else {
            let dateFmt = DateFormatter()
            dateFmt.dateStyle = .medium
            priorContext = related.prefix(3).map { r in
                "- **\(r.title)** (\(dateFmt.string(from: r.date))): \(r.summaryExcerpt)"
            }.joined(separator: "\n")
        }

        // Pull KB excerpts (returns "" when no folder is configured —
        // substituteVariables falls back to "No Knowledge Base configured").
        let kbContext = await KnowledgeBaseService.shared.retrieveContext(for: meeting)

        let userPrompt = promptManager.substituteVariables(
            template: template,
            meeting: meeting,
            transcript: transcript,
            notes: notes,
            priorContext: priorContext,
            knowledgeBase: kbContext
        )

        // System prompt anchors the model to the structure in the user prompt.
        // A weak system prompt lets the model fall back to its own preferred
        // format (tables, numbered lists, etc.) and ignore detailed rules.
        let systemPrompt = """
        You are a precise meeting analyst. You output Markdown summaries that follow the exact section structure and formatting rules the user requests.

        Hard rules — these always apply:
        - Use only the exact headings the user prompt specifies. Never substitute your own.
        - Use bullets only — never Markdown tables. No `| col | col |` rows, no `|---|---|` separators.
        - No HTML tags of any kind: no `<br>`, no `<p>`, no `&nbsp;`.
        - Bold the first phrase of every bullet in discussion, decision, action, and question sections.
        - Be specific. Do not write generic phrases like "the team discussed X". Name the people, the positions, the evidence.
        - Never invent content. If a fact, name, or commitment is not in the transcript or notes, omit it.
        - Match length to substance: a dense 600-word summary beats a padded 1500-word one.
        """

        // 3. Generate summary text
        progress = "Generating summary..."
        let summaryText = try await textGenerator(systemPrompt, userPrompt)

        // 4. Create and save MeetingSummary
        progress = "Saving summary..."
        var summary = MeetingSummary(
            meetingId: meeting.id,
            promptUsed: userPrompt,
            summaryText: summaryText,
            modelUsed: modelUsed,
            generatedAt: Date()
        )
        try await summaryRepo.save(&summary)

        Logger.ai.info("Summary saved for meeting \(meeting.id), id=\(summary.id ?? -1)")

        return summary
    }
}

import Foundation
import os

/// Extracts action items from meeting transcripts using the Claude API.
@Observable
@MainActor
final class ActionItemExtractor {

    // MARK: - Public State

    private(set) var isProcessing = false
    var lastError: String?

    // MARK: - Extraction

    /// Extracts action items from the transcript of the given meeting.
    ///
    /// - Parameters:
    ///   - meeting: The meeting to extract action items from.
    ///   - transcriptRepo: Repository providing transcript text.
    ///   - actionItemRepo: Repository for persisting extracted items.
    ///   - textGenerator: A closure that takes (systemPrompt, userPrompt) and returns generated text.
    /// - Returns: The extracted and saved action items.
    @discardableResult
    func extractActionItems(
        for meeting: Meeting,
        transcriptRepo: TranscriptRepository,
        actionItemRepo: ActionItemRepository,
        textGenerator: (String, String) async throws -> String
    ) async throws -> [ActionItem] {
        isProcessing = true
        lastError = nil
        defer { isProcessing = false }

        Logger.ai.info("Starting action item extraction for meeting \(meeting.id)")

        // 1. Fetch full transcript
        let transcript = try await transcriptRepo.fullText(meetingId: meeting.id)

        guard !transcript.isEmpty else {
            Logger.ai.warning("No transcript available for meeting \(meeting.id)")
            lastError = "No transcript available for this meeting."
            return []
        }

        // 2. Build prompts
        let systemPrompt = """
            You are a professional meeting assistant that extracts action items from meeting transcripts. \
            Return ONLY a JSON array of action items. Each action item is an object with these fields:
            - "title" (string, required): A concise description of the action item.
            - "assignee" (string or null): The person responsible, if mentioned.
            - "dueDate" (string or null): ISO 8601 date (yyyy-MM-dd) if a deadline is mentioned.
            Do not include any text outside the JSON array. If there are no action items, return an empty array [].
            """

        let userPrompt = "Extract action items from this meeting transcript:\n\n\(transcript)"

        // 3. Call AI (Claude or Ollama via textGenerator closure)
        let responseText = try await textGenerator(systemPrompt, userPrompt)

        // 4. Parse JSON response
        let items = try parseActionItems(from: responseText, meetingId: meeting.id)

        // 5. Save batch
        try await actionItemRepo.saveBatch(items)

        Logger.ai.info("Extracted \(items.count) action items for meeting \(meeting.id)")

        return items
    }

    // MARK: - Private

    private struct RawActionItem: Decodable {
        let title: String
        let assignee: String?
        let dueDate: String?
    }

    private func parseActionItems(from text: String, meetingId: String) throws -> [ActionItem] {
        // Strip markdown code fences if present
        let cleaned = text
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8) else {
            lastError = "Failed to parse action items response."
            return []
        }

        let decoder = JSONDecoder()
        let rawItems: [RawActionItem]
        do {
            rawItems = try decoder.decode([RawActionItem].self, from: data)
        } catch {
            Logger.ai.error("Failed to decode action items JSON: \(error.localizedDescription)")
            lastError = "Failed to parse action items from AI response."
            throw error
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")

        let now = Date()
        return rawItems.map { raw in
            ActionItem(
                meetingId: meetingId,
                title: raw.title,
                assignee: raw.assignee,
                dueDate: raw.dueDate.flatMap { dateFormatter.date(from: $0) },
                isCompleted: false,
                extractedAt: now
            )
        }
    }
}

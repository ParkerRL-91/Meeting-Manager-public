import Foundation
import os

/// Generates short meeting titles from transcript or summary content.
///
/// Uses local Ollama if available (pass in the app's `OllamaService` instance);
/// callers should fall back to `extractFromSummary(_:)` if `generate(...)` returns
/// nil. No data leaves the device — all generation is local.
@MainActor
final class TitleGenerationService {
    static let shared = TitleGenerationService()
    private let logger = Logger(subsystem: "com.meetingmanager.app", category: "TitleGeneration")

    /// Cap so we never persist a runaway model output as a title.
    private let maxTitleLength = 80

    private init() {}

    /// Generate a 5-7 word title from transcript text using local Ollama.
    ///
    /// - Parameters:
    ///   - text: Full transcript text (any length — only the first ~1500 chars are used).
    ///   - ollama: The app's `OllamaService` instance. Caller must have refreshed status
    ///     at least once so `isReachable` / `availableModels` are populated; if Ollama
    ///     is unreachable this method short-circuits to nil.
    /// - Returns: A trimmed title (no quotes, no trailing punctuation) or nil on any
    ///   failure. Callers should fall back to `extractFromSummary(_:)`.
    func generate(fromTranscript text: String, using ollama: OllamaService) async -> String? {
        // Use first ~1500 chars of transcript as input (about 300 tokens)
        let excerpt = String(text.prefix(1500))
        guard !excerpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            logger.debug("generate: empty transcript excerpt — skipping")
            return nil
        }

        // Skip the network round-trip if we already know Ollama isn't up.
        guard ollama.isReachable, !ollama.availableModels.isEmpty else {
            logger.info("generate: Ollama not reachable — caller should fall back")
            return nil
        }

        let systemPrompt = """
        You generate concise meeting titles. Return ONLY the title — \
        no quotes, no punctuation, no explanation, no prefix like "Title:".
        """

        let userPrompt = """
        Generate a concise meeting title (5 to 7 words, no punctuation, no quotes) \
        based on this transcript excerpt. Return ONLY the title, nothing else.

        Transcript:
        \(excerpt)
        """

        do {
            let raw = try await ollama.generate(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                model: "auto"
            )
            return Self.sanitize(raw, maxLength: maxTitleLength)
        } catch {
            logger.error("generate: Ollama call failed — \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Fallback: extract first sentence from summary text as title.
    func extractFromSummary(_ summary: String) -> String? {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Take first sentence, truncate to ~7 words
        let firstLine = trimmed.components(separatedBy: .newlines).first ?? trimmed
        let sentence = firstLine.components(separatedBy: ". ").first ?? firstLine
        let words = sentence.split(separator: " ", maxSplits: 7, omittingEmptySubsequences: true)
        let title = words.prefix(7).joined(separator: " ")
        let cleaned = Self.sanitize(title, maxLength: maxTitleLength)
        return cleaned
    }

    // MARK: - Helpers

    /// Trim whitespace, surrounding quotes, and trailing punctuation.
    /// Returns nil if the result is empty or longer than `maxLength`.
    private static func sanitize(_ raw: String, maxLength: Int) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Models sometimes wrap output in matching quotes — strip one matched pair.
        let quotePairs: [(Character, Character)] = [
            ("\"", "\""), ("'", "'"), ("\u{201C}", "\u{201D}"), ("\u{2018}", "\u{2019}")
        ]
        for (open, close) in quotePairs {
            if s.count >= 2, s.first == open, s.last == close {
                s = String(s.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }

        // If the model returned multiple lines, keep only the first non-empty line.
        if let firstLine = s.components(separatedBy: .newlines).first(where: {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }) {
            s = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Strip a leading "Title:" / "Meeting Title:" prefix if the model added one.
        for prefix in ["Title:", "Meeting Title:", "title:", "meeting title:"] {
            if s.hasPrefix(prefix) {
                s = String(s.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // Drop trailing sentence-ending punctuation.
        while let last = s.last, ".!?,;:".contains(last) {
            s.removeLast()
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !s.isEmpty, s.count <= maxLength else { return nil }
        return s
    }
}

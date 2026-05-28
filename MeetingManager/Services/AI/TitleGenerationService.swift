import Foundation
import os

/// Generates short (≤8 word) meeting titles from transcript or summary content.
///
/// `generate(...)` prefers local Ollama — it keeps the transcript on-device — and
/// falls back to Claude haiku only when Ollama isn't running or returns an
/// unusable result. Callers should fall back to `extractFromSummary(_:)` if
/// `generate(...)` returns nil. The Ollama path keeps all content on-device; the
/// Claude fallback sends the transcript excerpt to Anthropic.
@MainActor
final class TitleGenerationService {
    static let shared = TitleGenerationService()
    private let logger = Logger(subsystem: "com.meetingmanager.app", category: "TitleGeneration")

    /// Cap so we never persist a runaway model output as a title.
    private let maxTitleLength = 80

    /// The title contract: a generated meeting name is at most this many words.
    private static let maxTitleWords = 8

    private init() {}

    /// Generate an ≤8-word title from transcript text, preferring local Ollama
    /// and falling back to Claude haiku.
    ///
    /// - Parameters:
    ///   - text: Full transcript text (any length — only the first ~1500 chars are used).
    ///   - claudeAPIKey: The Anthropic key, or nil/empty to disable the cloud
    ///     fallback. Only consulted when Ollama is unreachable or returns an
    ///     unusable result.
    ///   - ollama: The app's `OllamaService` instance. Caller must have refreshed status
    ///     at least once so `isReachable` / `availableModels` are populated; if Ollama
    ///     is unreachable this method tries the Claude fallback.
    /// - Returns: A trimmed title (no quotes, no trailing punctuation) or nil on any
    ///   failure. Callers should fall back to `extractFromSummary(_:)`.
    func generate(
        fromTranscript text: String,
        claudeAPIKey: String?,
        ollama: OllamaService
    ) async -> String? {
        // Use first ~1500 chars of transcript as input (about 300 tokens)
        let excerpt = String(text.prefix(1500))
        guard !excerpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            logger.debug("generate: empty transcript excerpt — skipping")
            return nil
        }

        let systemPrompt = """
        You generate concise meeting titles. Return ONLY the title — \
        no quotes, no punctuation, no explanation, no prefix like "Title:".
        """

        let userPrompt = """
        Generate a concise meeting title (8 words or fewer, no punctuation, \
        no quotes) based on this transcript excerpt. Return ONLY the title, \
        nothing else.

        Transcript:
        \(excerpt)
        """

        // Prefer local Ollama: it keeps the transcript on-device. Any failure
        // (or an unusable result) falls through to the Claude fallback.
        if ollama.isReachable, !ollama.availableModels.isEmpty {
            do {
                let raw = try await ollama.generate(
                    systemPrompt: systemPrompt,
                    userPrompt: userPrompt,
                    model: "auto"
                )
                if let title = Self.sanitize(raw, maxLength: maxTitleLength) {
                    return title
                }
                logger.info("generate: Ollama returned an unusable title — trying Claude")
            } catch {
                logger.error("generate: Ollama call failed — \(error.localizedDescription, privacy: .public) — trying Claude")
            }
        }

        // Cloud fallback, used only when local generation is unavailable. Sends
        // the transcript excerpt to Anthropic.
        if let key = claudeAPIKey, !key.isEmpty {
            do {
                let raw = try await ClaudeService().sendMessage(
                    systemPrompt: systemPrompt,
                    userPrompt: userPrompt,
                    model: "claude-haiku-4-5",
                    maxTokens: 64
                )
                return Self.sanitize(raw, maxLength: maxTitleLength)
            } catch {
                logger.error("generate: Claude fallback failed — \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }

        logger.info("generate: no local or cloud provider available — caller should fall back")
        return nil
    }

    /// Fallback: extract first sentence from summary text as title.
    func extractFromSummary(_ summary: String) -> String? {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Take first sentence, clamp to the 8-word title contract.
        let firstLine = trimmed.components(separatedBy: .newlines).first ?? trimmed
        let sentence = firstLine.components(separatedBy: ". ").first ?? firstLine
        let words = sentence.split(separator: " ", maxSplits: Self.maxTitleWords, omittingEmptySubsequences: true)
        let title = words.prefix(Self.maxTitleWords).joined(separator: " ")
        let cleaned = Self.sanitize(title, maxLength: maxTitleLength)
        return cleaned
    }

    // MARK: - Helpers

    /// Trim whitespace, surrounding quotes, and trailing punctuation; clamp to
    /// the ≤`maxTitleWords`-word contract. Returns nil if the result is empty or
    /// longer than `maxLength`. Internal (not private) so the title contract can
    /// be verified directly in tests.
    static func sanitize(_ raw: String, maxLength: Int) -> String? {
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

        // Enforce the title contract deterministically: at most `maxTitleWords`
        // words. The prompt already asks for this, but per ADR-005 we don't trust
        // the prompt — clamping is the guarantee for the occasional long output.
        let words = s.split(separator: " ", omittingEmptySubsequences: true)
        if words.count > maxTitleWords {
            s = words.prefix(maxTitleWords).joined(separator: " ")
        }

        guard !s.isEmpty, s.count <= maxLength else { return nil }
        return s
    }
}

import Foundation
import os

/// Generates short (≤8 word) meeting titles from transcript or summary content.
///
/// `generate(...)` dispatches to whichever AI backend the user has selected
/// (Gemini, Claude, or Ollama). Callers should fall back to
/// `extractFromSummary(_:)` if `generate(...)` returns nil or the selected
/// backend is unavailable.
@MainActor
final class TitleGenerationService {
    static let shared = TitleGenerationService()
    private let logger = Logger(subsystem: "com.meetingmanager.app", category: "TitleGeneration")

    /// Cap so we never persist a runaway model output as a title.
    private let maxTitleLength = 80

    /// The title contract: a generated meeting name is at most this many words.
    private static let maxTitleWords = 8

    private init() {}

    /// Generate an ≤8-word title from transcript text using the selected AI backend.
    ///
    /// - Parameters:
    ///   - text: Full transcript text (any length — only the first ~1500 chars are used).
    ///   - backend: The resolved `AIBackendChoice` from `AppState.resolveAIBackend`.
    ///   - ollama: The app's `OllamaService` instance. Only consulted when
    ///     `backend` is `.ollama`.
    /// - Returns: A trimmed title (no quotes, no trailing punctuation) or nil on any
    ///   failure. Callers should fall back to `extractFromSummary(_:)`.
    func generate(
        fromTranscript text: String,
        backend: AIBackendChoice,
        ollama: OllamaService
    ) async -> String? {
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

        do {
            switch backend {
            case .gemini(let model):
                let raw = try await GeminiService().sendMessage(
                    systemPrompt: systemPrompt, userPrompt: userPrompt,
                    model: model, maxTokens: 64, thinking: false
                )
                return Self.sanitize(raw, maxLength: maxTitleLength)
            case .claude(let model):
                let raw = try await ClaudeService().sendMessage(
                    systemPrompt: systemPrompt, userPrompt: userPrompt,
                    model: model, maxTokens: 64
                )
                return Self.sanitize(raw, maxLength: maxTitleLength)
            case .openai(let model):
                let raw = try await OpenAICompatibleService(provider: .openAI).sendMessage(
                    systemPrompt: systemPrompt, userPrompt: userPrompt,
                    model: model, maxTokens: 64
                )
                return Self.sanitize(raw, maxLength: maxTitleLength)
            case .zai(let model):
                let raw = try await OpenAICompatibleService(provider: .zai).sendMessage(
                    systemPrompt: systemPrompt, userPrompt: userPrompt,
                    model: model, maxTokens: 64
                )
                return Self.sanitize(raw, maxLength: maxTitleLength)
            case .ollama(let model):
                guard ollama.isReachable, !ollama.availableModels.isEmpty else {
                    logger.info("generate: Ollama not reachable — caller should fall back")
                    return nil
                }
                let raw = try await ollama.generate(systemPrompt: systemPrompt, userPrompt: userPrompt, model: model)
                return Self.sanitize(raw, maxLength: maxTitleLength)
            case .none:
                return nil
            }
        } catch {
            logger.error("generate: title generation failed — \(error.localizedDescription, privacy: .public)")
            return nil
        }
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

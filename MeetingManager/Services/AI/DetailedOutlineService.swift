import Foundation
import os

/// Generates the detailed time-stamped outline for a meeting. Single-shot
/// LLM pass over the cleaned transcript (or, if cleanup hasn't run yet,
/// over the deterministic stitch of raw segments).
///
/// Produces a Markdown blob shaped like:
///
/// ```
/// ## [00:00 – 04:32] Introduction and Agenda Setting
/// **Speakers**: Philip, Eva
///
/// Philip opened by introducing the Genomics Trade Mission to Boston…
///
/// - Mission spans 5 days, June 15–19
/// - Anchor event: Festival of Genomics
///
/// ## [04:32 – 12:18] Five-Minute Pitch Strategy
/// …
/// ```
///
/// Saves to `detailedOutline` table keyed by meetingId. Replace-on-write —
/// regeneration overwrites the existing row.
///
/// ## Why this is a separate service from `SummaryGenerator`
///
/// - Different output shape (sectioned vs one-page narrative)
/// - Different prompt template (editable independently in Settings)
/// - Different storage table (so the user can keep a custom-edited
///   summary while the outline regenerates)
/// - Different consumers (the Outline tab; KB write-back may include
///   it later)
///
/// ## Why we accept names in this prompt (vs ADR-005's [TURN N] pattern)
///
/// Transcript cleanup hides speaker names from the LLM because small
/// models will substitute plausible names from outside context (the KB,
/// other meetings). The detailed-outline pass is different: the user
/// explicitly wants speaker attribution per section, the names are
/// already attached to each line in the input, and the prompt is
/// strict about "use exactly what appears in the transcript". The
/// hallucination surface is meaningfully smaller here than for the
/// cleanup pass.
@MainActor
final class DetailedOutlineService {
    static let shared = DetailedOutlineService()
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.meetingmanager.app", category: "DetailedOutline")
    private let promptManager = PromptManager()

    private init() {}

    /// Generate (or regenerate) the detailed outline for one meeting.
    ///
    /// - Parameters:
    ///   - meetingId: which meeting
    ///   - textGenerator: `(systemPrompt, userPrompt) -> output`. The caller
    ///     picks Claude or Ollama based on settings; this service is
    ///     agnostic. Pass `nil` to short-circuit (no AI configured) — the
    ///     service then writes a placeholder blob and returns.
    ///   - modelLabel: e.g. "claude-sonnet-4-6", "ollama/llama3.2:8b" —
    ///     persisted on the row so the UI can show provenance.
    @discardableResult
    func generate(
        meetingId: String,
        meetingRepo: MeetingRepository = MeetingRepository(database: AppDatabase.shared),
        cleanedRepo: CleanedTranscriptRepository = CleanedTranscriptRepository(),
        transcriptRepo: TranscriptRepository = TranscriptRepository(database: AppDatabase.shared),
        outlineRepo: DetailedOutlineRepository = DetailedOutlineRepository(),
        settings: AppSettings,
        textGenerator: ((String, String) async throws -> String)?,
        modelLabel: String
    ) async -> DetailedOutline? {
        guard let meeting = try? await meetingRepo.find(id: meetingId) else {
            Self.logger.warning("[Outline] meeting \(meetingId, privacy: .public) not found")
            return nil
        }

        // Prefer the cleaned transcript — it has consistent timestamps and
        // bold speaker headers that the prompt's section-builder logic can
        // ride on. Fall back to raw transcript text when no cleaned blob
        // exists yet (rare — cleanup runs as part of the post-meeting
        // pipeline before this service is called).
        let transcriptText: String
        if let cleaned = try? await cleanedRepo.cleanedTranscript(meetingId: meetingId), !cleaned.text.isEmpty {
            transcriptText = cleaned.text
        } else {
            transcriptText = (try? await transcriptRepo.fullText(meetingId: meetingId)) ?? ""
        }

        guard !transcriptText.isEmpty else {
            Self.logger.info("[Outline] no transcript content for \(meetingId, privacy: .public) — skipping")
            return nil
        }

        // Resolve template: user-edited value if present, else built-in default.
        let template: String = {
            if let custom = settings.detailedOutlinePromptTemplate?.trimmingCharacters(in: .whitespacesAndNewlines),
               !custom.isEmpty {
                return custom
            }
            return DefaultPrompts.detailedOutline
        }()

        let userPrompt = promptManager.substituteVariables(
            template: template,
            meeting: meeting,
            transcript: transcriptText,
            notes: ""
        )

        // System prompt narrows the role + reinforces the "no preamble"
        // and "ground in transcript" rules. Repeating in both places is
        // belt-and-suspenders for smaller models that drift on long user
        // prompts.
        let systemPrompt = """
        You produce detailed time-stamped meeting outlines as structured Markdown. \
        Every section is `## [mm:ss – mm:ss] Topic Name` with a `**Speakers**:` line, \
        a 3–6 sentence prose paragraph in past tense, and an optional bullet list of facts. \
        You ground every claim in the provided transcript and never invent facts or names. \
        You begin DIRECTLY with the first `## [...]` header — no preamble, no overview, \
        no closing recap.
        """

        guard let textGenerator else {
            Self.logger.info("[Outline] no LLM configured — writing placeholder for \(meetingId, privacy: .public)")
            let placeholder = DetailedOutline(
                meetingId: meetingId,
                text: "_Configure Claude or Ollama in Settings → AI to generate a detailed outline._",
                generatedAt: Date(),
                method: "ai-failed",
                modelUsed: nil
            )
            try? await outlineRepo.save(placeholder)
            return placeholder
        }

        let raw: String
        do {
            raw = try await textGenerator(systemPrompt, userPrompt)
        } catch {
            Self.logger.error("[Outline] LLM call failed for \(meetingId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            // Don't overwrite an existing outline with a failure stub —
            // a stale outline is more useful than an error message.
            if let existing = try? await outlineRepo.outline(meetingId: meetingId), !existing.text.isEmpty {
                return existing
            }
            let stub = DetailedOutline(
                meetingId: meetingId,
                text: "_Outline generation failed (\(error.localizedDescription)). Click Regenerate to retry._",
                generatedAt: Date(),
                method: "ai-failed",
                modelUsed: modelLabel
            )
            try? await outlineRepo.save(stub)
            return stub
        }

        // Light validation: the response MUST start with a `##` heading.
        // Otherwise the model preamble'd despite the prompt rules — strip
        // any leading non-heading content rather than rejecting outright.
        let cleaned = stripLeadingNonHeading(raw)
        guard cleaned.contains("## [") else {
            Self.logger.warning("[Outline] response had no recognizable section headers for \(meetingId, privacy: .public) — saving raw")
            // Save anyway — better the user sees something. method=ai-failed
            // signals the UI / next regen that this wasn't structurally clean.
            let stub = DetailedOutline(
                meetingId: meetingId,
                text: cleaned.isEmpty ? raw : cleaned,
                generatedAt: Date(),
                method: "ai-failed",
                modelUsed: modelLabel
            )
            try? await outlineRepo.save(stub)
            return stub
        }

        let outline = DetailedOutline(
            meetingId: meetingId,
            text: cleaned,
            generatedAt: Date(),
            method: "ai",
            modelUsed: modelLabel
        )
        try? await outlineRepo.save(outline)
        Self.logger.info("[Outline] generated for \(meetingId, privacy: .public) via \(modelLabel, privacy: .public)")
        return outline
    }

    /// Strip leading content before the first `## [` heading. Models
    /// occasionally write "Here is the detailed outline:" or a top-level
    /// `# Meeting Title` line despite the prompt's instruction to begin
    /// directly with a section header. We just delete those.
    nonisolated private func stripLeadingNonHeading(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let firstHeader = trimmed.range(of: "## [") {
            return String(trimmed[firstHeader.lowerBound...])
        }
        return trimmed
    }
}

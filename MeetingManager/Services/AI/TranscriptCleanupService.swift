import Foundation
import os

/// Turns the fragmented per-segment WhisperKit output into a clean, readable
/// transcript. Two-stage pipeline:
///
/// 1. **Stitch** — group consecutive segments from the same speaker when
///    the inter-segment gap is short and the combined text isn't ridiculous.
///    Pure deterministic, runs synchronously, no model needed.
///
/// 2. **AI pass** — single LLM call over the stitched output. Strips fillers
///    ("um", "you know"), adds proper punctuation, fixes obvious hearing
///    errors. Content is preserved — this is *cleanup*, not summarization.
///
/// The stitch always runs. The AI pass is best-effort: if the model fails or
/// no AI is configured, we fall back to the stitched output.
struct TranscriptCleanupService {

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.meetingmanager.app", category: "ai")

    // MARK: - Stitching

    /// Two consecutive segments from the same speaker get merged when the
    /// gap between them is shorter than this. 1.5s is empirically about the
    /// pause length that reads as "same sentence" in conversation.
    private static let maxStitchGapSeconds: TimeInterval = 1.5

    /// Hard cap on a stitched paragraph. Prevents one speaker holding the
    /// floor for a minute from becoming a single 5000-char wall.
    private static let maxStitchedChars = 600

    /// Group consecutive same-speaker segments into stitched turns.
    /// Returns one entry per speaker turn with combined text + bounding
    /// timestamps.
    static func stitch(_ transcripts: [Transcript]) -> [StitchedTurn] {
        var out: [StitchedTurn] = []
        var current: StitchedTurn?
        for t in transcripts {
            let speaker = (t.speakerLabel ?? "").trimmingCharacters(in: .whitespaces)
            let text = t.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }

            if var c = current,
               c.speaker == speaker,
               (t.startTime - c.endTime) <= maxStitchGapSeconds,
               (c.text.count + text.count + 1) <= maxStitchedChars {
                c.text = c.text + " " + text
                c.endTime = t.endTime
                current = c
            } else {
                if let c = current { out.append(c) }
                current = StitchedTurn(
                    speaker: speaker.isEmpty ? "Unknown" : speaker,
                    text: text,
                    startTime: t.startTime,
                    endTime: t.endTime
                )
            }
        }
        if let c = current { out.append(c) }
        return out
    }

    /// Render stitched turns as Markdown — what the UI shows by default.
    static func renderMarkdown(_ turns: [StitchedTurn]) -> String {
        turns.map { turn in
            let ts = formatTimestamp(turn.startTime)
            return "**\(turn.speaker)** _[\(ts)]_\n\n\(turn.text)"
        }.joined(separator: "\n\n")
    }

    private static func formatTimestamp(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    // MARK: - AI cleanup

    /// Run the full cleanup pipeline. Stitch always runs; AI pass runs when
    /// `textGenerator` is provided and succeeds. On AI failure, returns the
    /// stitched-only text with method "ai-failed" so a retry can be triggered.
    ///
    /// - Parameters:
    ///   - transcripts: raw segments in chronological order.
    ///   - textGenerator: optional LLM closure (system, user) -> text. When
    ///     nil, only the stitch runs.
    /// - Returns: (text, method) — text is markdown ready to display.
    static func clean(
        transcripts: [Transcript],
        textGenerator: ((String, String) async throws -> String)?
    ) async -> (text: String, method: String) {
        let turns = stitch(transcripts)
        guard !turns.isEmpty else { return ("", "stitch") }
        let stitchedMarkdown = renderMarkdown(turns)

        // No AI? Stop here.
        guard let textGenerator else {
            logger.info("[TranscriptCleanup] no textGenerator — stitch only (\(turns.count) turn(s))")
            return (stitchedMarkdown, "stitch")
        }

        // Build the AI prompt. Sent the stitched markdown so the model has
        // less work — turns are already grouped; the model just polishes
        // language and removes fillers.
        let systemPrompt = """
            You are a transcript editor. The user provides a raw automatic transcript that has been roughly grouped into speaker turns. Your job is to produce a clean, readable version.

            Rules — apply ALL of these:
            - Preserve every speaker turn. Do not merge turns from different speakers. Do not skip turns.
            - Within a turn, fix punctuation, capitalization, and obvious word-recognition errors when context makes the correction unambiguous.
            - Strip filler words ("um", "uh", "you know", "I mean", "like" when used as a filler) when their removal does not change meaning. Keep them when they ARE the meaning (e.g. "I'm not sure, you know?").
            - Do NOT add content. Do NOT change meaning. Do NOT translate. Do NOT reorder.
            - Preserve the speaker name and the timestamp at the start of each turn exactly as given.
            - Preserve the markdown structure: each turn begins with `**Speaker Name** _[HH:MM]_` followed by a blank line and the cleaned text.
            - Output ONLY the cleaned transcript. No preamble, no explanation, no summary.

            If the input is empty or unintelligible, return it unchanged.
            """

        let userPrompt = """
            Clean up this transcript. Preserve every speaker turn and timestamp; fix punctuation; strip true fillers; never invent content.

            \(stitchedMarkdown)
            """

        do {
            let cleaned = try await textGenerator(systemPrompt, userPrompt)
            let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                logger.warning("[TranscriptCleanup] AI returned empty — falling back to stitch")
                return (stitchedMarkdown, "ai-failed")
            }
            logger.info("[TranscriptCleanup] AI cleanup ok (\(turns.count) turn(s), \(trimmed.count) chars)")
            return (trimmed, "stitch+ai")
        } catch {
            logger.error("[TranscriptCleanup] AI threw: \(error.localizedDescription, privacy: .public) — falling back to stitch")
            return (stitchedMarkdown, "ai-failed")
        }
    }

    // MARK: - Stitched turn

    struct StitchedTurn {
        var speaker: String
        var text: String
        var startTime: TimeInterval
        var endTime: TimeInterval
    }
}

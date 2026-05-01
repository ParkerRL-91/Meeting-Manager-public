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
    /// `textGenerator` is provided and succeeds.
    ///
    /// **Critical: speaker names and timestamps are never sent to the LLM.**
    /// We send only the text body of each turn, get back the cleaned body,
    /// and reassemble the speaker label + timestamp locally from the
    /// deterministic stitch output. This guarantees the AI cannot
    /// hallucinate speaker names — even when a small Ollama model would
    /// otherwise pull a plausible-sounding name from training data or
    /// nearby context. Real-world bug this fixes: a meeting with one
    /// participant rendered with names from the user's KB on the cleaned
    /// rows.
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

        // Send the LLM only the bodies of each turn, separated by sentinel
        // markers. The LLM never sees speaker names or timestamps — those
        // are reattached locally after parsing the response.
        let bodyOnlyInput = turns.enumerated().map { idx, turn in
            "[TURN \(idx + 1)]\n\(turn.text)"
        }.joined(separator: "\n\n")

        let systemPrompt = """
            You are a transcript editor. The input is a list of speaker turns separated by `[TURN N]` markers. For each turn, you produce a cleaned version of that turn's text.

            Rules — apply ALL of them:
            - Output exactly the same number of `[TURN N]` blocks as the input, in the same order.
            - Each output block begins with `[TURN N]` on its own line, followed by the cleaned body on the next line(s).
            - Inside a block, fix punctuation, capitalization, and obvious word-recognition errors when context makes the correction unambiguous.
            - Strip filler words ("um", "uh", "you know", "I mean", "like" when used as a filler) when their removal does not change meaning. Keep them when they ARE the meaning (e.g. "I'm not sure, you know?").
            - Do NOT add content. Do NOT change meaning. Do NOT translate. Do NOT reorder turns.
            - Do NOT add speaker names. Do NOT add timestamps. Do NOT add headings. The `[TURN N]` markers are the ONLY structural elements you produce.
            - Output ONLY the cleaned blocks. No preamble, no explanation, no summary.

            If a turn body is empty or unintelligible, return it unchanged.
            """

        let userPrompt = """
            Clean up the body of each turn below. Output `[TURN N]` followed by the cleaned body, one block per input turn, in order. Never write a name, a timestamp, or a heading.

            \(bodyOnlyInput)
            """

        do {
            let raw = try await textGenerator(systemPrompt, userPrompt)
            let cleanedBodies = parseTurnBodies(raw, expectedCount: turns.count)
            // If parsing failed or the model returned the wrong number of
            // blocks, fall back to stitched-only — strictly safer than
            // shipping a half-cleaned transcript with potentially mismatched
            // turn boundaries.
            guard cleanedBodies.count == turns.count else {
                logger.warning("[TranscriptCleanup] AI returned \(cleanedBodies.count) block(s), expected \(turns.count) — falling back to stitch")
                return (stitchedMarkdown, "ai-failed")
            }
            // Reassemble locally: original speaker + original timestamp +
            // cleaned body. Speaker names are never read from the LLM
            // output. Empty cleaned body falls back to original.
            var cleanedTurns: [StitchedTurn] = []
            for (idx, original) in turns.enumerated() {
                var copy = original
                let body = cleanedBodies[idx].trimmingCharacters(in: .whitespacesAndNewlines)
                copy.text = body.isEmpty ? original.text : body
                cleanedTurns.append(copy)
            }
            let assembled = renderMarkdown(cleanedTurns)
            logger.info("[TranscriptCleanup] AI cleanup ok (\(turns.count) turn(s), \(assembled.count) chars) — speaker labels reassembled locally")
            return (assembled, "stitch+ai")
        } catch {
            logger.error("[TranscriptCleanup] AI threw: \(error.localizedDescription, privacy: .public) — falling back to stitch")
            return (stitchedMarkdown, "ai-failed")
        }
    }

    /// Parse the LLM's `[TURN N]` blocks into an ordered array of cleaned
    /// bodies. Tolerant of small formatting drift — accepts `[TURN N]`,
    /// `Turn N:`, or `Turn N` on a line by itself, and treats everything
    /// between markers as the body. Returns blocks in input order.
    static func parseTurnBodies(_ raw: String, expectedCount: Int) -> [String] {
        let pattern = #"(?im)^\s*\[?\s*turn\s*(\d+)\s*[\]:\.]?\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsRaw = raw as NSString
        let matches = regex.matches(in: raw, range: NSRange(location: 0, length: nsRaw.length))
        guard !matches.isEmpty else { return [] }

        var ordered: [(idx: Int, body: String)] = []
        for (i, match) in matches.enumerated() {
            guard match.numberOfRanges >= 2 else { continue }
            let numRange = match.range(at: 1)
            let num = Int(nsRaw.substring(with: numRange)) ?? -1
            let bodyStart = match.range.location + match.range.length
            let bodyEnd: Int
            if i + 1 < matches.count {
                bodyEnd = matches[i + 1].range.location
            } else {
                bodyEnd = nsRaw.length
            }
            let bodyLength = max(0, bodyEnd - bodyStart)
            let body = nsRaw.substring(with: NSRange(location: bodyStart, length: bodyLength))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            ordered.append((num, body))
        }

        // Sort by input order index just in case the model shuffled them.
        ordered.sort { $0.idx < $1.idx }
        // If the model emitted exactly the expected count and they're 1..N,
        // return in order. Otherwise return what we got — the caller will
        // detect the mismatch and fall back.
        return ordered.map { $0.body }
    }

    // MARK: - Stitched turn

    struct StitchedTurn {
        var speaker: String
        var text: String
        var startTime: TimeInterval
        var endTime: TimeInterval
    }
}

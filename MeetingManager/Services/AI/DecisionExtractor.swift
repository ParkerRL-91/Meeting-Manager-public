import Foundation

/// Post-summary decision extraction (PRJ-017 F1). One schema-constrained call
/// turns a meeting's summary into a list of committed decisions — what was
/// decided, why, and who was involved — for the user-curated Decision Log.
///
/// Distinct from `InsightExtraction`'s "decision" entityFact kind (ADR-028):
/// that fans terse decision facts out to dossiers; this produces richer,
/// editable registry rows (rationale + involved people + a transcript anchor).
/// Pure — the prompt/parse/map logic is unit-testable; the AppState glue does
/// the AI call, BM25 anchoring, and the regen-safe merge.
enum DecisionExtractor {

    /// Grammar-constrains Ollama output; the Claude/Gemini paths ignore it and
    /// rely on the prompt.
    static let schemaJSON = """
    {"type":"array","items":{"type":"object","properties":{"decision":{"type":"string"},"rationale":{"type":["string","null"]},"decidedBy":{"type":["string","null"]},"target":{"type":["string","null"]},"involved":{"type":"array","items":{"type":"string"}},"quote":{"type":["string","null"]}},"required":["decision"]}}
    """

    static let systemPrompt = """
    You extract the concrete decisions made in a meeting. A decision is a \
    committed choice the group settled on ("we will ship Friday", "agreed to \
    drop the Q3 launch") — NOT an option merely discussed, a question left \
    open, or an action item assigned to one person. Return ONLY a JSON array. \
    Each element has: "decision" (a concise statement of WHAT was decided — \
    phrase it as the decision itself, e.g. "Email David for the renewal user \
    numbers", and do NOT embed the decider's name in this sentence: never write \
    "Parker decided to…" or "The team agreed to…"), "rationale" (why it was \
    decided, or null if not stated), "decidedBy" (the single name of the person \
    who made or owns this decision, ONLY when explicit textual evidence names \
    them; null when unclear or collective), "involved" (names of the people who \
    made or endorsed it, drawn only from the text; empty array if unclear), and \
    "target" (who or what the decision is FOR or ABOUT — distinct from who made \
    it: the specific client, candidate, vendor, team, or product the decision \
    applies to. "Finalize the contract by January 15" → the client the contract \
    is with, e.g. "Globex"; "offer a 95k salary" → the candidate receiving the \
    offer. A name or short noun phrase drawn only from the text; null when the \
    text names none), "quote" (a short verbatim excerpt from the transcript \
    where it was decided, or null). Use only names and wording that appear in \
    the material. Return an empty array [] when no decisions were made. No text \
    outside the JSON array.
    """

    struct RawDecision: Decodable {
        let decision: String
        let rationale: String?
        let decidedBy: String?
        let target: String?
        let involved: [String]?
        let quote: String?
    }

    /// Tolerant parse: take the substring from the first "[" to the last "]"
    /// so a fenced or prefixed response still decodes.
    static func parse(_ response: String) -> [RawDecision]? {
        guard let start = response.firstIndex(of: "["),
              let end = response.lastIndex(of: "]") else { return nil }
        let json = String(response[start...end])
        return try? JSONDecoder().decode([RawDecision].self, from: Data(json.utf8))
    }

    /// Map parsed rows to Decision records (pre-anchor). Drops blank titles and
    /// de-dups on the normalized key so one meeting can't carry two rows for
    /// the same decision. Pure.
    static func decisions(from raws: [RawDecision], meetingId: String, now: Date = Date()) -> [Decision] {
        var seen = Set<String>()
        var out: [Decision] = []
        for raw in raws {
            let title = raw.decision.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            let key = Decision.normalize(title)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }

            var decision = Decision(
                id: nil,
                meetingId: meetingId,
                title: title,
                rationale: raw.rationale?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                involved: nil,
                quoteText: raw.quote?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                startTime: nil,
                endTime: nil,
                normalizedKey: key,
                status: Decision.TriageStatus.suggested.rawValue,
                ownerName: raw.decidedBy?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                ownerPersonId: nil,
                targetName: raw.target?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                editedAt: nil,
                dismissedAt: nil,
                extractedAt: now,
                createdAt: now
            )
            decision.setInvolved(raw.involved ?? [])
            out.append(decision)
        }
        return out
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

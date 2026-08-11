import Foundation

/// Practice mode (TASK-067): rehearse against a persona that argues ONLY
/// from positions recorded in your meetings. Pure prompt assembly — the
/// sheet owns its own ephemeral conversation (review m11: never shared
/// with GlobalChat state), and every grounding fact is visible in the UI
/// as a numbered source (same citation discipline as the RAG chat).
enum PracticeMode {

    /// The numbered record the persona may argue from. Objections and
    /// questions lead — they're the positions a rehearsal is for.
    static func numberedRecord(facts: [EntityFact], cap: Int = 30) -> [(index: Int, fact: EntityFact)] {
        let priority = ["objection": 0, "question": 1, "decision": 2, "commitment": 3, "status": 4]
        var seen = Set<String>()
        let ordered = facts
            .filter { seen.insert($0.text).inserted }
            .sorted {
                let pa = priority[$0.kind] ?? 5, pb = priority[$1.kind] ?? 5
                return pa == pb ? $0.extractedAt > $1.extractedAt : pa < pb
            }
        return Array(ordered.prefix(cap)).enumerated().map { ($0 + 1, $1) }
    }

    static func systemPrompt(personaName: String, record: [(index: Int, fact: EntityFact)]) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        // `lines` MUST be pinned to String. GRDB's `SQL` is also
        // ExpressibleByStringInterpolation and ships a
        // `Sequence where Element == SQL` overload of `joined(separator:)`, and
        // GRDB's declarations are visible here even though this file imports only
        // Foundation. `lines` is then only ever used inside a string
        // interpolation, which accepts any type — so with no annotation the
        // literal below inferred as `SQL`, `joined` resolved to GRDB's overload,
        // and the prompt carried `SQL(elements: [...])` debug output in place of
        // the record. The persona was being grounded on nothing.
        let lines: String = record.map { idx, f -> String in
            let owner = f.owner.map { " — \($0)" } ?? ""
            return "[\(idx)] (\(f.kind), \(df.string(from: f.extractedAt))\(owner)) \(f.text)"
        }.joined(separator: "\n")
        return """
        You are role-playing \(personaName) in a PRACTICE conversation so \
        the user can rehearse. Hard rules:
        - Argue ONLY positions, concerns, objections, and questions that \
        appear in the record below. Push back the way the record shows \
        this party pushes back.
        - Cite the record item for each substantive position, like [3].
        - If the user raises something the record does not cover, say so \
        in character and briefly — "I don't have a recorded position on \
        that" — and steer back to recorded ground. NEVER invent facts, \
        prices, dates, commitments, or opinions.
        - Stay concise: 2-5 sentences per reply, conversational tone.
        This is a simulation for rehearsal, not a prediction of what \
        \(personaName) will actually say.

        THE RECORD:
        \(lines)
        """
    }

    /// Multi-turn prompt for a stateless (system, user) generator: the
    /// running conversation transcript with the next user line last.
    static func conversationPrompt(turns: [(role: String, text: String)],
                                   personaName: String,
                                   maxTurns: Int = 12) -> String {
        let recent = turns.suffix(maxTurns).map { turn in
            let speaker = turn.role == "user" ? "User" : personaName
            let text = turn.text.count <= 600 ? turn.text : String(turn.text.prefix(600)) + "…"
            return "\(speaker): \(text)"
        }
        return recent.joined(separator: "\n\n") + "\n\n\(personaName):"
    }
}

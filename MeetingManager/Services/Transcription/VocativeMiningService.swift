import Foundation
import os

/// Hallucination-proof speaker identification by *vocative mining* — scanning
/// the transcript for patterns where one person directly addresses another by
/// name, then matching the addressee to the next non-self speaker turn.
///
/// Why this works: names in the input come *only* from the calendar attendee
/// list. The matcher can't invent names the way an LLM can — it can only
/// observe whether an attendee name was spoken near a cluster transition.
/// Worst case is a missed assignment, never a hallucinated one.
///
/// Patterns recognised:
///   - "Hey <Name>"            (greeting)
///   - "Hi <Name>"             (greeting)
///   - "Thanks <Name>"         (acknowledgement)
///   - "<Name>, "              (vocative comma-prefix)
///   - "what do you think, <Name>"  (trailing vocative)
///   - "Over to you, <Name>"   (handoff)
///
/// Confidence model: a cluster→name pair earns a vote each time the name
/// appears in a vocative position immediately before/around an utterance
/// from that cluster. Multiple votes raise confidence; a single vote is
/// only used when no other signal exists.
///
/// TODO(v3.9): emit confidence scores for the multi-signal aggregator
/// instead of returning a flat dictionary. For now we return only the
/// highest-confidence cluster→name pairs, suitable to merge into the
/// existing prior-aliases dictionary.
enum VocativeMiningService {

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.meetingmanager.app", category: "general")

    /// Run vocative mining over the transcript. Returns cluster id → name
    /// for clusters where at least one strong vocative match was observed.
    /// Already-resolved clusters in `existingMapping` are skipped (we don't
    /// override prior knowledge).
    ///
    /// - Parameters:
    ///   - transcripts: chronological transcript segments
    ///   - attendees: calendar invitee names (full strings — "First Last"
    ///     or "first.last@…"); the matcher extracts first names internally
    ///   - userFirstName: the user's first name (lowercased) — vocatives
    ///     pointing at them resolve to the user's mic cluster, not a
    ///     non-mic cluster
    ///   - existingMapping: clusters already assigned by other signals;
    ///     these are skipped
    /// - Returns: cluster id → resolved name dictionary
    static func attribute(
        transcripts: [Transcript],
        attendees: [String],
        userFirstName: String?,
        existingMapping: [String: String]
    ) -> [String: String] {
        // Build the candidate-name list: first names of every attendee.
        // Stash both the first name (matching key) and the full name
        // (returned value) so the result is a real label, not a fragment.
        let candidates = candidateNames(from: attendees, excluding: userFirstName)
        guard !candidates.isEmpty else { return [:] }

        // Tally votes per cluster id keyed by candidate first name.
        var votes: [String: [String: Int]] = [:] // cluster -> firstName -> count

        // Walk pairs of consecutive utterances: when (current, next) crosses
        // a cluster boundary AND the current utterance ends with a vocative
        // pointing at one of the candidates, the *next* speaker is likely
        // that candidate.
        for (idx, current) in transcripts.enumerated() {
            guard idx + 1 < transcripts.count else { break }
            let next = transcripts[idx + 1]

            let currentCluster = (current.speakerLabel ?? "").trimmingCharacters(in: .whitespaces)
            let nextCluster = (next.speakerLabel ?? "").trimmingCharacters(in: .whitespaces)
            // Only useful when:
            //   - speakers are different (someone is addressing someone else)
            //   - the next cluster is an unresolved Speaker N (not already a name)
            //   - there's no existing mapping for next cluster
            guard currentCluster != nextCluster else { continue }
            guard nextCluster.lowercased().hasPrefix("speaker ") else { continue }
            guard existingMapping[nextCluster] == nil else { continue }

            for (firstLower, _) in candidates {
                if textMentionsVocative(current.text, name: firstLower) {
                    votes[nextCluster, default: [:]][firstLower, default: 0] += 1
                }
            }
        }

        // Pick the highest-vote candidate per cluster; require at least
        // 2 votes for an auto-attribution to avoid one-off coincidences.
        // Single-vote results are kept only when no other candidate ties.
        var result: [String: String] = [:]
        for (cluster, names) in votes {
            let sorted = names.sorted(by: { $0.value > $1.value })
            guard let winner = sorted.first else { continue }
            // Need either ≥2 votes OR be uniquely the highest with no rival
            let confident = winner.value >= 2 || sorted.count == 1
            guard confident else { continue }
            // Resolve back to the full name from candidates.
            if let full = candidates[winner.key] {
                result[cluster] = full
                logger.info("[Vocative] \(cluster, privacy: .public) → \(full, privacy: .public) (votes=\(winner.value))")
            }
        }
        return result
    }

    /// Build a `firstName(lowercased) → fullName` map from calendar
    /// attendees. Skips the user (we never vocative-map onto self) and
    /// drops single-letter / empty first names.
    private static func candidateNames(from attendees: [String], excluding userFirst: String?) -> [String: String] {
        var result: [String: String] = [:]
        for raw in attendees {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let firstName = extractFirstName(from: trimmed)
            let firstLower = firstName.lowercased()
            guard firstLower.count >= 2 else { continue }
            if let uf = userFirst?.lowercased(), firstLower == uf { continue }
            // Don't overwrite if we already have a candidate for this first
            // name — first one wins (deterministic).
            if result[firstLower] == nil {
                result[firstLower] = trimmed
            }
        }
        return result
    }

    /// Build a canonical lowercase first-name key for an attendee string —
    /// used by callers that need to dedup attendee lists across email and
    /// display-name formats. Examples:
    ///   - "dave@acme.com"        → "dave"
    ///   - "Dave Smith"                → "dave"
    ///   - "dave.smith@acme.com"  → "dave"
    ///   - "Dave"                      → "dave"
    static func canonicalKey(for input: String) -> String {
        return extractFirstName(from: input).lowercased()
    }

    /// Strip an email-shaped attendee down to a likely first name. For
    /// `"dana@acme.com"` returns "Dana"; for `"Dana Pace"`
    /// returns "Dana". Uses common separators (`.`, `_`, `-`, space).
    private static func extractFirstName(from input: String) -> String {
        // Email local-part (before @)
        let localPart: String
        if let at = input.firstIndex(of: "@") {
            localPart = String(input[..<at])
        } else {
            localPart = input
        }
        let separators = CharacterSet(charactersIn: ". _-")
        let parts = localPart.components(separatedBy: separators).filter { !$0.isEmpty }
        guard let first = parts.first else { return "" }
        return first.capitalized
    }

    /// Does `text` end with (or contain a clear final-position) vocative
    /// pointing at `name`? Conservative — we'd rather miss an attribution
    /// than make a wrong one. Patterns:
    ///   - "Hey Dana" / "Hi Dana" / "Thanks Dana" anywhere
    ///   - "..., Dana" / "..., Dana?" near end
    ///   - "<Name>?" alone
    static func textMentionsVocative(_ text: String, name firstNameLower: String) -> Bool {
        let lower = text.lowercased()
        // Word-boundary-aware contains: avoid "marie" matching inside
        // "americas" etc. Use spaces + punctuation as boundaries.
        let bounded = " \(lower) "
        let openers = ["hey", "hi", "hello", "thanks", "thank you", "yeah", "okay", "ok"]
        for opener in openers {
            // "hey dana" / "thanks dana" / "ok dana"
            if bounded.contains(" \(opener) \(firstNameLower) ") { return true }
            if bounded.contains(" \(opener) \(firstNameLower),") { return true }
            if bounded.contains(" \(opener) \(firstNameLower)?") { return true }
            if bounded.contains(" \(opener) \(firstNameLower).") { return true }
        }
        // Trailing vocative: "..., dana" or "..., dana?"
        let endingPatterns = [
            ", \(firstNameLower)?",
            ", \(firstNameLower).",
            ", \(firstNameLower) ",
            ", \(firstNameLower)\n",
        ]
        for p in endingPatterns where bounded.contains(p) { return true }
        // Standalone interrogative: "Dana?" — most common as a one-word
        // turn handoff. Only count when the ENTIRE text is the name +
        // optional punctuation.
        let stripped = lower.trimmingCharacters(in: .whitespacesAndNewlines)
        let punctSet = CharacterSet(charactersIn: "?.!,")
        let strippedNoPunct = stripped.trimmingCharacters(in: punctSet)
        if strippedNoPunct == firstNameLower { return true }
        return false
    }
}

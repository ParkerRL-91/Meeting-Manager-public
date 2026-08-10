import Foundation

/// Pure, testable naming logic layered on top of the signal stack in
/// `applySpeakerAttribution`. The design it implements:
///   - margin-guarded constraint propagation (1:1 → N-person elimination),
///   - contradiction flags (name not invited, count mismatch, duplicate name).
///
/// Deliberately conservative: elimination only fires when it's unambiguous
/// (exactly one unassigned cluster AND one remaining candidate), so an
/// uninvited guest or a silent invitee can't trigger a wrong guess. Everything
/// uncertain is left as "Speaker N" and surfaced as a flag instead of guessed.
enum SpeakerNamingEngine {

    /// Confidence assigned to an elimination-derived name (tier 5). Below the
    /// 0.95 of the deterministic 1:1/energy anchors, above the review bar so it
    /// auto-applies but the UI can still show it resolved.
    static let eliminationConfidence: Float = 0.8

    /// Margin-guarded elimination. Repeatedly assigns the lone remaining
    /// candidate to the lone unassigned cluster until neither is unique.
    ///
    /// - Parameters:
    ///   - allClusters: every diarization cluster id in the meeting ("Speaker N").
    ///   - candidates: accepted attendees EXCLUDING the local user, normalized
    ///     (bots/rooms filtered, identity-deduped) by the caller.
    ///   - assigned: clusters already mapped by stronger signals (voice, vocative,
    ///     LLM, enrollment, the energy "you" anchor) → resolved name.
    /// - Returns: newly-eliminated assignments cluster → (name, confidence).
    static func eliminate(
        allClusters: Set<String>,
        candidates: [String],
        assigned: [String: String]
    ) -> [String: (name: String, confidence: Float)] {
        var working = assigned
        var result: [String: (name: String, confidence: Float)] = [:]

        func remainingCandidates() -> [String] {
            let used = Set(working.values.map { $0.lowercased() })
            return candidates.filter { c in
                let cl = c.lowercased()
                // A candidate is "used" if any assigned name fuzzy-matches it.
                return !used.contains { $0.contains(cl) || cl.contains($0) }
            }
        }
        func unassignedClusters() -> [String] {
            allClusters.filter { working[$0] == nil }.sorted()
        }

        var changed = true
        while changed {
            changed = false
            let u = unassignedClusters()
            let r = remainingCandidates()
            guard u.count == 1, r.count == 1 else { break }
            working[u[0]] = r[0]
            result[u[0]] = (r[0], eliminationConfidence)
            changed = true
        }
        return result
    }

    // MARK: - Contradiction flags

    enum FlagKind: String, Codable, Sendable {
        case nameNotInvited      // a resolved name isn't on the invite list
        case moreVoicesThanInvited
        case duplicateName       // same name on >1 cluster (over-split)
        case unexpectedSpeaker   // unassigned cluster but candidates remain (someone unrecognized)
        case voiceMatchAdvisory  // name rests only on uncorroborated cross-meeting voice (~57% precise)
    }

    // MARK: - P5: candidate hygiene

    /// Bot / notetaker / room / distribution-list patterns that are "attendees"
    /// but never have a voice cluster. Leaving them in the candidate pool
    /// corrupts elimination (a phantom candidate). Matched case-insensitively
    /// against the attendee string (name or email).
    private static let nonPersonPatterns: [String] = [
        "otter.ai", "fireflies", "read.ai", "fathom", "avoma", "tldv", "tl;dv",
        "notetaker", "note taker", "notes bot", "meeting bot", "recording bot",
        "transcription", "zoom room", "meet room", "teams room", "boardroom",
        "conference room", "(room)", "resource", "no-reply", "noreply", "calendar",
    ]

    /// Clean the accepted-attendee list before attribution/elimination:
    /// drop bots/notetakers/rooms, drop unenumerable distribution lists, trim,
    /// and dedupe near-identical entries (same person as name and email).
    /// Conservative — only clear non-person patterns are removed.
    static func cleanCandidates(_ raw: [String]) -> [String] {
        var seen: [String] = []
        for a in raw {
            let trimmed = a.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let lower = trimmed.lowercased()
            // Drop bots / rooms / resources.
            if nonPersonPatterns.contains(where: { lower.contains($0) }) { continue }
            // Drop obvious distribution lists (team@, all@, group aliases).
            if let at = lower.firstIndex(of: "@") {
                let localPart = String(lower[lower.startIndex..<at])
                let listy: Set<String> = ["team", "all", "everyone", "staff", "group", "dl", "list", "announce", "info", "sales", "support"]
                if listy.contains(localPart) { continue }
            }
            // Dedupe: skip only when an already-kept entry is provably the
            // same person — the identical string, or an email form sharing
            // the same first token ("Dave Smith" / "dave@x.com"). Two plain
            // NAMES are never merged: "Sam" and "Sam Smith" can be distinct
            // attendees, and collapsing them hands elimination a wrong
            // roster. Keeping both is the safe direction — elimination then
            // requires both to be consumed before it auto-assigns.
            func firstToken(_ s: String) -> String {
                s.split(whereSeparator: { $0 == " " || $0 == "@" || $0 == "." || $0 == "<" })
                    .first.map(String.init) ?? s
            }
            if seen.contains(where: { kept in
                let kl = kept.lowercased()
                if kl == lower { return true }
                let oneIsEmail = kl.contains("@") || lower.contains("@")
                return oneIsEmail && firstToken(kl) == firstToken(lower)
            }) { continue }
            seen.append(trimmed)
        }
        return seen
    }

    struct Flag: Codable, Sendable, Equatable {
        let kind: FlagKind
        let reason: String
    }

    /// Compute review flags for a finalized mapping. `acceptedCandidates`
    /// includes the local user; `userNames` are the local user's name variants
    /// (so we don't flag the user as "not invited" when they're not on an
    /// externally-organized invite).
    static func flags(
        finalMapping: [String: String],
        allClusters: Set<String>,
        acceptedCandidates: [String],
        userNames: [String]
    ) -> [Flag] {
        var out: [Flag] = []
        let inviteLower = acceptedCandidates.map { $0.lowercased() }
        let userLower = userNames.map { $0.lowercased() }.filter { !$0.isEmpty }

        func isUser(_ nl: String) -> Bool { userLower.contains { $0.contains(nl) || nl.contains($0) } }
        func onInvite(_ nl: String) -> Bool { inviteLower.contains { $0.contains(nl) || nl.contains($0) } }

        // 1) resolved name not on the invite list (and not the user).
        for name in Set(finalMapping.values) {
            let nl = name.lowercased()
            if !isUser(nl) && !onInvite(nl) {
                out.append(Flag(kind: .nameNotInvited,
                                reason: "“\(name)” was matched but isn’t on this meeting’s invite list — please confirm."))
            }
        }

        // 2) same name on more than one cluster (diarization over-split a person).
        var nameToClusters: [String: [String]] = [:]
        for (cluster, name) in finalMapping { nameToClusters[name.lowercased(), default: []].append(cluster) }
        for (_, clusters) in nameToClusters where clusters.count > 1 {
            let display = finalMapping[clusters[0]] ?? clusters[0]
            out.append(Flag(kind: .duplicateName,
                            reason: "“\(display)” is split across \(clusters.count) speakers — they may be the same person."))
        }

        // 3) more distinct voices than invited people.
        if allClusters.count > acceptedCandidates.count, acceptedCandidates.count > 0 {
            out.append(Flag(kind: .moreVoicesThanInvited,
                            reason: "\(allClusters.count) distinct voices but \(acceptedCandidates.count) invited — an unlisted speaker may be present."))
        }

        // 4) an unassigned cluster while named candidates remain unused → unrecognized speaker.
        let assignedNames = Set(finalMapping.values.map { $0.lowercased() })
        let unusedCandidates = inviteLower.filter { c in !assignedNames.contains { $0.contains(c) || c.contains($0) } && !isUser(c) }
        let unassigned = allClusters.filter { finalMapping[$0] == nil }
        if !unassigned.isEmpty && unusedCandidates.isEmpty && acceptedCandidates.count > 0 {
            out.append(Flag(kind: .unexpectedSpeaker,
                            reason: "\(unassigned.count) speaker(s) couldn’t be matched to any invitee."))
        }

        return out
    }
}

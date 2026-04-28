import Foundation

extension Transcript {
    /// Display-friendly speaker name. Resolves the raw `speakerLabel` against
    /// the meeting context and current user identity:
    /// - "mic" → user's first name (or "You" if unknown)
    /// - "system" → "Them" (single-other-participant) or "Other"
    /// - Anything else (e.g. "Speaker 1", a real name) → passed through
    ///
    /// This is a v3.1 Layer 1 display-time rename — no DB writes. Layer 2 will
    /// replace "Speaker N" with real names from the participant list via LLM
    /// attribution.
    func displayedSpeakerName(
        meeting: Meeting?,
        userDisplayName: String?
    ) -> String {
        let raw = (speakerLabel ?? "").trimmingCharacters(in: .whitespaces)
        switch raw.lowercased() {
        case "mic":
            return Self.firstName(from: userDisplayName) ?? "You"
        case "system":
            // If the meeting has exactly one other participant, "Them" implies
            // them specifically. Otherwise prefer the more neutral "Other".
            let otherCount = (meeting?.participantList.count ?? 0)
            return otherCount == 1 ? "Them" : "Other"
        case "":
            return "Speaker"
        default:
            return raw
        }
    }

    /// Extract the first whitespace-delimited token of a display name. Returns
    /// nil if the input is empty/nil after trimming.
    static func firstName(from displayName: String?) -> String? {
        guard let n = displayName?.trimmingCharacters(in: .whitespaces),
              !n.isEmpty else { return nil }
        return n.components(separatedBy: .whitespaces).first
    }
}

import Foundation
import GRDB

// MARK: - Decision (PRJ-017 F1, migration v67)

/// One decision made in a meeting: what was decided, why, who was involved,
/// and a transcript anchor (time range + verbatim quote snapshot). Unlike the
/// entityFact "decision" kind (which fans facts out to People/Company/Series
/// dossiers), this is a user-curated registry — decisions can be edited and
/// dismissed, and those human edits survive re-extraction (see
/// `DecisionRepository.mergeForMeeting`). The quote is a SNAPSHOT (honest even
/// after audio prune or re-transcription); the time range is the playback
/// anchor (`AudioPlaybackService.playRange`), nil when anchoring found no match.
struct Decision: Codable, FetchableRecord, MutablePersistableRecord, Identifiable {
    static let databaseTableName = "decision"

    var id: Int64?
    var meetingId: String
    var title: String
    var rationale: String?
    /// JSON array of names; use `involvedNames` / `setInvolved` to read/write.
    var involved: String?
    var quoteText: String?
    var startTime: Double?
    var endTime: Double?
    var normalizedKey: String
    /// One of `TriageStatus`: "suggested" (in the review inbox), "active"
    /// (confirmed), or "dismissed" (not a decision).
    var status: String
    /// Display name of who decided/owns the decision, or nil. Extraction fills
    /// this from the model's `decidedBy` field; a correction sets it via
    /// `setOwner` (which also stamps `editedAt`).
    var ownerName: String?
    /// Resolved `Person.id` for the owner, or nil (unknown / ambiguous). Never
    /// resolved in the repository — People matching lives in the AppState glue.
    var ownerPersonId: String?
    /// Who or what the decision is FOR — distinct from who made it: the client
    /// whose contract gets finalized, the candidate receiving the offer, the
    /// vendor, team, or product it applies to (TASK-137, v74). A name or short
    /// noun phrase from the text; nil when none is named.
    var targetName: String?
    var editedAt: Date?
    var dismissedAt: Date?
    var extractedAt: Date
    var createdAt: Date

    enum Columns {
        static let meetingId = Column(CodingKeys.meetingId)
        static let normalizedKey = Column(CodingKeys.normalizedKey)
        static let status = Column(CodingKeys.status)
        static let ownerName = Column(CodingKeys.ownerName)
        static let ownerPersonId = Column(CodingKeys.ownerPersonId)
        static let editedAt = Column(CodingKeys.editedAt)
        static let dismissedAt = Column(CodingKeys.dismissedAt)
        static let extractedAt = Column(CodingKeys.extractedAt)
        static let createdAt = Column(CodingKeys.createdAt)
    }

    /// The triage lifecycle of a decision (PRJ-020 / TASK-128). Extractions land
    /// as `.suggested` (an inbox); the user confirms them into `.active` or
    /// rejects them into `.dismissed`. Confirmed decisions flow outward to the
    /// weekly digest, KB export, prep, etc.; suggestions stay in the inbox.
    enum TriageStatus: String, CaseIterable {
        case suggested
        case active
        case dismissed
    }

    var triageStatus: TriageStatus { TriageStatus(rawValue: status) ?? .active }
    var isSuggested: Bool { triageStatus == .suggested }
    var isConfirmed: Bool { triageStatus == .active }

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    var isDismissed: Bool { dismissedAt != nil || status == "dismissed" }

    /// True once a human has vouched for the row — edited, dismissed, or moved
    /// it out of the suggested inbox (confirmed). Re-extraction must not
    /// overwrite it. The `status != "suggested"` clause is the single shield
    /// covering BOTH merge branches: an update-in-place would otherwise demote a
    /// confirmed row back to suggested and clobber its title/owner, and the
    /// stale-delete would otherwise DELETE a confirmed row whose key vanished.
    var isUserTouched: Bool { editedAt != nil || dismissedAt != nil || status != "suggested" }

    var hasAnchor: Bool { startTime != nil }

    /// `MM:SS` / `H:MM:SS` for the decision's transcript moment, or nil.
    var timestampLabel: String? {
        guard let start = startTime else { return nil }
        let total = max(0, Int(start))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    var involvedNames: [String] {
        guard let involved, let data = involved.data(using: .utf8),
              let names = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return names
    }

    mutating func setInvolved(_ names: [String]) {
        let cleaned = names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty,
              let data = try? JSONEncoder().encode(cleaned),
              let json = String(data: data, encoding: .utf8) else {
            involved = nil
            return
        }
        involved = json
    }

    /// True when this decision belongs to `person` — either the resolved owner
    /// Person id matches, or the owner/involved names match the person's
    /// canonical keys (aliases included, via `Person.matches`). Raw canonicalName
    /// comparison would miss "Dave" vs "David Smith"; this is the codebase's
    /// actual identity rule. Drives the person-page Decision Log (TASK-129).
    func belongsTo(person: Person) -> Bool {
        if let pid = ownerPersonId, pid == person.id { return true }
        if let owner = ownerName, person.matches(participant: owner) { return true }
        // The target is usually a company or product, but when it IS a person
        // (a candidate, a report), their page should carry the decision too.
        if let target = targetName, person.matches(participant: target) { return true }
        return involvedNames.contains { person.matches(participant: $0) }
    }

    /// Lowercased, punctuation-stripped, whitespace-collapsed title — the
    /// dedup key within a meeting. Deterministic so re-extraction of the same
    /// decision maps to the same row.
    static func normalize(_ title: String) -> String {
        let lowered = title.lowercased()
        let stripped = lowered.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(stripped).split(separator: " ").joined(separator: " ")
    }
}

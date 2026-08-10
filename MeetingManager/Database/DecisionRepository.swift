import Foundation
import GRDB

/// Persistence for the Decision Log (PRJ-017 F1). The distinguishing behavior
/// is `mergeForMeeting`: unlike `EntityFactRepository.replaceForMeeting` (blind
/// delete + insert), a re-extraction here preserves any decision a human has
/// edited or dismissed, so regenerating a summary never clobbers curation.
final class DecisionRepository {
    private let database: AppDatabase
    init(database: AppDatabase) { self.database = database }

    // MARK: Reads

    func decisionsForMeeting(_ meetingId: String, includeDismissed: Bool = false) async throws -> [Decision] {
        try await database.writer.read { db in
            var request = Decision.filter(Decision.Columns.meetingId == meetingId)
            if !includeDismissed {
                request = request.filter(Decision.Columns.dismissedAt == nil)
            }
            // Anchored decisions in transcript order; unanchored last
            // (portable NULLS-LAST: the boolean sorts non-null before null).
            return try request.order(sql: "startTime IS NULL, startTime ASC, createdAt ASC").fetchAll(db)
        }
    }

    /// `confirmedOnly` (default true) restricts to confirmed ("active") rows —
    /// the outward-facing default so suggestions never leak into the weekly
    /// digest, KB export, etc. The singular `decisionsForMeeting` intentionally
    /// has NO such default (the meeting detail shows suggested rows for triage).
    func decisionsForMeetings(_ meetingIds: [String], includeDismissed: Bool = false,
                              confirmedOnly: Bool = true,
                              limit: Int = 200) async throws -> [Decision] {
        guard !meetingIds.isEmpty else { return [] }
        return try await database.writer.read { db in
            var request = Decision.filter(meetingIds.contains(Decision.Columns.meetingId))
            if confirmedOnly {
                request = request.filter(Decision.Columns.status == Decision.TriageStatus.active.rawValue)
            } else if !includeDismissed {
                request = request.filter(Decision.Columns.dismissedAt == nil)
            }
            return try request.order(Decision.Columns.extractedAt.desc).limit(limit).fetchAll(db)
        }
    }

    /// Rows in a given triage state, newest-first — the per-tab feed for
    /// `DecisionBrowserView` (Inbox / Confirmed / Dismissed).
    func decisions(status: Decision.TriageStatus, limit: Int = 500) async throws -> [Decision] {
        try await database.writer.read { db in
            try Decision.filter(Decision.Columns.status == status.rawValue)
                .order(Decision.Columns.extractedAt.desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// Count of decisions awaiting triage — drives the sidebar badge and the
    /// browser's default-tab choice.
    func suggestedCount() async throws -> Int {
        try await database.writer.read { db in
            try Decision.filter(Decision.Columns.status == Decision.TriageStatus.suggested.rawValue)
                .fetchCount(db)
        }
    }

    /// The global browser feed — visible decisions newest-first, filtered
    /// in-memory in the view (matching KeyQuotesView).
    func allDecisions(limit: Int = 500) async throws -> [Decision] {
        try await database.writer.read { db in
            try Decision.filter(Decision.Columns.dismissedAt == nil)
                .order(Decision.Columns.extractedAt.desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    // MARK: Regen-safe merge

    /// Reconcile freshly extracted decisions against what's stored for a
    /// meeting, in one write transaction:
    ///   - matched key + user-touched  → keep the user's row (backfill a
    ///     missing anchor from the fresh extraction)
    ///   - matched key + untouched     → update fields in place
    ///   - unmatched extracted         → insert
    ///   - existing, unmatched, untouched → delete (prior-run AI noise)
    /// Edited/dismissed rows always survive. `extracted` rows are expected to
    /// carry a computed `normalizedKey`.
    func mergeForMeeting(_ meetingId: String, extracted: [Decision]) async throws {
        try await database.writer.write { db in
            let existing = try Decision.filter(Decision.Columns.meetingId == meetingId).fetchAll(db)
            var existingByKey: [String: Decision] = [:]
            for row in existing { existingByKey[row.normalizedKey] = row }

            var seenKeys = Set<String>()
            for var fresh in extracted {
                let key = fresh.normalizedKey
                guard !key.isEmpty, seenKeys.insert(key).inserted else { continue }

                if var prior = existingByKey[key] {
                    if prior.isUserTouched {
                        // Preserve curation; only backfill a missing anchor and
                        // an owner name the confirmed row never had.
                        var dirty = false
                        if prior.startTime == nil, fresh.startTime != nil {
                            prior.startTime = fresh.startTime
                            prior.endTime = fresh.endTime
                            if prior.quoteText == nil { prior.quoteText = fresh.quoteText }
                            dirty = true
                        }
                        if prior.ownerName == nil, fresh.ownerName != nil {
                            prior.ownerName = fresh.ownerName
                            // The glue already resolved the Person link — carry
                            // it too, or person-page matching falls back to
                            // name-key matching forever on this row.
                            prior.ownerPersonId = fresh.ownerPersonId
                            dirty = true
                        }
                        if prior.targetName == nil, fresh.targetName != nil {
                            prior.targetName = fresh.targetName
                            dirty = true
                        }
                        if dirty { try prior.update(db) }
                    } else {
                        // Refresh AI fields in place; keep identity + createdAt.
                        fresh.id = prior.id
                        fresh.createdAt = prior.createdAt
                        try fresh.update(db)
                    }
                } else {
                    try fresh.insert(db)
                }
            }

            // Drop stale, untouched rows the fresh pass didn't reproduce.
            for row in existing where !seenKeys.contains(row.normalizedKey) && !row.isUserTouched {
                if let id = row.id { try Decision.deleteOne(db, key: id) }
            }
        }
        // The badge's most important trigger: extraction landing new
        // suggestions. Without this the badge would stay frozen until relaunch.
        // userMutation:false — extraction must NOT trigger a KB re-export of a
        // still-suggested-only meeting (TASK-129 loop gate).
        announceChange(meetingId: meetingId, userMutation: false)
    }

    // MARK: Mutations

    @discardableResult
    func update(_ decision: Decision) async throws -> Decision {
        var copy = decision
        copy.editedAt = Date()
        let saved = try await database.writer.write { db in try copy.saved(db) }
        announceChange(meetingId: saved.meetingId, userMutation: true)
        return saved
    }

    /// Move a suggestion into the confirmed set. Clears any dismissal so a
    /// restored-then-confirmed row is coherent.
    func confirm(id: Int64) async throws {
        let mid = try await database.writer.write { db -> String? in
            try db.execute(
                sql: "UPDATE decision SET status = ?, dismissedAt = NULL WHERE id = ?",
                arguments: [Decision.TriageStatus.active.rawValue, id])
            return try String.fetchOne(db, sql: "SELECT meetingId FROM decision WHERE id = ?", arguments: [id])
        }
        announceChange(meetingId: mid, userMutation: true)
    }

    /// Return a decision to the review inbox (from Confirmed or Dismissed).
    /// Mirrors `TaskRepository.restoreToInbox`; clears any dismissal.
    func restoreToInbox(id: Int64) async throws {
        let mid = try await database.writer.write { db -> String? in
            try db.execute(
                sql: "UPDATE decision SET status = ?, dismissedAt = NULL WHERE id = ?",
                arguments: [Decision.TriageStatus.suggested.rawValue, id])
            return try String.fetchOne(db, sql: "SELECT meetingId FROM decision WHERE id = ?", arguments: [id])
        }
        announceChange(meetingId: mid, userMutation: true)
    }

    /// Correct who owns a decision. Stamps `editedAt` — an owner correction is
    /// an edit, so a corrected-but-not-yet-confirmed suggestion is shielded
    /// from the next re-extraction (the headline mis-attribution use case).
    func setOwner(id: Int64, name: String?, personId: String?) async throws {
        let mid = try await database.writer.write { db -> String? in
            try db.execute(
                sql: "UPDATE decision SET ownerName = ?, ownerPersonId = ?, editedAt = ? WHERE id = ?",
                arguments: [name, personId, Date(), id])
            return try String.fetchOne(db, sql: "SELECT meetingId FROM decision WHERE id = ?", arguments: [id])
        }
        announceChange(meetingId: mid, userMutation: true)
    }

    func setDismissed(id: Int64, _ dismissed: Bool) async throws {
        let mid = try await database.writer.write { db -> String? in
            // Un-dismissing returns the row to the inbox (not silently to
            // "active" — under triage semantics that would auto-confirm it).
            try db.execute(
                sql: "UPDATE decision SET dismissedAt = ?, status = ? WHERE id = ?",
                arguments: [dismissed ? Date() : nil,
                            dismissed ? Decision.TriageStatus.dismissed.rawValue
                                      : Decision.TriageStatus.suggested.rawValue,
                            id])
            return try String.fetchOne(db, sql: "SELECT meetingId FROM decision WHERE id = ?", arguments: [id])
        }
        announceChange(meetingId: mid, userMutation: true)
    }

    func delete(id: Int64) async throws {
        let mid = try await database.writer.write { db -> String? in
            let existing = try String.fetchOne(db, sql: "SELECT meetingId FROM decision WHERE id = ?", arguments: [id])
            try Decision.deleteOne(db, key: id)
            return existing
        }
        announceChange(meetingId: mid, userMutation: true)
    }

    func deleteForMeeting(_ meetingId: String) async throws {
        try await database.writer.write { db in
            try db.execute(sql: "DELETE FROM decision WHERE meetingId = ?", arguments: [meetingId])
        }
        announceChange(meetingId: meetingId, userMutation: true)
    }

    /// Announce that decision data changed so observers (AppState → the sidebar
    /// badge count and open views) can refresh. Mirrors
    /// `TaskRepository.announceChange`; decoupled via NotificationCenter so the
    /// repository stays UI-agnostic.
    ///
    /// `userInfo` carries `meetingId` (which meeting's note to re-export) and
    /// `userMutation` (true for confirm/edit/setOwner/dismiss/restore/delete;
    /// false only for `mergeForMeeting`). The KB re-export observer fires ONLY
    /// on user mutations, so an extraction landing still-suggested rows never
    /// triggers a note rewrite (TASK-129 loop gate).
    private func announceChange(meetingId: String? = nil, userMutation: Bool = true) {
        var info: [AnyHashable: Any] = ["userMutation": userMutation]
        if let meetingId { info["meetingId"] = meetingId }
        NotificationCenter.default.post(name: .decisionDataDidChange, object: nil, userInfo: info)
    }
}

extension Notification.Name {
    /// Posted by `DecisionRepository` after any decision mutation — including
    /// `mergeForMeeting` (fresh extractions). AppState observes it to refresh
    /// the suggested-decision badge count (PRJ-020 / TASK-128).
    static let decisionDataDidChange = Notification.Name("decisionDataDidChange")
}

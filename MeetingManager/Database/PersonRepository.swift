import Foundation
import GRDB
import os

/// Persistence for Person identity records. The primary operations are
/// find-or-create (keyed by canonical first name) and alias merging, which
/// keeps the person table tidy as new name/email formats appear for the
/// same human across meetings.
final class PersonRepository {
    private let database: AppDatabase
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.meetingmanager.app",
        category: "PersonRepository"
    )

    init(database: AppDatabase) {
        self.database = database
    }

    // MARK: - Read

    func allPersons() async throws -> [Person] {
        try await database.writer.read { db in
            try Person.fetchAll(db)
        }
    }

    /// Find a Person whose canonical keys include the canonical key of `rawInput`.
    /// e.g. passing "dave@acme.com" finds a Person that has "dave" in its keys.
    func find(for rawInput: String) async throws -> Person? {
        let key = VocativeMiningService.canonicalKey(for: rawInput)
        guard !key.isEmpty else { return nil }
        let all = try await allPersons()
        return all.first { $0.canonicalKeys.contains(key) }
    }

    // MARK: - Write

    /// Find an existing Person matching `rawName` or create a new one.
    /// If found, merges `rawName` into the Person's aliases if not already present.
    /// Returns the (possibly updated) Person.
    @discardableResult
    func findOrCreate(for rawName: String) async throws -> Person {
        guard !rawName.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw PersonRepositoryError.emptyName
        }
        let key = VocativeMiningService.canonicalKey(for: rawName)
        let all = try await allPersons()

        // Domain disambiguation: if rawName is an email, find ALL persons that
        // share the same canonical key (first name) and pick the one whose domain
        // matches. If no domain match exists, create a new person rather than
        // collapsing two different "Dave"s from different organisations.
        let candidates = all.filter { $0.canonicalKeys.contains(key) }
        if !candidates.isEmpty {
            let incomingDomain = rawName.contains("@")
                ? rawName.components(separatedBy: "@").last?.lowercased()
                : nil

            let match: Person?
            if let domain = incomingDomain {
                // Prefer a candidate whose existing aliases share the same domain
                match = candidates.first(where: { $0.domain == domain })
                    ?? (candidates.count == 1 ? candidates.first : nil)
                // If multiple domain-mismatched Daves exist and we can't tell
                // which — don't merge; fall through to create a new person.
            } else {
                // No domain info — merge into the first matching candidate
                match = candidates.first
            }

            if var existing = match {
                var currentAliases = existing.aliases
                if !currentAliases.contains(rawName) {
                    currentAliases.append(rawName)
                    existing.setAliases(currentAliases)
                    existing.updatedAt = Date()
                    try await database.writer.write { db in try existing.update(db) }
                    logger.debug("[Person] merged alias '\(rawName, privacy: .public)' into '\(existing.canonicalName, privacy: .public)'")
                }
                return existing
            }
            // No domain-safe match found — fall through to create a new person
            logger.info("[Person] domain disambiguation: creating separate record for '\(rawName, privacy: .public)'")
        }

        // Create new person; prefer a display-name format for canonical name
        let canonicalName = preferDisplayName(rawName)
        var person = Person.make(canonicalName: canonicalName, aliases: [rawName])
        try await database.writer.write { db in
            try person.insert(db)
        }
        logger.info("[Person] created '\(canonicalName, privacy: .public)' from '\(rawName, privacy: .public)'")
        return person
    }

    /// Add an alias to an existing Person by id. No-ops if alias already present.
    func addAlias(_ alias: String, toPersonId personId: String) async throws {
        guard !alias.isEmpty else { return }
        try await database.writer.write { db in
            guard var person = try Person.fetchOne(db, key: personId) else { return }
            var current = person.aliases
            guard !current.contains(alias) else { return }
            current.append(alias)
            person.setAliases(current)
            person.updatedAt = Date()
            try person.update(db)
        }
    }

    /// Merge `sourceId` into `targetId`: move all of source's aliases onto target,
    /// then delete source. VoiceProfile rows linked to source are re-pointed to target.
    func merge(sourceId: String, intoTargetId targetId: String) async throws {
        try await database.writer.write { db in
            guard var target = try Person.fetchOne(db, key: targetId),
                  let source = try Person.fetchOne(db, key: sourceId)
            else { return }

            var combined = target.aliases
            for alias in source.aliases where !combined.contains(alias) {
                combined.append(alias)
            }
            target.setAliases(combined)
            target.updatedAt = Date()
            try target.update(db)

            // Re-point any VoiceProfile rows linked to source
            try db.execute(
                sql: "UPDATE voiceProfile SET personId = ? WHERE personId = ?",
                arguments: [targetId, sourceId]
            )

            try db.execute(
                sql: "DELETE FROM person WHERE id = ?",
                arguments: [sourceId]
            )
        }
        logger.info("[Person] merged \(sourceId, privacy: .public) → \(targetId, privacy: .public)")
    }

    // MARK: - Bootstrap

    /// Scan all meeting participants in the database and create Person records
    /// for any that don't exist yet. Safe to call repeatedly — existing persons
    /// are only updated (aliases merged), never duplicated.
    ///
    /// Returns the count of Person rows created.
    func bootstrapFromMeetingHistory(db sharedDb: AppDatabase) async -> Int {
        do {
            let meetings = try await sharedDb.writer.read { db in
                try Row.fetchAll(db, sql: "SELECT participants FROM meeting WHERE participants IS NOT NULL AND participants != ''")
            }

            var rawNames = Set<String>()
            for row in meetings {
                let csv: String = row["participants"] ?? ""
                for part in csv.components(separatedBy: ", ") {
                    let trimmed = part.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { rawNames.insert(trimmed) }
                }
            }

            var created = 0
            for rawName in rawNames {
                let before = try await allPersons()
                let key = VocativeMiningService.canonicalKey(for: rawName)
                if !key.isEmpty && !before.contains(where: { $0.canonicalKeys.contains(key) }) {
                    _ = try await findOrCreate(for: rawName)
                    created += 1
                }
            }
            logger.info("[Person] bootstrap: scanned \(rawNames.count) names, created \(created) new persons")
            return created
        } catch {
            logger.error("[Person] bootstrap failed: \(error, privacy: .public)")
            return 0
        }
    }

    // MARK: - Helpers

    /// Prefer a `First Last` style string over an email address when both
    /// are plausible candidates for the canonical name.
    private func preferDisplayName(_ raw: String) -> String {
        if raw.contains("@") {
            // It's an email — extract first name as capitalized string
            let first = VocativeMiningService.canonicalKey(for: raw)
            return first.isEmpty ? raw : first.capitalized
        }
        return raw
    }
}

// MARK: - Errors

enum PersonRepositoryError: Error {
    case emptyName
}

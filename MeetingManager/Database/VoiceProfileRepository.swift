import Foundation
import GRDB
import os

/// Persistence for per-person voice fingerprints. Profiles are keyed by
/// canonical person name. Upsert semantics: writing a new embedding for a
/// known name merges it via exponential moving average rather than replacing.
///
/// When a PersonRepository is provided, the repository also looks up (or
/// creates) the corresponding Person record and stamps the personId FK onto
/// the VoiceProfile row. This enables future lookups by stable identity
/// regardless of how the person's name is spelled.
final class VoiceProfileRepository {
    private let database: AppDatabase

    init(database: AppDatabase) {
        self.database = database
    }

    // MARK: - Read

    func allProfiles() async throws -> [VoiceProfile] {
        try await database.writer.read { db in
            try VoiceProfile.fetchAll(db)
        }
    }

    func profile(for personName: String) async throws -> VoiceProfile? {
        try await database.writer.read { db in
            try VoiceProfile
                .filter(VoiceProfile.Columns.personName == personName)
                .fetchOne(db)
        }
    }

    /// Look up a profile by Person id. Returns the profile whose personId matches,
    /// or falls back to a name-keyed lookup so existing profiles without a linked
    /// Person are still found.
    func profile(forPersonId personId: String, fallbackName: String) async throws -> VoiceProfile? {
        try await database.writer.read { db in
            if let byId = try VoiceProfile
                .filter(VoiceProfile.Columns.personId == personId)
                .fetchOne(db) {
                return byId
            }
            return try VoiceProfile
                .filter(VoiceProfile.Columns.personName == fallbackName)
                .fetchOne(db)
        }
    }

    /// Returns all profiles with personName resolved to the Person's current
    /// canonicalName. Profiles without a Person link are returned unchanged.
    /// Used by the matching flow so attributed speaker labels always reflect
    /// the best-known display name, not the name string from when the profile
    /// was first created.
    func allProfilesResolved(personRepo: PersonRepository) async throws -> [VoiceProfile] {
        let profiles = try await allProfiles()
        let persons = try await personRepo.allPersons()
        let personById = Dictionary(uniqueKeysWithValues: persons.map { ($0.id, $0) })
        return profiles.map { profile in
            guard let pid = profile.personId,
                  let person = personById[pid],
                  person.canonicalName != profile.personName
            else { return profile }
            var resolved = profile
            resolved.personName = person.canonicalName
            return resolved
        }
    }

    // MARK: - Write

    /// Source of evidence for a new embedding. Used by `merge` to weight the
    /// EMA blend (manual confirmations learn aggressively, LLM attributions
    /// contribute cautiously) and to populate the source-quality counters.
    enum EmbeddingSource: String {
        /// User explicitly renamed a Speaker N to a real name in the UI.
        /// Highest trust — α 0.40, increments manualSampleCount.
        case manual
        /// Stored fingerprint matched this cluster via cosine similarity above
        /// threshold. High trust because it's audio-grounded — α 0.25,
        /// increments manualSampleCount (it confirmed an existing identity).
        case voiceMatch
        /// LLM attributed this cluster to an attendee name via prompt. Low
        /// trust — α 0.10, increments llmSampleCount. Profiles built only
        /// from LLM samples are matched at the stricter 0.87 threshold.
        case llm

        var alpha: Float {
            switch self {
            case .manual:     return 0.40
            case .voiceMatch: return 0.25
            case .llm:        return 0.10
            }
        }
    }

    /// Merge a new embedding into the stored profile using an exponential
    /// moving average so more-recent meetings gradually dominate older ones.
    /// The blend weight (α) and the source-quality counters depend on
    /// `source`, so manual confirmations dominate while LLM attributions
    /// contribute conservatively (preventing drift onto similar voices).
    ///
    /// When `personRepo` is supplied the repository:
    ///   1. Finds or creates the Person for `personName`
    ///   2. Looks up the VoiceProfile by personId first — so "dave@company.com"
    ///      and "Dave Smith" both merge into the same fingerprint
    ///   3. Stamps personId on any newly-created or previously-unlinked profile
    func merge(
        personName: String,
        newEmbedding: [Float],
        personRepo: PersonRepository? = nil,
        source: EmbeddingSource = .voiceMatch
    ) async throws {
        let resolvedPerson: Person?
        if let repo = personRepo {
            resolvedPerson = try await repo.findOrCreate(for: personName)
        } else {
            resolvedPerson = nil
        }
        let resolvedPersonId = resolvedPerson?.id

        try await database.writer.write { db in
            let alpha = source.alpha

            // Look up by personId first so different name strings for the same
            // person all compound into one fingerprint (Phase 2 dedup).
            let existing: VoiceProfile? = {
                if let pid = resolvedPersonId,
                   let byId = try? VoiceProfile
                    .filter(VoiceProfile.Columns.personId == pid)
                    .fetchOne(db) {
                    return byId
                }
                return try? VoiceProfile
                    .filter(VoiceProfile.Columns.personName == personName)
                    .fetchOne(db)
            }()

            if var row = existing {
                let old = row.embedding
                if old.count == newEmbedding.count {
                    // Re-normalize after the EMA: a lerp of two unit vectors is
                    // shorter than unit length, so the matcher's dot-product-
                    // as-cosine read systematically under-scores mature
                    // profiles against the fixed 0.82/0.87 thresholds.
                    var merged = zip(old, newEmbedding).map { o, n in o * (1 - alpha) + n * alpha }
                    let norm = sqrt(merged.reduce(Float(0)) { $0 + $1 * $1 })
                    if norm > 0 {
                        merged = merged.map { $0 / norm }
                    }
                    row.embedding = merged
                } else {
                    row.embedding = newEmbedding
                }
                row.sampleCount += 1
                switch source {
                case .manual, .voiceMatch: row.manualSampleCount += 1
                case .llm:                 row.llmSampleCount += 1
                }
                row.lastUpdatedAt = Date()
                if let pid = resolvedPersonId, row.personId == nil { row.personId = pid }
                // Keep the canonical name current
                if let person = resolvedPerson { row.personName = person.canonicalName }
                try row.update(db)
            } else {
                let canonicalName = resolvedPerson?.canonicalName ?? personName
                var profile = VoiceProfile.makeEmpty(personName: canonicalName, personId: resolvedPersonId)
                profile.embedding = newEmbedding
                profile.sampleCount = 1
                switch source {
                case .manual, .voiceMatch: profile.manualSampleCount = 1
                case .llm:                 profile.llmSampleCount = 1
                }
                profile.lastUpdatedAt = Date()
                try profile.insert(db)
            }
        }
    }

    func delete(personName: String) async throws {
        try await database.writer.write { db in
            _ = try VoiceProfile
                .filter(VoiceProfile.Columns.personName == personName)
                .deleteAll(db)
        }
    }

    func delete(personId: String) async throws {
        try await database.writer.write { db in
            _ = try VoiceProfile
                .filter(VoiceProfile.Columns.personId == personId)
                .deleteAll(db)
        }
    }
}

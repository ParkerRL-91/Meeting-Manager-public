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

    // MARK: - Write

    /// Merge a new embedding into the stored profile using an exponential
    /// moving average so more-recent meetings gradually dominate older ones.
    /// α = 0.3 means each new meeting contributes 30% to the profile.
    ///
    /// Pass `personRepo` to automatically link the profile to a Person record.
    func merge(
        personName: String,
        newEmbedding: [Float],
        personRepo: PersonRepository? = nil
    ) async throws {
        // Resolve personId if a PersonRepository is available
        let resolvedPersonId: String?
        if let repo = personRepo {
            resolvedPersonId = try await repo.findOrCreate(for: personName).id
        } else {
            resolvedPersonId = nil
        }

        try await database.writer.write { db in
            let alpha: Float = 0.3
            if var existing = try VoiceProfile
                .filter(VoiceProfile.Columns.personName == personName)
                .fetchOne(db) {
                let old = existing.embedding
                guard old.count == newEmbedding.count else {
                    existing.embedding = newEmbedding
                    existing.sampleCount += 1
                    existing.lastUpdatedAt = Date()
                    if let pid = resolvedPersonId, existing.personId == nil {
                        existing.personId = pid
                    }
                    try existing.update(db)
                    return
                }
                let merged = zip(old, newEmbedding).map { o, n in o * (1 - alpha) + n * alpha }
                existing.embedding = merged
                existing.sampleCount += 1
                existing.lastUpdatedAt = Date()
                if let pid = resolvedPersonId, existing.personId == nil {
                    existing.personId = pid
                }
                try existing.update(db)
            } else {
                var profile = VoiceProfile.makeEmpty(personName: personName, personId: resolvedPersonId)
                profile.embedding = newEmbedding
                profile.sampleCount = 1
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
}

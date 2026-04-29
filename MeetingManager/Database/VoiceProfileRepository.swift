import Foundation
import GRDB
import os

/// Persistence for per-person voice fingerprints. Profiles are keyed by
/// canonical person name. Upsert semantics: writing a new embedding for a
/// known name merges it via exponential moving average rather than replacing.
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

    // MARK: - Write

    /// Merge a new embedding into the stored profile using an exponential
    /// moving average so more-recent meetings gradually dominate older ones.
    /// α = 0.3 means each new meeting contributes 30% to the profile.
    func merge(personName: String, newEmbedding: [Float]) async throws {
        try await database.writer.write { db in
            let alpha: Float = 0.3
            if var existing = try VoiceProfile
                .filter(VoiceProfile.Columns.personName == personName)
                .fetchOne(db) {
                let old = existing.embedding
                guard old.count == newEmbedding.count else {
                    // Dimension mismatch — replace rather than blend
                    existing.embedding = newEmbedding
                    existing.sampleCount += 1
                    existing.lastUpdatedAt = Date()
                    try existing.update(db)
                    return
                }
                let merged = zip(old, newEmbedding).map { o, n in o * (1 - alpha) + n * alpha }
                existing.embedding = merged
                existing.sampleCount += 1
                existing.lastUpdatedAt = Date()
                try existing.update(db)
            } else {
                var profile = VoiceProfile.makeEmpty(personName: personName)
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

import Foundation
import GRDB
import os

/// Persistence for per-utterance voice samples. Supplements VoiceProfile's
/// EMA centroid with individual provenance records so contaminated or
/// misattributed samples can be identified and rolled back.
final class VoiceSampleRepository {
    private let database: AppDatabase
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.meetingmanager.app",
        category: "VoiceSampleRepository"
    )

    init(database: AppDatabase) {
        self.database = database
    }

    // MARK: - Read

    func samples(forPersonId personId: String) async throws -> [VoiceSample] {
        try await database.writer.read { db in
            try VoiceSample
                .filter(VoiceSample.Columns.personId == personId)
                .order(VoiceSample.Columns.createdAt.desc)
                .fetchAll(db)
        }
    }

    func samples(forMeetingId meetingId: String) async throws -> [VoiceSample] {
        try await database.writer.read { db in
            try VoiceSample
                .filter(VoiceSample.Columns.meetingId == meetingId)
                .fetchAll(db)
        }
    }

    func sampleCount(forPersonId personId: String) async throws -> Int {
        try await database.writer.read { db in
            try VoiceSample
                .filter(VoiceSample.Columns.personId == personId)
                .fetchCount(db)
        }
    }

    // MARK: - Write

    func save(_ sample: VoiceSample) async throws {
        try await database.writer.write { db in
            var s = sample
            try s.insert(db)
        }
    }

    /// Delete all samples from a meeting — used for rollback when a meeting's
    /// speaker attributions are found to be wrong.
    func deleteSamples(forMeetingId meetingId: String) async throws -> Int {
        try await database.writer.write { db in
            try VoiceSample
                .filter(VoiceSample.Columns.meetingId == meetingId)
                .deleteAll(db)
        }
    }

    /// Delete all samples for a person (e.g. when merging or clearing a profile).
    func deleteSamples(forPersonId personId: String) async throws {
        try await database.writer.write { db in
            _ = try VoiceSample
                .filter(VoiceSample.Columns.personId == personId)
                .deleteAll(db)
        }
    }

    // MARK: - Rebuild EMA from samples

    /// Recompute the EMA centroid for a person from their stored samples.
    /// Call after rolling back bad samples to restore the profile to a
    /// known-good state. Writes the result into VoiceProfileRepository.
    func rebuildProfile(forPersonId personId: String,
                        profileRepo: VoiceProfileRepository,
                        personRepo: PersonRepository) async throws {
        let samples = try await self.samples(forPersonId: personId)
        guard !samples.isEmpty else { return }

        guard let person = try await personRepo.allPersons().first(where: { $0.id == personId })
        else { return }

        // Recompute EMA in chronological order, α = 0.3
        let alpha: Float = 0.3
        var centroid = samples.first!.embedding
        for sample in samples.dropFirst() {
            let e = sample.embedding
            guard e.count == centroid.count else { continue }
            centroid = zip(centroid, e).map { c, n in c * (1 - alpha) + n * alpha }
        }

        // Write directly via the DB writer to avoid triggering another sample record
        try await database.writer.write { db in
            if var existing = try VoiceProfile
                .filter(VoiceProfile.Columns.personId == personId)
                .fetchOne(db) {
                existing.embedding = centroid
                existing.sampleCount = samples.count
                existing.lastUpdatedAt = Date()
                try existing.update(db)
            } else {
                var profile = VoiceProfile.makeEmpty(
                    personName: person.canonicalName,
                    personId: personId
                )
                profile.embedding = centroid
                profile.sampleCount = samples.count
                profile.lastUpdatedAt = Date()
                try profile.insert(db)
            }
        }
        logger.info("[VoiceSample] rebuilt profile for \(person.canonicalName, privacy: .public) from \(samples.count) samples")
    }
}

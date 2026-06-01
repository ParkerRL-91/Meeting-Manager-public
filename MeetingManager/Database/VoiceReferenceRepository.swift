import Foundation
import GRDB

/// Persistence for per-person FluidAudio voice references (Phase 2 cross-meeting
/// speaker identity). Keyed by `personId`; one row per Person. Writing a new
/// reference replaces the previous one — `SpeakerEnrollmentService` always
/// rebuilds the embedding from the person's best segments rather than blending,
/// so there is no EMA merge here (FluidAudio owns the matching; we just persist
/// the latest best aggregate).
final class VoiceReferenceRepository {
    private let database: AppDatabase

    init(database: AppDatabase) {
        self.database = database
    }

    // MARK: - Read

    func allReferences() async throws -> [VoiceReference] {
        try await database.writer.read { db in
            try VoiceReference.fetchAll(db)
        }
    }

    func reference(forPersonId personId: String) async throws -> VoiceReference? {
        try await database.writer.read { db in
            try VoiceReference.fetchOne(db, key: personId)
        }
    }

    /// References for a set of person ids, returned as `[personId: VoiceReference]`.
    func references(forPersonIds personIds: [String]) async throws -> [String: VoiceReference] {
        guard !personIds.isEmpty else { return [:] }
        let rows = try await database.writer.read { db in
            try VoiceReference
                .filter(personIds.contains(VoiceReference.Columns.personId))
                .fetchAll(db)
        }
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.personId, $0) })
    }

    // MARK: - Write

    /// Upsert the reference embedding for a person. Replaces any existing row.
    func save(personId: String, personName: String, embedding: [Float], segmentCount: Int) async throws {
        var ref = VoiceReference(
            personId: personId,
            personName: personName,
            embeddingData: Data(),
            segmentCount: segmentCount,
            updatedAt: Date()
        )
        ref.embedding = embedding
        try await database.writer.write { db in
            try ref.save(db)
        }
    }

    func delete(personId: String) async throws {
        try await database.writer.write { db in
            _ = try VoiceReference.deleteOne(db, key: personId)
        }
    }
}

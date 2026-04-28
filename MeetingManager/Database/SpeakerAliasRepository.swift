import Foundation
import GRDB
import os

/// Persistence for v3.1 Layer 3 user-confirmed speaker renames. Reads return
/// the aliases for a given series so the LLM attribution prompt can pre-seed
/// "you've previously identified Speaker 1 as Alex"; writes upsert on the
/// unique `(seriesKey, clusterId)` pair so renaming the same cluster twice
/// replaces rather than stacks.
final class SpeakerAliasRepository {
    private let database: AppDatabase

    init(database: AppDatabase) {
        self.database = database
    }

    /// All aliases for a given series, oldest first.
    func aliases(forSeriesKey key: String) async throws -> [SpeakerAlias] {
        try await database.writer.read { db in
            try SpeakerAlias
                .filter(SpeakerAlias.Columns.seriesKey == key)
                .order(SpeakerAlias.Columns.createdAt.asc)
                .fetchAll(db)
        }
    }

    /// Upsert an alias. The `(seriesKey, clusterId)` pair is unique at the
    /// DB layer; we delete any existing row before insert so the new
    /// resolvedName + createdAt fully replaces the prior entry.
    func upsert(seriesKey: String, clusterId: String, resolvedName: String) async throws {
        try await database.writer.write { db in
            try SpeakerAlias
                .filter(SpeakerAlias.Columns.seriesKey == seriesKey)
                .filter(SpeakerAlias.Columns.clusterId == clusterId)
                .deleteAll(db)
            var alias = SpeakerAlias(
                id: nil,
                seriesKey: seriesKey,
                clusterId: clusterId,
                resolvedName: resolvedName,
                createdAt: Date()
            )
            try alias.insert(db)
        }
    }
}

import Foundation
import GRDB

/// Persistence for the `apolloProfile` enrichment cache (PRJ-007 TASK-023,
/// ADR-014). Keyed 1:1 by `cacheKey` (lowercased email for people,
/// `domain:<domain>` for companies), replace-on-write. The TTL and
/// negative-cache policy live in `ApolloEnrichmentCoordinator`; this layer is
/// a plain store.
final class ApolloProfileRepository {
    private let database: AppDatabase

    init(database: AppDatabase = AppDatabase.shared) {
        self.database = database
    }

    /// The cached record for a key, regardless of age or `found` flag.
    /// The coordinator decides whether it's fresh enough to serve.
    func cached(forKey key: String) async throws -> ApolloProfileRecord? {
        try await database.writer.read { db in
            try ApolloProfileRecord
                .filter(ApolloProfileRecord.Columns.cacheKey == key)
                .fetchOne(db)
        }
    }

    /// Insert-or-replace the cache entry. A nil `profile` writes a negative
    /// cache row (`found == false`) so the coordinator won't re-fetch a
    /// known-empty key until it ages out.
    func upsert(
        key: String,
        kind: ApolloProfileRecord.Kind,
        profile: ApolloService.Profile?,
        found: Bool
    ) async throws {
        var record = ApolloProfileRecord.make(key: key, kind: kind, profile: profile)
        record.found = found
        try await database.writer.write { db in
            try record.save(db)
        }
    }

    /// Delete rows older than `date`. Called on a TTL-expiry sweep so stale
    /// (and negative-cache) entries don't accumulate forever.
    func purgeStale(olderThan date: Date) async throws {
        try await database.writer.write { db in
            _ = try ApolloProfileRecord
                .filter(ApolloProfileRecord.Columns.fetchedAt < date)
                .deleteAll(db)
        }
    }
}

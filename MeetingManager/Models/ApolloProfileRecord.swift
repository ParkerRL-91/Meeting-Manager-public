import Foundation
import GRDB

/// Persisted Apollo enrichment for one person or company (PRJ-007 TASK-023,
/// ADR-014). One row per `cacheKey`; `ApolloEnrichmentCoordinator` writes
/// these so profile cards survive quit/relaunch without re-hitting Apollo
/// within the TTL.
///
/// The Apollo `Profile` value (URLs, employment dates) is stored as JSON in
/// `payloadJSON`. Encode and decode go through `.iso8601`, which round-trips
/// the `Date` fields losslessly — the default `Date` strategy emits a
/// floating reference-time double that drifts and reads poorly in a SQLite
/// blob inspector, so we pin a stable string format instead.
struct ApolloProfileRecord: Codable, FetchableRecord, MutablePersistableRecord {
    /// Lowercased email (person) or `domain:<domain>` (company). Primary key.
    var cacheKey: String
    /// `"person"` or `"company"`.
    var kind: String
    /// JSON encoding of `ApolloService.Profile`. Empty / un-decodable when
    /// `found == false` (negative cache — no profile to store).
    var payloadJSON: String
    /// When the lookup was performed — the TTL basis.
    var fetchedAt: Date
    /// `false` = Apollo returned no match; a negative cache the coordinator
    /// honors so it doesn't re-fetch a known-empty key until it goes stale.
    var found: Bool

    static let databaseTableName = "apolloProfile"

    enum Columns {
        static let cacheKey    = Column(CodingKeys.cacheKey)
        static let kind        = Column(CodingKeys.kind)
        static let payloadJSON = Column(CodingKeys.payloadJSON)
        static let fetchedAt   = Column(CodingKeys.fetchedAt)
        static let found       = Column(CodingKeys.found)
    }

    enum Kind: String {
        case person
        case company
    }

    // MARK: - Profile encode / decode

    /// Shared JSON coders pinned to `.iso8601` so `Profile`'s `Date` fields
    /// round-trip identically on the way in and out.
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Decoded Apollo profile, or nil when this is a negative-cache row or the
    /// stored JSON can't be read.
    var profile: ApolloService.Profile? {
        guard found,
              let data = payloadJSON.data(using: .utf8),
              let decoded = try? Self.decoder.decode(ApolloService.Profile.self, from: data)
        else { return nil }
        return decoded
    }

    /// Build a record from a coordinator lookup result. A nil `profile`
    /// produces a negative-cache row (`found == false`, empty payload).
    static func make(
        key: String,
        kind: Kind,
        profile: ApolloService.Profile?,
        fetchedAt: Date = Date()
    ) -> ApolloProfileRecord {
        let json = profile
            .flatMap { try? encoder.encode($0) }
            .flatMap { String(data: $0, encoding: .utf8) }
            ?? ""
        return ApolloProfileRecord(
            cacheKey: key,
            kind: kind.rawValue,
            payloadJSON: json,
            fetchedAt: fetchedAt,
            found: profile != nil
        )
    }
}

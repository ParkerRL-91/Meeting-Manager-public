import XCTest
import GRDB
@testable import MeetingManager

/// Persistence + JSON round-trip seam for the Apollo enrichment cache
/// (PRJ-007 TASK-023, ADR-014). Proves the `.iso8601` date strategy
/// round-trips `Profile`'s URL/Date fields, that `upsert` overwrites,
/// that `cached(forKey:)` returns the row, that a `found == false` row is a
/// negative cache (no decoded profile), and that `purgeStale` drops old rows.
@MainActor
final class ApolloProfileRepositoryTests: XCTestCase {

    private var db: AppDatabase!
    private var repo: ApolloProfileRepository!

    override func setUpWithError() throws {
        db = try TestDatabase.create()
        repo = ApolloProfileRepository(database: db)
    }

    // MARK: - Fixture

    private func sampleProfile() -> ApolloService.Profile {
        ApolloService.Profile(
            name: "Dana Reyes",
            title: "VP Engineering",
            organizationName: "Acme Genomics",
            linkedinURL: URL(string: "https://www.linkedin.com/in/dana-reyes"),
            photoURL: URL(string: "https://photos.example.com/dana.jpg"),
            recentEmployment: [
                ApolloService.Employment(
                    title: "VP Engineering",
                    organizationName: "Acme Genomics",
                    startDate: Date(timeIntervalSince1970: 1_700_000_000),
                    endDate: nil
                ),
                ApolloService.Employment(
                    title: "Director",
                    organizationName: "Prior Co",
                    startDate: Date(timeIntervalSince1970: 1_500_000_000),
                    endDate: Date(timeIntervalSince1970: 1_690_000_000)
                )
            ],
            recentlyJoined: false,
            headline: "Building genomics infrastructure",
            location: "Boston, MA",
            industry: "Biotechnology",
            companyEmployees: 240,
            companyDescription: "A genomics platform company.",
            companyWebsite: URL(string: "https://acme.example.com")
        )
    }

    // MARK: - Round-trip (URL + Date via .iso8601)

    func testRoundTripPreservesURLsAndDates() async throws {
        let key = "dana@acme.example.com"
        let original = sampleProfile()
        try await repo.upsert(key: key, kind: .person, profile: original, found: true)

        let record = try await repo.cached(forKey: key)
        let decoded = try XCTUnwrap(record?.profile)

        XCTAssertEqual(decoded.name, original.name)
        // URL fields survive the iso8601-coded JSON blob.
        XCTAssertEqual(decoded.linkedinURL, original.linkedinURL)
        XCTAssertEqual(decoded.photoURL, original.photoURL)
        XCTAssertEqual(decoded.companyWebsite, original.companyWebsite)
        // Date fields round-trip exactly (the whole point of pinning .iso8601).
        XCTAssertEqual(decoded.recentEmployment.count, 2)
        XCTAssertEqual(decoded.recentEmployment[0].startDate, original.recentEmployment[0].startDate)
        XCTAssertEqual(decoded.recentEmployment[1].startDate, original.recentEmployment[1].startDate)
        XCTAssertEqual(decoded.recentEmployment[1].endDate, original.recentEmployment[1].endDate)
        XCTAssertNil(decoded.recentEmployment[0].endDate)
        XCTAssertEqual(decoded.companyEmployees, 240)
    }

    // MARK: - Upsert overwrites

    func testUpsertOverwrites() async throws {
        let key = "dana@acme.example.com"
        try await repo.upsert(key: key, kind: .person, profile: sampleProfile(), found: true)

        var updated = sampleProfile()
        updated = ApolloService.Profile(
            name: "Dana Reyes",
            title: "CTO",
            organizationName: updated.organizationName,
            linkedinURL: updated.linkedinURL,
            photoURL: updated.photoURL,
            recentEmployment: updated.recentEmployment,
            recentlyJoined: updated.recentlyJoined,
            headline: updated.headline,
            location: updated.location,
            industry: updated.industry,
            companyEmployees: updated.companyEmployees,
            companyDescription: updated.companyDescription,
            companyWebsite: updated.companyWebsite
        )
        try await repo.upsert(key: key, kind: .person, profile: updated, found: true)

        let record = try await repo.cached(forKey: key)
        XCTAssertEqual(record?.profile?.title, "CTO")
        // Still exactly one row (replace-on-write, not append).
        let count = try await db.writer.read { db in
            try ApolloProfileRecord.fetchCount(db)
        }
        XCTAssertEqual(count, 1)
    }

    // MARK: - Negative cache

    func testNegativeCacheStoresRowWithoutProfile() async throws {
        let key = "ghost@nowhere.example.com"
        try await repo.upsert(key: key, kind: .person, profile: nil, found: false)

        let record = try await repo.cached(forKey: key)
        // The row exists (so the coordinator won't re-fetch) but decodes to no
        // profile — that's the negative cache contract.
        XCTAssertNotNil(record)
        XCTAssertEqual(record?.found, false)
        XCTAssertNil(record?.profile)
    }

    func testCachedMissReturnsNil() async throws {
        let record = try await repo.cached(forKey: "unknown@example.com")
        XCTAssertNil(record)
    }

    // MARK: - Company key namespace

    func testCompanyKeyIsDistinctFromPersonKey() async throws {
        try await repo.upsert(key: "domain:acme.example.com", kind: .company, profile: sampleProfile(), found: true)
        let company = try await repo.cached(forKey: "domain:acme.example.com")
        let person = try await repo.cached(forKey: "acme.example.com")
        XCTAssertEqual(company?.kind, ApolloProfileRecord.Kind.company.rawValue)
        XCTAssertNil(person) // the domain: prefix keeps the namespaces apart
    }

    // MARK: - Purge stale

    func testPurgeStaleDropsOldRows() async throws {
        let staleKey = "old@acme.example.com"
        let freshKey = "new@acme.example.com"

        // Write a stale row dated well in the past, and a fresh row now.
        var stale = ApolloProfileRecord.make(key: staleKey, kind: .person, profile: sampleProfile())
        stale.fetchedAt = Date(timeIntervalSinceNow: -10 * 24 * 3600) // 10 days ago
        try await db.writer.write { db in try stale.save(db) }
        try await repo.upsert(key: freshKey, kind: .person, profile: sampleProfile(), found: true)

        // Purge anything older than 7 days.
        try await repo.purgeStale(olderThan: Date(timeIntervalSinceNow: -7 * 24 * 3600))

        let staleRecord = try await repo.cached(forKey: staleKey)
        let freshRecord = try await repo.cached(forKey: freshKey)
        XCTAssertNil(staleRecord)
        XCTAssertNotNil(freshRecord)
    }
}

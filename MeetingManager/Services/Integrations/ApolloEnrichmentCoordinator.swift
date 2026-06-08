import Foundation
import os

/// Persistence + policy layer over `ApolloService` for the Companies lens and
/// the richer profile cards (PRJ-007 TASK-023, ADR-014).
///
/// `ApolloService` only caches in memory for the session, so every launch
/// re-fetches. This coordinator persists each lookup in `apolloProfile` and
/// enforces the cost policy:
///   1. Gate — do nothing unless the caller passes `gateEnabled` (the view
///      computes it from `apolloProfilePrepEnabled && apolloKeyValidated`).
///      Off ⇒ no DB read, no network call, returns nil.
///   2. Fresh cache hit (within `ttl`) is served directly. A fresh
///      negative-cache row (`found == false`) is served as nil — no re-fetch.
///   3. On a miss / stale row, call `ApolloService.lookupPerson` and upsert
///      the result (including negative results).
///   4. On a network error during refresh, serve a stale cached profile if
///      one exists rather than failing the card.
///
/// Company enrichment reuses the same `lookupPerson` endpoint against a
/// representative member's email — Apollo returns the organization block
/// inside the person record, which is all the company card needs. The result
/// is cached under `domain:<domain>` so it's shared across every member.
@MainActor
final class ApolloEnrichmentCoordinator {

    static let shared = ApolloEnrichmentCoordinator()

    private let service: ApolloService
    private let repository: ApolloProfileRepository
    /// 7 days. One Apollo call per email/domain per week is the cost bound.
    private let ttl: TimeInterval = 7 * 24 * 3600

    init(
        service: ApolloService = .shared,
        repository: ApolloProfileRepository = ApolloProfileRepository()
    ) {
        self.service = service
        self.repository = repository
    }

    // MARK: - Person

    /// Resolve the Apollo profile for a person by email. Returns nil when the
    /// gate is closed, the email is blank, Apollo has no match, or the network
    /// fails with no usable cached fallback.
    func personProfile(email: String, gateEnabled: Bool) async -> ApolloService.Profile? {
        let key = normalize(email)
        guard gateEnabled, !key.isEmpty else { return nil }
        return await resolve(key: key, kind: .person, lookupEmail: key)
    }

    // MARK: - Company

    /// Resolve the Apollo company profile for a domain, using a representative
    /// member's email to drive the lookup. Cached under `domain:<domain>` so
    /// the result is shared across the org's members. Returns nil for consumer
    /// domains (gmail, …) — those are people, not employers.
    func companyProfile(domain: String, representativeEmail: String, gateEnabled: Bool) async -> ApolloService.Profile? {
        let normalizedDomain = domain.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let lookupEmail = normalize(representativeEmail)
        guard gateEnabled,
              !normalizedDomain.isEmpty,
              !lookupEmail.isEmpty,
              !CompanyGroupingService.isConsumerDomain(normalizedDomain)
        else { return nil }
        return await resolve(key: "domain:\(normalizedDomain)", kind: .company, lookupEmail: lookupEmail)
    }

    // MARK: - Refresh

    /// Force a re-fetch for a person, ignoring the cached row. Used by an
    /// explicit "Refresh" affordance on the card.
    func refreshPerson(email: String, gateEnabled: Bool) async -> ApolloService.Profile? {
        let key = normalize(email)
        guard gateEnabled, !key.isEmpty else { return nil }
        return await fetchAndStore(key: key, kind: .person, lookupEmail: key)
    }

    /// Force a re-fetch for a company, ignoring the cached row.
    func refreshCompany(domain: String, representativeEmail: String, gateEnabled: Bool) async -> ApolloService.Profile? {
        let normalizedDomain = domain.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let lookupEmail = normalize(representativeEmail)
        guard gateEnabled,
              !normalizedDomain.isEmpty,
              !lookupEmail.isEmpty,
              !CompanyGroupingService.isConsumerDomain(normalizedDomain)
        else { return nil }
        return await fetchAndStore(key: "domain:\(normalizedDomain)", kind: .company, lookupEmail: lookupEmail)
    }

    /// Drop cache rows past the TTL. Safe to call opportunistically (e.g. when
    /// the People directory loads) — negative-cache rows age out too.
    func purgeStale() async {
        try? await repository.purgeStale(olderThan: Date().addingTimeInterval(-ttl))
    }

    // MARK: - Core

    private func resolve(key: String, kind: ApolloProfileRecord.Kind, lookupEmail: String) async -> ApolloService.Profile? {
        if let cached = try? await repository.cached(forKey: key),
           Date().timeIntervalSince(cached.fetchedAt) < ttl {
            // Fresh — serve it. A fresh negative row resolves to nil with no
            // network call (honors the negative cache).
            return cached.profile
        }
        return await fetchAndStore(key: key, kind: kind, lookupEmail: lookupEmail)
    }

    private func fetchAndStore(key: String, kind: ApolloProfileRecord.Kind, lookupEmail: String) async -> ApolloService.Profile? {
        do {
            let profile = try await service.lookupPerson(email: lookupEmail)
            try? await repository.upsert(key: key, kind: kind, profile: profile, found: profile != nil)
            return profile
        } catch {
            Logger.general.warning("Apollo enrichment failed for \(key, privacy: .public): \(error.localizedDescription, privacy: .public)")
            // Serve a stale cached profile rather than failing the card.
            if let stale = try? await repository.cached(forKey: key) {
                return stale.profile
            }
            return nil
        }
    }

    private func normalize(_ email: String) -> String {
        email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

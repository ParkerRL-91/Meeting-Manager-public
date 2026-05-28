import Foundation
import os

/// Thin wrapper around Apollo.io's "people match" endpoint. Used by the
/// Attendee Profile section in the meeting view and pre-meeting prep
/// when the user has:
///   1. Toggled `apolloProfilePrepEnabled` in Settings,
///   2. Stored an API key in the Keychain (`KeychainHelper.Key.apolloAPIKey`), and
///   3. Run the "Test" button at least once (`apolloKeyValidated == true`).
///
/// API surface:
///   - `validate(apiKey:)` — Apollo doesn't expose a dedicated health endpoint,
///     so we call `/people/match` with a known-shape payload and inspect the
///     status code. 200 ⇒ valid; 401/403 ⇒ invalid key; anything else is
///     treated as a transient error and surfaces a generic message.
///   - `lookupPerson(email:)` — fetches a single person record. Returns nil
///     when the email can't be matched (Apollo returns 200 with a null
///     `person` field for unknowns). Network/HTTP errors throw.
///
/// Anti-cost guard: results are cached in-memory for the session keyed by
/// lowercased email so opening the same meeting twice doesn't burn the
/// Apollo credit allowance. A real persistent cache would be nice but the
/// data goes stale fast (job changes), so 1 hour per session is fine.
@MainActor
final class ApolloService {

    static let shared = ApolloService()

    // MARK: - Public models

    struct Profile: Codable, Sendable, Equatable {
        let name: String
        let title: String?
        let organizationName: String?
        let linkedinURL: URL?
        let photoURL: URL?
        /// Latest two employment records in reverse chronological order.
        let recentEmployment: [Employment]
        /// "Just started at X" — true when the most recent employment row
        /// has a `startDate` within the last 90 days. Surfaced as a small
        /// "Recently joined" badge in the UI.
        let recentlyJoined: Bool
    }

    struct Employment: Codable, Sendable, Equatable {
        let title: String?
        let organizationName: String?
        let startDate: Date?
        let endDate: Date?
    }

    enum ApolloError: LocalizedError {
        case invalidKey
        case rateLimited
        case http(Int)
        case decode(String)

        var errorDescription: String? {
            switch self {
            case .invalidKey:   return "Apollo rejected the API key. Double-check the value and try again."
            case .rateLimited:  return "Apollo rate-limited the request. Wait a minute and retry."
            case .http(let c): return "Apollo returned HTTP \(c)."
            case .decode(let m): return "Couldn't parse Apollo response: \(m)"
            }
        }
    }

    // MARK: - State

    private var sessionCache: [String: (profile: Profile?, fetchedAt: Date)] = [:]
    private let cacheTTL: TimeInterval = 3600 // 1 hour, per session
    private let session: URLSession
    private static let endpointMatch = URL(string: "https://api.apollo.io/api/v1/people/match")!

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Validation

    /// Calls Apollo with a throwaway email and inspects the response. Returns
    /// true on 200, throws ApolloError.invalidKey on 401/403, otherwise
    /// throws an HTTP error so the UI surfaces something actionable.
    func validate(apiKey: String) async throws -> Bool {
        // Use a real, unambiguously-public email so Apollo will respond 200
        // with either a hit or null person — both prove the key works.
        let (status, _) = try await postMatch(apiKey: apiKey, email: "no-reply@apollo.io")
        switch status {
        case 200:           return true
        case 401, 403:      throw ApolloError.invalidKey
        case 429:           throw ApolloError.rateLimited
        default:            throw ApolloError.http(status)
        }
    }

    // MARK: - Lookup

    /// Fetches the Apollo profile for an email. Returns nil when Apollo
    /// found no match (still a successful call). Throws on network/HTTP
    /// failure or invalid key.
    func lookupPerson(email: String) async throws -> Profile? {
        let key = email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        if let cached = sessionCache[key],
           Date().timeIntervalSince(cached.fetchedAt) < cacheTTL {
            return cached.profile
        }

        guard let apiKey = try? KeychainHelper.loadString(forKey: KeychainHelper.Key.apolloAPIKey),
              !apiKey.isEmpty else {
            throw ApolloError.invalidKey
        }

        let (status, data) = try await postMatch(apiKey: apiKey, email: key)
        switch status {
        case 200:
            let profile = try Self.decodeProfile(from: data)
            sessionCache[key] = (profile, Date())
            return profile
        case 401, 403:
            throw ApolloError.invalidKey
        case 429:
            throw ApolloError.rateLimited
        default:
            throw ApolloError.http(status)
        }
    }

    /// Clears the in-memory cache. Called when the user changes their key
    /// or toggles the feature off.
    func clearCache() {
        sessionCache.removeAll()
    }

    // MARK: - Internal

    private func postMatch(apiKey: String, email: String) async throws -> (Int, Data) {
        var req = URLRequest(url: Self.endpointMatch)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        req.timeoutInterval = 15

        let body: [String: Any] = [
            "email": email,
            "reveal_personal_emails": false,
            "reveal_phone_number": false
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        Logger.general.debug("Apollo /people/match → HTTP \(status) (\(data.count) bytes)")
        return (status, data)
    }

    // MARK: - Decoding

    /// Apollo's response wraps the person under `person`. Many fields are
    /// optional; treat anything we can't read as nil and return a
    /// minimum-viable profile when at least the name is present. Returns
    /// nil when the response carries no person at all.
    static func decodeProfile(from data: Data) throws -> Profile? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ApolloError.decode("expected object root")
        }
        guard let person = json["person"] as? [String: Any] else {
            return nil
        }

        let first = (person["first_name"] as? String) ?? ""
        let last = (person["last_name"] as? String) ?? ""
        let fullName = (person["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? [first, last].filter { !$0.isEmpty }.joined(separator: " ")
        guard !fullName.isEmpty else { return nil }

        let title = (person["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let org = person["organization"] as? [String: Any]
        let orgName = (org?["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let linkedin = (person["linkedin_url"] as? String).flatMap(URL.init(string:))
        let photo = (person["photo_url"] as? String).flatMap(URL.init(string:))

        var employmentRows: [Employment] = []
        if let history = person["employment_history"] as? [[String: Any]] {
            for row in history.prefix(2) {
                let rowTitle = (row["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                let rowOrg = (row["organization_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                let start = parseDate(row["start_date"] as? String)
                let end = parseDate(row["end_date"] as? String)
                employmentRows.append(Employment(
                    title: rowTitle,
                    organizationName: rowOrg,
                    startDate: start,
                    endDate: end
                ))
            }
        }

        let recentlyJoined: Bool = {
            guard let mostRecentStart = employmentRows.first?.startDate else { return false }
            return Date().timeIntervalSince(mostRecentStart) < (90 * 24 * 3600)
        }()

        return Profile(
            name: fullName,
            title: title,
            organizationName: orgName,
            linkedinURL: linkedin,
            photoURL: photo,
            recentEmployment: employmentRows,
            recentlyJoined: recentlyJoined
        )
    }

    /// Apollo dates arrive as `YYYY-MM-DD` (or sometimes `YYYY-MM`). Be
    /// permissive — partial dates are still useful for "Joined Jan 2025".
    private static func parseDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let formats = ["yyyy-MM-dd", "yyyy-MM", "yyyy"]
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        for f in formats {
            fmt.dateFormat = f
            if let d = fmt.date(from: raw) { return d }
        }
        return nil
    }
}

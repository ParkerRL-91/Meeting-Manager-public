import Foundation

/// Derives `Company` groupings from `Person` records at runtime — no
/// persistence (see ADR-014). People are grouped by email domain; people on
/// consumer domains (or with no email) collapse into one "Personal / No
/// company" bucket. Pure and synchronous over already-loaded arrays, so it's
/// cheap to call from a view's load task and trivial to unit-test.
enum CompanyGroupingService {

    /// Email domains that are personal, not employers. A person on one of
    /// these (or with no email) lands in the personal bucket, and never
    /// triggers a company-level Apollo lookup.
    static let consumerDomains: Set<String> = [
        "gmail.com", "googlemail.com", "outlook.com", "hotmail.com", "live.com",
        "msn.com", "yahoo.com", "ymail.com", "icloud.com", "me.com", "mac.com",
        "aol.com", "proton.me", "protonmail.com", "gmx.com", "pm.me", "hey.com",
        "fastmail.com", "zoho.com", "yandex.com", "qq.com", "163.com", "126.com"
    ]

    static func isConsumerDomain(_ domain: String) -> Bool {
        consumerDomains.contains(domain.lowercased())
    }

    /// Display label for a domain — "acme.com" → "Acme". Mirrors
    /// `Person.orgHint` so the People and Companies lenses agree on the name.
    static func displayName(forDomain domain: String) -> String {
        let base = domain.components(separatedBy: ".").first ?? domain
        guard !base.isEmpty else { return domain }
        return base.prefix(1).uppercased() + base.dropFirst()
    }

    /// Meetings in which any of `people` participated, deduplicated by meeting
    /// id (a meeting with two colleagues counts once). Uses the same
    /// canonical-key matching the People lens relies on (`Person.matches`).
    static func meetingsInvolving(people: [Person], in meetings: [Meeting]) -> [Meeting] {
        guard !people.isEmpty else { return [] }
        return meetings.filter { meeting in
            people.contains { person in
                meeting.participantList.contains { person.matches(participant: $0) }
            }
        }
    }

    /// Group `persons` into companies over the given meeting set. Real
    /// companies are sorted most-recently-met first; the personal bucket
    /// (if any) always renders last.
    static func companies(from persons: [Person], meetings: [Meeting]) -> [Company] {
        var byDomain: [String: [Person]] = [:]
        var personalPeople: [Person] = []

        for person in persons {
            if let domain = person.domain, !isConsumerDomain(domain) {
                byDomain[domain, default: []].append(person)
            } else {
                personalPeople.append(person)
            }
        }

        var companies: [Company] = byDomain.map { domain, people in
            let matched = meetingsInvolving(people: people, in: meetings)
            return Company(
                id: domain,
                domain: domain,
                displayName: displayName(forDomain: domain),
                people: people.sorted { $0.canonicalName < $1.canonicalName },
                meetingCount: matched.count,
                lastMet: matched.map(\.effectiveDate).max()
            )
        }

        companies.sort { a, b in
            switch (a.lastMet, b.lastMet) {
            case let (l?, r?): return l == r ? a.displayName < b.displayName : l > r
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return a.displayName < b.displayName
            }
        }

        if !personalPeople.isEmpty {
            let matched = meetingsInvolving(people: personalPeople, in: meetings)
            companies.append(Company(
                id: Company.personalBucketID,
                domain: "",
                displayName: "Personal / No company",
                people: personalPeople.sorted { $0.canonicalName < $1.canonicalName },
                meetingCount: matched.count,
                lastMet: matched.map(\.effectiveDate).max()
            ))
        }

        return companies
    }
}

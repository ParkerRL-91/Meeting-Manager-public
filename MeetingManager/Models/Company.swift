import Foundation

/// A company is derived at runtime by grouping `Person` records by email
/// domain — there is no `company` table (see ADR-014). People with no
/// corporate email (no email at all, or a consumer domain like gmail.com)
/// collect into a single synthetic "Personal / No company" bucket.
///
/// Identity is the normalized domain, so `Company` is `Hashable`/`Equatable`
/// on `id` alone (its `people` array isn't part of identity).
struct Company: Identifiable {
    /// Normalized lowercase domain (e.g. "acme.com"), or `personalBucketID`.
    var id: String
    /// Email domain; empty string for the personal bucket.
    var domain: String
    /// Human-readable label, e.g. "Acme" or "Personal / No company".
    var displayName: String
    /// Members, sorted by canonical name.
    var people: [Person]
    /// Distinct meetings with anyone from this company.
    var meetingCount: Int
    /// Most recent meeting date with anyone from this company.
    var lastMet: Date?

    var isPersonalBucket: Bool { id == Company.personalBucketID }

    static let personalBucketID = "__personal__"
}

extension Company: Hashable {
    static func == (lhs: Company, rhs: Company) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

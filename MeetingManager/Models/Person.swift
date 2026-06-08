import Foundation
import GRDB

/// Stable person identity record. A Person is the canonical anchor for a
/// real human across all name/email format variants — "Dave Smith",
/// "dave@acme.com", "dave.smith@company.com" all resolve to the same
/// Person row. VoiceProfile links here via personId so voice learning
/// survives renames, email changes, and display-name drift.
///
/// aliases stores every observed raw string for this person (emails,
/// display names), serialised as a JSON array. The canonical name is the
/// best human-readable label we have.
struct Person: Codable, Identifiable, FetchableRecord, MutablePersistableRecord {
    var id: String           // UUID string, set on init
    var canonicalName: String
    var aliasesJSON: String  // JSON-encoded [String]
    var createdAt: Date
    var updatedAt: Date

    static let databaseTableName = "person"

    enum CodingKeys: String, CodingKey {
        case id, canonicalName, aliasesJSON, createdAt, updatedAt
    }

    enum Columns {
        static let id            = Column(CodingKeys.id)
        static let canonicalName = Column(CodingKeys.canonicalName)
        static let aliasesJSON   = Column(CodingKeys.aliasesJSON)
        static let createdAt     = Column(CodingKeys.createdAt)
        static let updatedAt     = Column(CodingKeys.updatedAt)
    }

    // MARK: - Computed helpers

    /// All known aliases (display names + emails) for this person.
    var aliases: [String] {
        guard let data = aliasesJSON.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return decoded
    }

    /// Set the aliases list, re-encoding to JSON.
    mutating func setAliases(_ list: [String]) {
        let deduped = Array(OrderedSet(list))
        aliasesJSON = (try? String(data: JSONEncoder().encode(deduped), encoding: .utf8)) ?? "[]"
    }

    /// First email alias for this person, lowercased, e.g. "dave@acme.com".
    /// Drives Apollo enrichment lookups (the cache key for the person card and
    /// the representative-member lookup for the company card).
    var primaryEmail: String? {
        for alias in aliases where alias.contains("@") {
            let trimmed = alias.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    /// Primary email domain extracted from the first email alias, e.g. "acme.com".
    /// Used for disambiguation when two people share the same first name but
    /// work at different organisations.
    var domain: String? {
        for alias in aliases where alias.contains("@") {
            if let d = alias.components(separatedBy: "@").last?.lowercased(), !d.isEmpty {
                return d
            }
        }
        return nil
    }

    /// Short org hint derived from domain — strips common TLDs for display.
    /// "acme.com" → "Acme", "dave@acme.io" → "Acme"
    var orgHint: String? {
        guard let d = domain else { return nil }
        let base = d.components(separatedBy: ".").first ?? d
        return base.prefix(1).uppercased() + base.dropFirst()
    }

    /// Returns true if any alias (via canonical key) matches the given raw participant string.
    func matches(participant rawName: String) -> Bool {
        let key = VocativeMiningService.canonicalKey(for: rawName)
        return !key.isEmpty && canonicalKeys.contains(key)
    }

    /// All canonical keys (lowercased first names) for this person — used to
    /// match incoming raw attendee strings against existing Person records.
    var canonicalKeys: Set<String> {
        var keys = Set<String>()
        keys.insert(VocativeMiningService.canonicalKey(for: canonicalName))
        for alias in aliases {
            let k = VocativeMiningService.canonicalKey(for: alias)
            if !k.isEmpty { keys.insert(k) }
        }
        return keys
    }

    // MARK: - Factory

    static func make(canonicalName: String, aliases: [String] = []) -> Person {
        var p = Person(
            id: UUID().uuidString,
            canonicalName: canonicalName,
            aliasesJSON: "[]",
            createdAt: Date(),
            updatedAt: Date()
        )
        let all = ([canonicalName] + aliases).filter { !$0.isEmpty }
        p.setAliases(all)
        return p
    }
}

// MARK: - Ordered dedup helper (no import needed)

/// Preserves insertion order while deduplicating. Used only by Person.setAliases.
private struct OrderedSet<T: Hashable>: Sequence {
    private var seen = Set<T>()
    private var list = [T]()

    init(_ source: [T]) {
        for item in source { insert(item) }
    }

    mutating func insert(_ item: T) {
        if seen.insert(item).inserted { list.append(item) }
    }

    func makeIterator() -> Array<T>.Iterator { list.makeIterator() }
}

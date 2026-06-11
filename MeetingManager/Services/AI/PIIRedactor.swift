import Foundation
import NaturalLanguage

/// Reversible PII redaction for cloud calls (TASK-054). Built per call
/// from the names the app KNOWS (participants + Person aliases) plus
/// best-effort NLTagger name detection and email/phone regexes over the
/// outgoing text. Applied only when the user enables
/// "privacy.redactCloudPII"; attribution and title calls are exempt by
/// design — closed-set name matching needs the real names, and the
/// setting's help text says so. Documented honestly: a heuristic shield,
/// not a guarantee.
struct PIIRedactor: Sendable {
    static let settingKey = "privacy.redactCloudPII"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: settingKey)
    }

    /// (original, token) pairs, longest original first so "Dave Smith"
    /// tokenizes before "Dave".
    private let pairs: [(original: String, token: String)]

    var isEmpty: Bool { pairs.isEmpty }

    /// Build from known names plus a scan of the outgoing texts.
    static func build(knownNames: [String], texts: [String]) -> PIIRedactor {
        var names = Set(knownNames.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count > 2 && !$0.contains("@") })
        var emails = Set(knownNames.filter { $0.contains("@") })

        let joined = texts.joined(separator: "\n")

        // Emails anywhere in the outgoing text.
        if let regex = try? NSRegularExpression(pattern: #"[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#) {
            let range = NSRange(joined.startIndex..., in: joined)
            for match in regex.matches(in: joined, range: range) {
                if let r = Range(match.range, in: joined) { emails.insert(String(joined[r])) }
            }
        }
        // Phone numbers (NSDataDetector — handles formats regexes miss).
        var phones: Set<String> = []
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.phoneNumber.rawValue) {
            let range = NSRange(joined.startIndex..., in: joined)
            for match in detector.matches(in: joined, range: range) {
                if let phone = match.phoneNumber { phones.insert(phone) }
            }
        }
        // NLTagger personal names not already known (best-effort; capped so a
        // pathological transcript can't build a 10k-entry map).
        let tagger = NLTagger(tagSchemes: [.nameType])
        let sample = String(joined.prefix(30_000))
        tagger.string = sample
        tagger.enumerateTags(in: sample.startIndex..<sample.endIndex, unit: .word,
                             scheme: .nameType,
                             options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
            if tag == .personalName, names.count < 80 {
                let name = String(sample[range])
                if name.count > 2 { names.insert(name) }
            }
            return true
        }

        var pairs: [(String, String)] = []
        for (i, name) in names.sorted(by: { $0.count > $1.count }).enumerated() {
            pairs.append((name, "Person \(Self.letterLabel(i))"))
        }
        for (i, email) in emails.sorted().enumerated() {
            pairs.append((email, "person\(i + 1)@redacted.example"))
        }
        for (i, phone) in phones.sorted().enumerated() {
            pairs.append((phone, "555-01\(String(format: "%02d", i))"))
        }
        return PIIRedactor(pairs: pairs)
    }

    private static func letterLabel(_ i: Int) -> String {
        let letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ".map(String.init)
        return i < letters.count ? letters[i] : "\(letters[i % 26])\(i / 26 + 1)"
    }

    func redact(_ text: String) -> String {
        var out = text
        for (original, token) in pairs {
            out = out.replacingOccurrences(of: original, with: token)
        }
        return out
    }

    func restore(_ text: String) -> String {
        // Reverse longest-token-first so "Person A1" restores before "Person A".
        var out = text
        for (original, token) in pairs.sorted(by: { $0.token.count > $1.token.count }) {
            out = out.replacingOccurrences(of: token, with: original)
        }
        return out
    }
}

import Foundation

/// Normalizes browser tab / call-app window titles into a stable comparison
/// key so the switch detector can tell a *real* meeting change apart from a
/// cosmetic one (unread-count flip, mute-status glyph, platform suffix churn).
///
/// The engine compares these keys as a SET (see `MeetingSwitchDetectionService`),
/// never against a calendar title — so a tab title like "Meet – abc-defg-hij"
/// that would never equal "Design Review" doesn't cause a false switch.
///
/// Pure and `Sendable`: no state, no I/O, safe to call from any isolation.
struct MeetingTitleNormalizer: Sendable {

    /// Google Meet room codes look like `abc-defg-hij` — three, four, three
    /// lowercase letters. The code uniquely identifies the room, so when a
    /// title contains one it becomes the whole identity token (a code change
    /// is unambiguously a room switch; everything else in the title is noise).
    private static let meetCodePattern = try! NSRegularExpression(
        pattern: "\\b([a-z]{3}-[a-z]{4}-[a-z]{3})\\b",
        options: []
    )

    /// Leading unread/notification count, e.g. "(3) Design Review".
    private static let unreadPrefixPattern = try! NSRegularExpression(
        pattern: "^\\(\\d+\\)\\s*",
        options: []
    )

    /// Platform suffixes stripped case-insensitively. Order matters only in
    /// that longer, more specific suffixes are listed first.
    private static let platformSuffixes: [String] = [
        " — Zoom Meeting",
        " - Zoom Meeting",
        " | Microsoft Teams",
        " - Microsoft Teams",
        " - Google Meet",
        " - Zoom",
        " | Zoom",
    ]

    /// Leading Meet prefixes per `CalendarMeetingMatcher`'s patterns.
    private static let meetPrefixes: [String] = [
        "Meet with ",
        "Meet - ",
        "Meet – ",
    ]

    /// Titles that carry no meeting identity — a generic platform chrome string
    /// that every call of that kind shares. These normalize to `nil` (no signal).
    private static let genericTitles: Set<String> = [
        "meet",
        "meeting",
        "zoom",
        "zoom meeting",
        "google meet",
        "microsoft teams",
        "teams",
        "webex",
        "webex meeting",
        "new meeting",
        "browser call",
    ]

    /// Returns a normalized identity key for `rawTitle`, or `nil` when the
    /// title carries no meeting identity (generic platform chrome, empty).
    ///
    /// Cosmetic-only differences (unread count, leading status glyph, platform
    /// suffix) collapse to the same key; a Meet room-code change produces a
    /// different key.
    func normalize(_ rawTitle: String) -> String? {
        var title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }

        // Strip a leading unread/notification count.
        title = Self.unreadPrefixPattern.stringByReplacingMatches(
            in: title,
            range: NSRange(title.startIndex..., in: title),
            withTemplate: ""
        )

        // Strip leading status glyphs / emoji / punctuation (e.g. "🔴 ", "• ").
        title = Self.strippingLeadingGlyphs(title)

        // A Meet room code anywhere is the strongest identity signal — use it
        // verbatim and ignore the rest of the title.
        if let code = Self.meetCode(in: title) {
            return code
        }

        // Strip a Meet prefix ("Meet with Parker" → "Parker").
        for prefix in Self.meetPrefixes where title.lowercased().hasPrefix(prefix.lowercased()) {
            title = String(title.dropFirst(prefix.count))
            break
        }

        // Strip a trailing platform suffix.
        for suffix in Self.platformSuffixes {
            if title.lowercased().hasSuffix(suffix.lowercased()) {
                title = String(title.dropLast(suffix.count))
                break
            }
        }

        // Case-fold + collapse internal whitespace.
        let collapsed = title
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()

        guard !collapsed.isEmpty, !Self.genericTitles.contains(collapsed) else { return nil }
        return collapsed
    }

    /// The lowercased Meet room code contained in `title`, if any.
    private static func meetCode(in title: String) -> String? {
        let lowered = title.lowercased()
        let range = NSRange(lowered.startIndex..., in: lowered)
        guard let match = meetCodePattern.firstMatch(in: lowered, range: range),
              let codeRange = Range(match.range(at: 1), in: lowered) else { return nil }
        return String(lowered[codeRange])
    }

    /// Drops leading whitespace, symbols, emoji, and punctuation — the status
    /// glyphs some platforms prepend ("🔴", "•", "▶") — without touching a
    /// legitimate alphanumeric first character.
    private static func strippingLeadingGlyphs(_ input: String) -> String {
        var chars = Array(input)
        var index = 0
        while index < chars.count {
            let c = chars[index]
            let strippable = c.isWhitespace || c.isSymbol || c.isPunctuation
                || (c.unicodeScalars.first?.properties.isEmoji ?? false)
            if strippable { index += 1 } else { break }
        }
        return String(chars[index...])
    }
}

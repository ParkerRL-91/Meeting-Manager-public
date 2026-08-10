import Foundation

/// Extracts a conferencing "join the call" URL out of free-text calendar
/// fields (event location, notes/description body).
///
/// This is the single source of truth for conferencing-link detection,
/// shared by both `AppleCalendarService` (EventKit) and
/// `GoogleCalendarService` (REST). It uses `NSDataDetector`'s link checker,
/// restricted to matches that carry an explicit scheme in the source text,
/// so a bare-domain prose mention ("we'll use zoom.us") is never treated as
/// a link. Matches are then disambiguated by host against a known list of
/// conferencing platforms.
enum ConferencingLinkParser {

    /// Known conferencing-platform domains. A detected URL is a "join" link
    /// when its host IS one of these or is a subdomain of one (suffix match —
    /// `us02web.zoom.us` matches `zoom.us`; `zoom.us.evil.com` does NOT).
    /// The legacy `contains` matching was spoofable, and TASK-127 routes
    /// derived links into the −60s auto-open, so exactness matters now.
    /// (Dropped from the legacy list: "g.co/meet" — a host never contains a
    /// slash, so it was dead; "meet.jit.si" — subsumed by "jit.si".)
    static let conferencingHostPatterns: [String] = [
        "zoom.us", "zoom.com",
        "meet.google.com",
        "teams.microsoft.com", "teams.live.com",
        "webex.com",
        "gotomeeting.com", "gotomeet.me",
        "whereby.com",
        "bluejeans.com",
        "ringcentral.com",
        "jit.si",
        "around.co",
        "discord.gg",
    ]

    /// Exact-or-subdomain host match.
    private static func hostMatches(_ host: String, _ pattern: String) -> Bool {
        host == pattern || host.hasSuffix("." + pattern)
    }

    /// Real URLs detected in `text`, in the order they appear.
    ///
    /// `NSDataDetector`'s link checker also matches bare domains in prose and
    /// synthesizes an `http://` URL for them — "we'll use zoom.us for this one"
    /// yields `http://zoom.us`, which would become a dead Join button. Requiring
    /// the matched source text to carry a scheme keeps those out. (It also drops
    /// `mailto:` matches, which are never join links.)
    private static func detectedURLs(in text: String) -> [URL] {
        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, options: [], range: range).compactMap { match in
            guard let url = match.url,
                  let matched = Range(match.range, in: text),
                  text[matched].contains("://") else { return nil }
            return url
        }
    }

    /// Returns the first real URL whose host matches a known conferencing
    /// platform, scanning `candidates` in order and, within each candidate,
    /// in the order the URLs appear. Nil candidates are skipped.
    static func firstConferencingURL(in candidates: [String?]) -> String? {
        for text in candidates {
            guard let text else { continue }
            for url in detectedURLs(in: text) {
                guard let host = url.host?.lowercased() else { continue }
                if conferencingHostPatterns.contains(where: { hostMatches(host, $0) }) {
                    return url.absoluteString
                }
            }
        }
        return nil
    }

    /// Returns the first real URL of any kind, scanning `candidates` in order.
    /// Used as a fallback by the Apple path only (Google intentionally never
    /// grabs an arbitrary body URL, which could be a docs/agenda link).
    static func firstURL(in candidates: [String?]) -> String? {
        for text in candidates {
            guard let text else { continue }
            if let url = detectedURLs(in: text).first { return url.absoluteString }
        }
        return nil
    }
}

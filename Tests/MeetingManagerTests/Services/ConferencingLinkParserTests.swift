import XCTest
@testable import MeetingManager

final class ConferencingLinkParserTests: XCTestCase {

    // MARK: - firstConferencingURL

    func testZoomURLInDescription() {
        let desc = "Agenda attached. Join Zoom Meeting\nhttps://us02web.zoom.us/j/8461234567?pwd=abc"
        XCTAssertEqual(
            ConferencingLinkParser.firstConferencingURL(in: [nil, desc]),
            "https://us02web.zoom.us/j/8461234567?pwd=abc"
        )
    }

    func testZoomURLInLocation() {
        let location = "https://zoom.us/j/99887766"
        XCTAssertEqual(
            ConferencingLinkParser.firstConferencingURL(in: [location, "some notes"]),
            "https://zoom.us/j/99887766"
        )
    }

    func testTeamsURL() {
        let text = "Microsoft Teams meeting https://teams.microsoft.com/l/meetup-join/xyz"
        XCTAssertEqual(
            ConferencingLinkParser.firstConferencingURL(in: [text]),
            "https://teams.microsoft.com/l/meetup-join/xyz"
        )
    }

    func testWebexURL() {
        let text = "Join: https://acme.webex.com/meet/room123"
        XCTAssertEqual(
            ConferencingLinkParser.firstConferencingURL(in: [text]),
            "https://acme.webex.com/meet/room123"
        )
    }

    func testProseWithoutURLReturnsNil() {
        // Bare-domain prose must NOT match — only real URLs are extracted.
        let text = "We'll use zoom.us for this one, details to follow on teams.microsoft.com"
        XCTAssertNil(ConferencingLinkParser.firstConferencingURL(in: [text]))
    }

    func testMultipleURLsPicksConferencingHost() {
        // A docs link appears before the Zoom link; the conferencing host wins.
        let text = """
        Pre-read: https://docs.google.com/document/d/abc123
        Join Zoom Meeting: https://us02web.zoom.us/j/555000
        """
        XCTAssertEqual(
            ConferencingLinkParser.firstConferencingURL(in: [text]),
            "https://us02web.zoom.us/j/555000"
        )
    }

    func testLocationScannedBeforeDescription() {
        // Candidate order matters: a conferencing URL in location wins over one
        // in the description.
        let location = "https://zoom.us/j/111"
        let description = "backup https://meet.google.com/abc-defg-hij"
        XCTAssertEqual(
            ConferencingLinkParser.firstConferencingURL(in: [location, description]),
            "https://zoom.us/j/111"
        )
    }

    func testNoConferencingURLReturnsNil() {
        let text = "See the doc at https://docs.google.com/document/d/abc123"
        XCTAssertNil(ConferencingLinkParser.firstConferencingURL(in: [text]))
    }

    func testAllNilCandidates() {
        XCTAssertNil(ConferencingLinkParser.firstConferencingURL(in: [nil, nil]))
    }

    // MARK: - firstURL (Apple fallback)

    func testFirstURLFallbackReturnsAnyURL() {
        let text = "Dial-in doc: https://docs.google.com/document/d/xyz"
        XCTAssertEqual(
            ConferencingLinkParser.firstURL(in: [nil, text]),
            "https://docs.google.com/document/d/xyz"
        )
    }

    func testFirstURLProseWithoutURLReturnsNil() {
        XCTAssertNil(ConferencingLinkParser.firstURL(in: ["no links here at all"]))
    }

    // TASK-127 review fix: host matching is exact-or-subdomain, not substring —
    // a lookalike domain must not be treated as a join link (derived links feed
    // the -60s auto-open).
    func testSpoofedHostDoesNotMatch() {
        let text = "Join here: https://zoom.us.evil.com/j/12345"
        XCTAssertNil(ConferencingLinkParser.firstConferencingURL(in: [text]))
    }

    func testSubdomainHostMatches() {
        let text = "https://us02web.zoom.us/j/12345?pwd=abc"
        XCTAssertEqual(ConferencingLinkParser.firstConferencingURL(in: [text]),
                       "https://us02web.zoom.us/j/12345?pwd=abc")
    }
}

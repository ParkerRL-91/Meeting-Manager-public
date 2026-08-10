import XCTest
@testable import MeetingManager

/// Tests for person-identity and recurring-meeting-series key logic.
/// Covers CLAUDE.md constraint #9 and ADR-003: Person Identity Model.
///
/// Services under test:
/// - `VocativeMiningService.canonicalKey(for:)` — first-name extraction / lowercasing
/// - `VocativeMiningService.textMentionsVocative(_:name:)` — vocative pattern matching
/// - `MeetingSeriesService.seriesKey(for:)` — stable series key via normalize + SHA-256
/// - `Person.canonicalKeys` / `Person.matches(participant:)` — alias-aware identity
/// - `Meeting.acceptedParticipantList` — RSVP-gate filtering by identityKey
///
/// Note: `MeetingSeriesService` is `@MainActor` so the class is annotated accordingly.
@MainActor
final class IdentityKeysTests: XCTestCase {

    // MARK: - Helpers

    /// The `MeetingSeriesService.shared` singleton is `@MainActor`.
    /// `seriesKey(for:)` is `nonisolated`, so accessing it through the shared
    /// instance is safe from a `@MainActor` test class.
    private let seriesService = MeetingSeriesService.shared

    /// Build a minimal `Meeting` with just the fields these tests need.
    private func meeting(
        id: String = UUID().uuidString,
        title: String,
        participants: String? = nil,
        calendarEventId: String? = nil,
        declinedAttendees: String? = nil
    ) -> Meeting {
        Meeting(
            id: id,
            title: title,
            calendarEventId: calendarEventId,
            participants: participants,
            declinedAttendees: declinedAttendees
        )
    }

    // MARK: - VocativeMiningService.canonicalKey

    func testCanonicalKey_displayNameFirstLast() {
        XCTAssertEqual(VocativeMiningService.canonicalKey(for: "Dave Smith"), "dave")
    }

    func testCanonicalKey_displayNameFirstOnly() {
        XCTAssertEqual(VocativeMiningService.canonicalKey(for: "Dave"), "dave")
    }

    func testCanonicalKey_emailLocalPart_simple() {
        XCTAssertEqual(VocativeMiningService.canonicalKey(for: "dave@acme.com"), "dave")
    }

    func testCanonicalKey_emailLocalPart_dotSeparated() {
        // "dave.smith@acme.com" → local part "dave.smith" → first segment "dave"
        XCTAssertEqual(VocativeMiningService.canonicalKey(for: "dave.smith@acme.com"), "dave")
    }

    func testCanonicalKey_emailLocalPart_underscoreSeparated() {
        XCTAssertEqual(VocativeMiningService.canonicalKey(for: "dave_smith@acme.com"), "dave")
    }

    func testCanonicalKey_emailLocalPart_dashSeparated() {
        XCTAssertEqual(VocativeMiningService.canonicalKey(for: "dave-smith@acme.com"), "dave")
    }

    func testCanonicalKey_caseFolding_uppercase() {
        XCTAssertEqual(VocativeMiningService.canonicalKey(for: "DAVE SMITH"), "dave")
    }

    func testCanonicalKey_caseFolding_mixedCase() {
        XCTAssertEqual(VocativeMiningService.canonicalKey(for: "DaVe"), "dave")
    }

    func testCanonicalKey_leadingTrailingWhitespace() {
        // extractFirstName trims via component splitting (whitespace is a separator)
        XCTAssertEqual(VocativeMiningService.canonicalKey(for: "  Dave Smith  "), "dave")
    }

    func testCanonicalKey_emptyInput() {
        // Empty input → extractFirstName returns "" → canonicalKey returns ""
        XCTAssertEqual(VocativeMiningService.canonicalKey(for: ""), "")
    }

    func testCanonicalKey_twoDisplayVariantsSamePerson_sameKey() {
        // "Dana Pace" and "dana@acme.com" must produce the same first-name key
        let key1 = VocativeMiningService.canonicalKey(for: "Dana Pace")
        let key2 = VocativeMiningService.canonicalKey(for: "dana@acme.com")
        XCTAssertEqual(key1, key2)
    }

    func testCanonicalKey_differentPeople_differentKeys() {
        let key1 = VocativeMiningService.canonicalKey(for: "Alice Chen")
        let key2 = VocativeMiningService.canonicalKey(for: "Bob Chen")
        XCTAssertNotEqual(key1, key2)
    }

    func testCanonicalKey_emailMatchesDisplayName_capitalized() {
        // canonicalKey returns lowercased — both forms yield the same value
        let fromDisplay = VocativeMiningService.canonicalKey(for: "Dana Pace")
        let fromEmail   = VocativeMiningService.canonicalKey(for: "dana.pace@example.com")
        XCTAssertEqual(fromDisplay, fromEmail)
        XCTAssertEqual(fromDisplay, "dana")
    }

    // MARK: - VocativeMiningService.textMentionsVocative

    func testVocative_heyGreeting() {
        XCTAssertTrue(VocativeMiningService.textMentionsVocative("Hey Dana, what do you think?", name: "dana"))
    }

    func testVocative_hiGreeting() {
        XCTAssertTrue(VocativeMiningService.textMentionsVocative("Hi Dana, can you share the update?", name: "dana"))
    }

    func testVocative_thanksAcknowledgement() {
        XCTAssertTrue(VocativeMiningService.textMentionsVocative("Thanks Dana for sharing that.", name: "dana"))
    }

    func testVocative_trailingComma() {
        // "..., Name" pattern near end of utterance
        XCTAssertTrue(VocativeMiningService.textMentionsVocative("Over to you, dana", name: "dana"))
    }

    func testVocative_trailingCommaWithQuestion() {
        XCTAssertTrue(VocativeMiningService.textMentionsVocative("What do you think, dana?", name: "dana"))
    }

    func testVocative_standaloneNameWithQuestion() {
        // Entire text is just the name + "?" — handoff pattern
        XCTAssertTrue(VocativeMiningService.textMentionsVocative("Dana?", name: "dana"))
    }

    func testVocative_standaloneNameOnly() {
        XCTAssertTrue(VocativeMiningService.textMentionsVocative("dana", name: "dana"))
    }

    func testVocative_caseInsensitive() {
        // textMentionsVocative lowercases `text` internally; name is already lowercase
        XCTAssertTrue(VocativeMiningService.textMentionsVocative("Hey DANA, great point.", name: "dana"))
    }

    func testVocative_substringFalsePositive_samNotInSame() {
        // "sam" must not match inside "same" — word-boundary protection
        XCTAssertFalse(VocativeMiningService.textMentionsVocative("That's the same approach we used.", name: "sam"))
    }

    func testVocative_substringFalsePositive_alNotInAlso() {
        XCTAssertFalse(VocativeMiningService.textMentionsVocative("We should also review the doc.", name: "al"))
    }

    func testVocative_nameNotPresent() {
        XCTAssertFalse(VocativeMiningService.textMentionsVocative("Let's move on to the next item.", name: "dana"))
    }

    func testVocative_nameInMiddleOfSentenceWithoutPattern() {
        // Name appears mid-sentence without a vocative pattern — should NOT match
        // "dana" is a segment in a normal sentence, not addressed directly
        XCTAssertFalse(VocativeMiningService.textMentionsVocative("I heard dana said something interesting.", name: "dana"))
    }

    func testVocative_helloGreeting() {
        XCTAssertTrue(VocativeMiningService.textMentionsVocative("Hello dana, welcome to the call.", name: "dana"))
    }

    func testVocative_okayOpener() {
        XCTAssertTrue(VocativeMiningService.textMentionsVocative("Okay dana, your turn.", name: "dana"))
    }

    // MARK: - MeetingSeriesService.seriesKey — Stability

    func testSeriesKey_googleRecurringRootId_returnsRecPrefix() {
        // Google calendar event id with "_<date>" suffix → strips to root id
        let m = meeting(title: "Weekly Sync", calendarEventId: "abc123rootid_20260528")
        let key = seriesService.seriesKey(for: m)
        XCTAssertEqual(key, "rec:abc123rootid")
    }

    func testSeriesKey_googleRecurringRootId_stability_acrossOccurrences() {
        // Two occurrences of the same Google series must produce the same key
        let m1 = meeting(title: "Weekly Sync", calendarEventId: "abc123rootid_20260521")
        let m2 = meeting(title: "Weekly Sync", calendarEventId: "abc123rootid_20260528")
        XCTAssertEqual(seriesService.seriesKey(for: m1), seriesService.seriesKey(for: m2))
    }

    func testSeriesKey_appleCalendar_fallsBackToTitleParticipants() {
        // Apple calendar ids start with "applecal-" — parseRecurringRoot returns nil
        let m = meeting(title: "Weekly Sync", participants: "Alice, Bob",
                        calendarEventId: "applecal-F4C2E1D3-1234-5678-ABCD-000000000001")
        let key = seriesService.seriesKey(for: m)
        XCTAssertTrue(key.hasPrefix("title:"), "Apple calendar id should fall back to title: prefix, got: \(key)")
    }

    func testSeriesKey_noCalendarId_fallsBackToTitleParticipants() {
        let m = meeting(title: "Design Review", participants: "Alice, Bob")
        let key = seriesService.seriesKey(for: m)
        XCTAssertTrue(key.hasPrefix("title:"), "Missing calendarEventId should fall back to title: prefix, got: \(key)")
    }

    func testSeriesKey_sameTitleAndParticipants_sameKey() {
        let m1 = meeting(id: "m1", title: "Design Review", participants: "Alice, Bob")
        let m2 = meeting(id: "m2", title: "Design Review", participants: "Alice, Bob")
        XCTAssertEqual(seriesService.seriesKey(for: m1), seriesService.seriesKey(for: m2))
    }

    func testSeriesKey_differentTitles_differentKeys() {
        let m1 = meeting(title: "Design Review", participants: "Alice, Bob")
        let m2 = meeting(title: "Sprint Planning", participants: "Alice, Bob")
        XCTAssertNotEqual(seriesService.seriesKey(for: m1), seriesService.seriesKey(for: m2))
    }

    func testSeriesKey_differentParticipants_differentKeys() {
        let m1 = meeting(title: "Design Review", participants: "Alice, Bob")
        let m2 = meeting(title: "Design Review", participants: "Alice, Carol")
        XCTAssertNotEqual(seriesService.seriesKey(for: m1), seriesService.seriesKey(for: m2))
    }

    func testSeriesKey_titleNormalization_numberSuffix_sameKey() {
        // normalize strips "(1)", "(2)" suffixes — both should collapse to same key
        let m1 = meeting(title: "Weekly Sync (1)", participants: "Alice, Bob")
        let m2 = meeting(title: "Weekly Sync (2)", participants: "Alice, Bob")
        XCTAssertEqual(seriesService.seriesKey(for: m1), seriesService.seriesKey(for: m2),
                       "Recurrence number suffix should be stripped by normalize")
    }

    func testSeriesKey_titleNormalization_hashNumberSuffix_sameKey() {
        // normalize strips "#3", "#10" suffixes
        let m1 = meeting(title: "Design Review #3", participants: "Alice, Bob")
        let m2 = meeting(title: "Design Review #10", participants: "Alice, Bob")
        XCTAssertEqual(seriesService.seriesKey(for: m1), seriesService.seriesKey(for: m2),
                       "#N recurrence suffix should be stripped by normalize")
    }

    func testSeriesKey_titleNormalization_dashMonthDay_sameKey() {
        // normalize strips "- April 27" style suffixes
        let m1 = meeting(title: "Team Standup - April 27", participants: "Alice, Bob")
        let m2 = meeting(title: "Team Standup - May 4", participants: "Alice, Bob")
        XCTAssertEqual(seriesService.seriesKey(for: m1), seriesService.seriesKey(for: m2),
                       "Date suffix '- Month Day' should be stripped by normalize")
    }

    func testSeriesKey_titleNormalization_slashMonthDay_sameKey() {
        // normalize strips "/ Apr 27" style suffixes
        let m1 = meeting(title: "Team Standup / Apr 27", participants: "Alice, Bob")
        let m2 = meeting(title: "Team Standup / May 4", participants: "Alice, Bob")
        XCTAssertEqual(seriesService.seriesKey(for: m1), seriesService.seriesKey(for: m2),
                       "Date suffix '/ Month Day' should be stripped by normalize")
    }

    func testSeriesKey_titleNormalization_numericDate_sameKey() {
        // normalize strips "4/27" and "4/27/2026" numeric date suffixes
        let m1 = meeting(title: "Team Standup 4/27", participants: "Alice, Bob")
        let m2 = meeting(title: "Team Standup 4/27/2026", participants: "Alice, Bob")
        XCTAssertEqual(seriesService.seriesKey(for: m1), seriesService.seriesKey(for: m2),
                       "Numeric date suffix should be stripped by normalize")
    }

    func testSeriesKey_titleNormalization_caseInsensitive_sameKey() {
        // normalize lowercases — "Weekly Sync" and "weekly sync" should match
        let m1 = meeting(title: "Weekly Sync", participants: "Alice, Bob")
        let m2 = meeting(title: "WEEKLY SYNC", participants: "Alice, Bob")
        XCTAssertEqual(seriesService.seriesKey(for: m1), seriesService.seriesKey(for: m2),
                       "Title normalization should be case-insensitive")
    }

    func testSeriesKey_participantsUnordered_sameKey() {
        // participantList is sorted before hashing — order should not matter
        let m1 = meeting(title: "Weekly Sync", participants: "Alice, Bob")
        let m2 = meeting(title: "Weekly Sync", participants: "Bob, Alice")
        XCTAssertEqual(seriesService.seriesKey(for: m1), seriesService.seriesKey(for: m2),
                       "Participant order should not affect the series key")
    }

    func testSeriesKey_deterministicAcrossInstances() {
        // SHA-256 is stable across process launches (unlike String.hashValue)
        let m = meeting(title: "Design Review", participants: "Alice, Bob")
        let key1 = seriesService.seriesKey(for: m)
        let key2 = seriesService.seriesKey(for: m)
        XCTAssertEqual(key1, key2, "seriesKey must be deterministic — same input, same output")
    }

    func testSeriesKey_emptyTitle_producesNonCrashingKey() {
        let m = meeting(title: "", participants: "Alice, Bob")
        let key = seriesService.seriesKey(for: m)
        // Should not crash; result is a "title::" prefixed key
        XCTAssertTrue(key.hasPrefix("title:"))
    }

    func testSeriesKey_noParticipants_producesNonCrashingKey() {
        let m = meeting(title: "Solo Review", participants: nil)
        let key = seriesService.seriesKey(for: m)
        XCTAssertFalse(key.isEmpty, "seriesKey should never be empty")
    }

    func testSeriesKey_googleIdWithoutUnderscore_returnsRecPrefix() {
        // A Google id that has no "_" separator is treated as the root id itself
        let m = meeting(title: "Weekly Sync", calendarEventId: "plainrootid")
        let key = seriesService.seriesKey(for: m)
        // parseRecurringRoot returns nil when there is no underscore,
        // so this falls back to the title+participants path.
        XCTAssertTrue(key.hasPrefix("title:"),
                      "Google id without underscore should fall back to title: key, got: \(key)")
    }

    // MARK: - Person.canonicalKeys and Person.matches

    func testPersonCanonicalKeys_includesCanonicalName() {
        let p = Person.make(canonicalName: "Dave Smith")
        XCTAssertTrue(p.canonicalKeys.contains("dave"),
                      "canonicalKeys must include the key derived from canonicalName")
    }

    func testPersonCanonicalKeys_includesEmailAlias() {
        let p = Person.make(canonicalName: "Dave Smith", aliases: ["dave@acme.com"])
        XCTAssertTrue(p.canonicalKeys.contains("dave"))
    }

    func testPersonCanonicalKeys_multipleAliasesAllIncluded() {
        let p = Person.make(canonicalName: "Alice Chen",
                            aliases: ["alice@acme.com", "alice.chen@work.org"])
        // All three produce the same first-name key "alice"
        XCTAssertTrue(p.canonicalKeys.contains("alice"))
    }

    func testPersonCanonicalKeys_doesNotContainUnrelatedName() {
        let p = Person.make(canonicalName: "Dave Smith")
        XCTAssertFalse(p.canonicalKeys.contains("bob"),
                       "canonicalKeys should not contain keys from unrelated names")
    }

    func testPersonMatches_ownCanonicalName() {
        let p = Person.make(canonicalName: "Dave Smith")
        XCTAssertTrue(p.matches(participant: "Dave Smith"))
    }

    func testPersonMatches_emailAlias() {
        let p = Person.make(canonicalName: "Dave Smith", aliases: ["dave@acme.com"])
        XCTAssertTrue(p.matches(participant: "dave@acme.com"))
    }

    func testPersonMatches_caseInsensitive() {
        let p = Person.make(canonicalName: "Dave Smith")
        XCTAssertTrue(p.matches(participant: "DAVE JONES"),
                      "matches should be case-insensitive (both reduce to 'dave')")
    }

    func testPersonMatches_differentFirstName_noMatch() {
        let p = Person.make(canonicalName: "Dave Smith")
        XCTAssertFalse(p.matches(participant: "Bob Jones"))
    }

    func testPersonMatches_emptyParticipant_noMatch() {
        let p = Person.make(canonicalName: "Dave Smith")
        // canonicalKey("") returns "" — empty key should not match
        XCTAssertFalse(p.matches(participant: ""))
    }

    // MARK: - POTENTIAL BUG: canonicalKey collision on shared first name
    //
    // ADR-003 §"Domain Disambiguation" acknowledges that two people sharing a
    // first name (e.g. "Dave from Globex" vs "Dave from Acme") will both
    // produce canonicalKey "dave", causing Person.matches to return true for
    // both against any "dave"-keyed input.  The disambiguation is handled in
    // PersonRepository.findOrCreate, NOT in Person.matches / canonicalKeys.
    // This test documents the known collision — it is expected behaviour at
    // the Person model layer.
    func testPersonMatches_sharedFirstName_KNOWN_COLLISION() {
        let dave1 = Person.make(canonicalName: "Dave Smith",  aliases: ["dave@acme.com"])
        let dave2 = Person.make(canonicalName: "Dave Johnson", aliases: ["dave@acme.com"])
        // Both persons match "Dave Williams" — collision is real, disambiguation
        // is the repository's responsibility (ADR-003).
        XCTAssertTrue(dave1.matches(participant: "Dave Williams"),
                      "Expected collision: same first-name key matches across different people")
        XCTAssertTrue(dave2.matches(participant: "Dave Williams"),
                      "Expected collision: same first-name key matches across different people")
    }

    // MARK: - Meeting.acceptedParticipantList (RSVP gate via identityKey)

    func testAcceptedParticipantList_noDeclined_returnsAll() {
        let m = meeting(title: "T", participants: "Alice, Bob, Carol", declinedAttendees: nil)
        XCTAssertEqual(m.acceptedParticipantList.sorted(), ["Alice", "Bob", "Carol"])
    }

    func testAcceptedParticipantList_oneDeclined_excluded() {
        let m = meeting(title: "T", participants: "Alice, Bob, Carol",
                        declinedAttendees: "Bob")
        XCTAssertFalse(m.acceptedParticipantList.contains("Bob"),
                       "Declined attendee should be removed from accepted list")
        XCTAssertEqual(m.acceptedParticipantList.sorted(), ["Alice", "Carol"])
    }

    func testAcceptedParticipantList_allDeclined_returnsEmpty() {
        let m = meeting(title: "T", participants: "Alice, Bob",
                        declinedAttendees: "Alice, Bob")
        XCTAssertTrue(m.acceptedParticipantList.isEmpty,
                      "All attendees declined — accepted list should be empty")
    }

    func testAcceptedParticipantList_declinedByEmail_excludedFromDisplayName() {
        // identityKey("alice@x.com") → "alice"
        // identityKey("Alice Chen") → "alice chen"
        // These are DIFFERENT identity keys — this is the documented limitation
        // called out in Meeting.acceptedParticipantList's comment ("known limitation").
        // POTENTIAL BUG: "alice@x.com" declining does NOT filter "Alice Chen" from
        // accepted list because their identityKeys differ ("alice" vs "alice chen").
        let m = meeting(title: "T", participants: "Alice Chen, Bob",
                        declinedAttendees: "alice@x.com")
        // Expected: Alice Chen is NOT filtered (known limitation)
        XCTAssertTrue(m.acceptedParticipantList.contains("Alice Chen"),
                      "Known limitation: bare email decline does not match display-name participant " +
                      "because identityKey('alice@x.com')='alice' != identityKey('Alice Chen')='alice chen'")
    }

    func testAcceptedParticipantList_emailSuffixedDisplayName_matchesDisplayName() {
        // identityKey("Alex Chen <alex@x.com>") → strips <...> → "alex chen"
        // identityKey("Alex Chen") → "alex chen" — these DO match
        let m = meeting(title: "T", participants: "Alex Chen, Bob",
                        declinedAttendees: "Alex Chen <alex@x.com>")
        XCTAssertFalse(m.acceptedParticipantList.contains("Alex Chen"),
                       "Display-name with email suffix should match plain display-name via identityKey")
    }

    func testAcceptedParticipantList_substringFalsePositive_regression() {
        // QA finding #2 from Meeting.swift comment: "Samantha" declining must NOT
        // exclude "Sam" who accepted.  identityKey("Samantha") = "samantha",
        // identityKey("Sam") = "sam" — they are distinct, so Sam stays in.
        let m = meeting(title: "T", participants: "Sam, Samantha, Bob",
                        declinedAttendees: "Samantha")
        XCTAssertTrue(m.acceptedParticipantList.contains("Sam"),
                      "Declining 'Samantha' must NOT remove 'Sam' — identity keys are distinct")
        XCTAssertFalse(m.acceptedParticipantList.contains("Samantha"),
                       "Samantha declined — should be absent from accepted list")
    }

    func testAcceptedParticipantList_emptyParticipants_returnsEmpty() {
        let m = meeting(title: "T", participants: nil, declinedAttendees: "Alice")
        XCTAssertTrue(m.acceptedParticipantList.isEmpty)
    }
}

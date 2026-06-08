import XCTest
@testable import MeetingManager

/// PRJ-007 TASK-020: persistence + staleness-hash invariants for the enhanced
/// note artifact.
final class EnhancedNoteRepositoryTests: XCTestCase {

    // MARK: - Staleness hash

    func testStableHashIsDeterministicAcrossInvocations() {
        // String.hashValue is salted per process and would differ between
        // launches; SHA256 must produce the same digest every time. This is
        // what makes the "notes changed since enhanced" check trustworthy.
        let notes = "# Pricing\n- push back on $99\n- alice owns followup"
        let a = EnhancedNote.stableHash(notes)
        let b = EnhancedNote.stableHash(notes)
        XCTAssertEqual(a, b, "Hash of identical notes must be stable")
        XCTAssertFalse(a.isEmpty)
        // SHA256 hex is 64 chars — a cheap structural sanity check that we're
        // not accidentally returning the raw string or a truncated value.
        XCTAssertEqual(a.count, 64, "SHA256 hex digest should be 64 characters")
    }

    func testOneCharacterEditChangesHash() {
        let original = "Discussed pricing and timeline."
        let edited = "Discussed pricing and timelines."
        XCTAssertNotEqual(
            EnhancedNote.stableHash(original),
            EnhancedNote.stableHash(edited),
            "A one-character edit must change the staleness hash"
        )
    }

    func testTrailingWhitespaceDoesNotChangeHash() {
        // The hash trims, so adding a trailing newline (which the live editor
        // does constantly) must NOT falsely flag the enhancement as stale.
        XCTAssertEqual(
            EnhancedNote.stableHash("Same notes"),
            EnhancedNote.stableHash("Same notes\n\n  "),
            "Trailing whitespace must not change the staleness hash"
        )
    }

    // MARK: - Repository round-trip

    func testSaveFetchOverwrite() async throws {
        let db = try TestDatabase.create()
        let repo = EnhancedNoteRepository(database: db)
        let meetingId = "m1"

        // Nothing yet.
        let empty = try await repo.enhancedNote(meetingId: meetingId)
        XCTAssertNil(empty)

        // Save.
        let first = EnhancedNote(
            meetingId: meetingId,
            content: "# Pricing\n\nPushed back on the $99 tier because it undercuts margin.",
            modelUsed: "claude-sonnet-4-test",
            generatedAt: SampleData.fixedDate,
            sourceNotesHash: EnhancedNote.stableHash("pricing notes v1"),
            sourceNotesLength: 16
        )
        try await repo.save(first)

        let fetched = try await repo.enhancedNote(meetingId: meetingId)
        XCTAssertEqual(fetched?.content, first.content)
        XCTAssertEqual(fetched?.modelUsed, "claude-sonnet-4-test")
        XCTAssertEqual(fetched?.sourceNotesHash, first.sourceNotesHash)
        XCTAssertEqual(fetched?.sourceNotesLength, 16)

        // Overwrite (re-enhancement) replaces in place — still one row.
        let second = EnhancedNote(
            meetingId: meetingId,
            content: "# Pricing\n\nThe $99 tier was rejected for undercutting margin; Alice owns the follow-up.",
            modelUsed: "ollama/qwen3:8b",
            generatedAt: SampleData.fixedDate.addingTimeInterval(60),
            sourceNotesHash: EnhancedNote.stableHash("pricing notes v2 with alice"),
            sourceNotesLength: 27
        )
        try await repo.save(second)

        let afterOverwrite = try await repo.enhancedNote(meetingId: meetingId)
        XCTAssertEqual(afterOverwrite?.content, second.content, "Re-enhancement must replace the prior content")
        XCTAssertEqual(afterOverwrite?.modelUsed, "ollama/qwen3:8b")
        XCTAssertNotEqual(afterOverwrite?.sourceNotesHash, first.sourceNotesHash,
                          "Overwrite must persist the new source-notes hash")

        let count = try await db.writer.read { dbConn in
            try EnhancedNote.fetchCount(dbConn)
        }
        XCTAssertEqual(count, 1, "Replace-on-write must keep exactly one row per meeting")
    }

    func testDeleteRemovesRow() async throws {
        let db = try TestDatabase.create()
        let repo = EnhancedNoteRepository(database: db)
        let meetingId = "m1"

        try await repo.save(EnhancedNote(
            meetingId: meetingId,
            content: "Polished.",
            modelUsed: nil,
            generatedAt: SampleData.fixedDate,
            sourceNotesHash: EnhancedNote.stableHash("notes"),
            sourceNotesLength: 5
        ))
        try await repo.delete(meetingId: meetingId)
        let after = try await repo.enhancedNote(meetingId: meetingId)
        XCTAssertNil(after, "Delete must remove the row")
    }
}

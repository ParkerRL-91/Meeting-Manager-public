import XCTest
@testable import MeetingManager

/// Regression guard for TASK-019: `DetailedOutlineService.generate` must feed
/// the meeting's user notes into the outline prompt rather than the hardcoded
/// empty string it used previously. If someone re-hardcodes `notes: ""`, the
/// note content stops reaching the prompt and this test fails.
final class DetailedOutlineNotesTests: XCTestCase {

    @MainActor
    func testGenerateInjectsUserNotesIntoPrompt() async throws {
        let db = try TestDatabase.create()

        let meetingId = "m1"
        let meeting = SampleData.makeMeeting(id: meetingId)
        let transcript = SampleData.makeTranscript(
            meetingId: meetingId,
            text: "[00:00] Alice: Let's review the budget."
        )
        // Two notes to also confirm they're combined, not just the first.
        let note1 = SampleData.makeMeetingNote(
            meetingId: meetingId,
            content: "Decided to ship v2 on Friday — owner Alice"
        )
        let note2 = SampleData.makeMeetingNote(
            meetingId: meetingId,
            content: "Open question: does pricing change for EU?"
        )
        try await db.writer.write { dbConn in
            var m = meeting; try m.save(dbConn)
            var t = transcript; try t.save(dbConn)
            var n1 = note1; try n1.save(dbConn)
            var n2 = note2; try n2.save(dbConn)
        }

        // Custom template so the assertion is independent of the shipped
        // default — it proves the service substitutes whatever notes it loaded.
        var settings = AppSettings.default
        settings.detailedOutlinePromptTemplate = "Transcript: {{transcript}}\nNotes: {{notes}}"

        final class Box { var userPrompt = "" }
        let box = Box()

        _ = await DetailedOutlineService.shared.generate(
            meetingId: meetingId,
            meetingRepo: MeetingRepository(database: db),
            cleanedRepo: CleanedTranscriptRepository(database: db),
            transcriptRepo: TranscriptRepository(database: db),
            outlineRepo: DetailedOutlineRepository(database: db),
            noteRepo: NoteRepository(database: db),
            settings: settings,
            textGenerator: { _, userPrompt in
                box.userPrompt = userPrompt
                return "## [00:00 – 01:00] Budget Review\n**Speakers**: Alice\n\nAlice reviewed the budget."
            },
            modelLabel: "test"
        )

        XCTAssertTrue(
            box.userPrompt.contains("Decided to ship v2 on Friday"),
            "Outline prompt must include the user's notes (regression guard against notes: \"\")"
        )
        XCTAssertTrue(
            box.userPrompt.contains("does pricing change for EU?"),
            "All notes for the meeting should be combined into the prompt"
        )
        XCTAssertFalse(box.userPrompt.contains("{{notes}}"), "Notes token should be substituted")
    }
}

import XCTest
@testable import MeetingManager

/// Invariants for the "Enhance Notes" prompt assembly (PRJ-007 TASK-020).
/// These guard the two behaviours that make the artifact correct and safe:
/// it preserves the user's structure (it is NOT a summary), it forbids
/// fabrication, and an absent transcript flips it into a pure polish.
final class EnhanceNotesPromptBuilderTests: XCTestCase {

    private func makeMeeting() -> Meeting {
        SampleData.makeMeeting(
            id: "m1",
            title: "Q3 Pricing Sync",
            startDate: SampleData.fixedDate,
            status: .complete
        )
    }

    private let notes = """
    # Pricing
    - push back on $99, margin
    - alice owns followup
    """

    // MARK: - Structure-preserving + anti-hallucination invariants

    func testSystemPromptIsStructurePreservingNotSummarizing() {
        let prompts = EnhanceNotesPromptBuilder.build(
            template: DefaultPrompts.enhanceNotes,
            meeting: makeMeeting(),
            notes: notes,
            transcript: "Alice: I think $99 undercuts our margin."
        )
        let sys = prompts.system.lowercased()
        XCTAssertTrue(sys.contains("structure"), "System prompt must instruct preserving the user's structure")
        XCTAssertTrue(
            sys.contains("tl;dr") && sys.contains("never reshape") || sys.contains("never") && sys.contains("summary"),
            "System prompt must forbid reshaping into a summary format"
        )
    }

    func testSystemPromptForbidsFabrication() {
        let prompts = EnhanceNotesPromptBuilder.build(
            template: DefaultPrompts.enhanceNotes,
            meeting: makeMeeting(),
            notes: notes,
            transcript: "Alice: I think $99 undercuts our margin."
        )
        let sys = prompts.system.lowercased()
        XCTAssertTrue(sys.contains("invent") || sys.contains("not invent") || sys.contains("never invent"),
                      "System prompt must contain an anti-fabrication rule")
    }

    func testDefaultTemplateDoesNotImposeSummaryHeadings() {
        // The shipped default must NOT instruct the model to emit the fixed
        // summary headings — that's the whole point of a distinct artifact.
        let t = DefaultPrompts.enhanceNotes
        XCTAssertTrue(t.contains("Keep the user's headings"),
                      "Default enhance template must tell the model to keep the user's headings")
        XCTAssertTrue(t.lowercased().contains("do not reshape") || t.lowercased().contains("not reshape the notes"),
                      "Default enhance template must forbid reshaping into a summary")
    }

    // MARK: - Variable substitution

    func testSubstitutesNotesAndTranscriptTokens() {
        let prompts = EnhanceNotesPromptBuilder.build(
            template: "NOTES:\n{{notes}}\nTRANSCRIPT:\n{{transcript}}\nMEETING:{{meetingTitle}}",
            meeting: makeMeeting(),
            notes: notes,
            transcript: "Alice spoke about pricing."
        )
        XCTAssertTrue(prompts.user.contains("push back on $99"), "User prompt must contain the notes")
        XCTAssertTrue(prompts.user.contains("Alice spoke about pricing."), "User prompt must contain the transcript")
        XCTAssertTrue(prompts.user.contains("Q3 Pricing Sync"), "Meeting title token must be substituted")
        XCTAssertFalse(prompts.user.contains("{{notes}}"), "Notes token must be substituted")
        XCTAssertFalse(prompts.user.contains("{{transcript}}"), "Transcript token must be substituted")
    }

    // MARK: - Empty-transcript "polish only" swap

    func testEmptyTranscriptSubstitutesPlaceholderAndPolishOnlySystemPrompt() {
        let prompts = EnhanceNotesPromptBuilder.build(
            template: DefaultPrompts.enhanceNotes,
            meeting: makeMeeting(),
            notes: notes,
            transcript: ""
        )
        XCTAssertTrue(
            prompts.user.contains(EnhanceNotesPromptBuilder.noTranscriptPlaceholder),
            "Absent transcript must substitute the no-transcript placeholder, not leave the token raw"
        )
        XCTAssertFalse(prompts.user.contains("{{transcript}}"), "Transcript token must still be substituted")
        XCTAssertTrue(
            prompts.system.lowercased().contains("no factual additions"),
            "With no transcript the system prompt must switch to polish-only (no factual additions)"
        )
    }

    func testWhitespaceOnlyTranscriptTreatedAsAbsent() {
        let prompts = EnhanceNotesPromptBuilder.build(
            template: DefaultPrompts.enhanceNotes,
            meeting: makeMeeting(),
            notes: notes,
            transcript: "   \n\t  "
        )
        XCTAssertTrue(prompts.user.contains(EnhanceNotesPromptBuilder.noTranscriptPlaceholder),
                      "A whitespace-only transcript must be treated as absent")
        XCTAssertTrue(prompts.system.lowercased().contains("no factual additions"),
                      "A whitespace-only transcript must yield the polish-only system prompt")
    }

    func testPresentTranscriptUsesCorrectionSystemPrompt() {
        let prompts = EnhanceNotesPromptBuilder.build(
            template: DefaultPrompts.enhanceNotes,
            meeting: makeMeeting(),
            notes: notes,
            transcript: "Alice: $99 undercuts margin."
        )
        // The transcript-present branch permits corrections; the polish-only
        // branch must NOT be selected.
        XCTAssertFalse(prompts.system.lowercased().contains("no factual additions"),
                       "With a transcript present the system prompt must allow transcript-sourced corrections")
        XCTAssertTrue(prompts.system.lowercased().contains("correct names"),
                      "With a transcript present the system prompt must mention correcting names/figures")
    }
}

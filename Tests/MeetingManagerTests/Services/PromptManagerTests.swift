import XCTest
@testable import MeetingManager

final class PromptManagerTests: XCTestCase {

    private let manager = PromptManager()

    // MARK: - Substitute Variables

    func testSubstituteVariablesReplacesAllTokens() {
        let template = """
        Meeting: {{meetingTitle}}
        Date: {{date}}
        Duration: {{duration}}
        Transcript: {{transcript}}
        Notes: {{notes}}
        """

        let start = Date(timeIntervalSinceReferenceDate: 700_000_000)
        let end = start.addingTimeInterval(2700) // 45 min
        let meeting = SampleData.makeMeeting(
            title: "Sprint Retro",
            startDate: start,
            endDate: end,
            scheduledStartDate: start
        )

        let result = manager.substituteVariables(
            template: template,
            meeting: meeting,
            transcript: "Alice: Hello\nBob: Hi",
            notes: "Action items discussed"
        )

        XCTAssertTrue(result.contains("Sprint Retro"), "Should contain meeting title")
        XCTAssertFalse(result.contains("{{meetingTitle}}"), "Token should be replaced")
        XCTAssertFalse(result.contains("{{date}}"), "Token should be replaced")
        XCTAssertFalse(result.contains("{{duration}}"), "Token should be replaced")
        XCTAssertTrue(result.contains("Alice: Hello\nBob: Hi"), "Should contain transcript")
        XCTAssertTrue(result.contains("Action items discussed"), "Should contain notes")
    }

    func testSubstituteVariablesWithNoStartDate() {
        let template = "Date: {{date}}"
        let meeting = SampleData.makeMeeting(title: "No Date Meeting")

        let result = manager.substituteVariables(
            template: template,
            meeting: meeting,
            transcript: "",
            notes: ""
        )

        XCTAssertTrue(result.contains("Unknown date"))
    }

    func testSubstituteVariablesUsesScheduledStartAsDate() {
        let template = "Date: {{date}}"
        let scheduled = Date(timeIntervalSinceReferenceDate: 700_000_000)
        let meeting = SampleData.makeMeeting(scheduledStartDate: scheduled)

        let result = manager.substituteVariables(
            template: template,
            meeting: meeting,
            transcript: "",
            notes: ""
        )

        // Should not show "Unknown date" because scheduledStartDate is set
        XCTAssertFalse(result.contains("Unknown date"))
        XCTAssertFalse(result.contains("{{date}}"))
    }

    func testSubstituteVariablesDurationWhenNil() {
        let template = "Duration: {{duration}}"
        let meeting = SampleData.makeMeeting() // No start/end dates

        let result = manager.substituteVariables(
            template: template,
            meeting: meeting,
            transcript: "",
            notes: ""
        )

        XCTAssertTrue(result.contains("--"), "Should show -- for nil duration")
    }

    func testSubstituteVariablesEmptyTranscriptAndNotes() {
        let template = "T: {{transcript}} N: {{notes}}"
        let meeting = SampleData.makeMeeting()

        let result = manager.substituteVariables(
            template: template,
            meeting: meeting,
            transcript: "",
            notes: ""
        )

        XCTAssertEqual(result, "T:  N: ")
    }

    // MARK: - Load Template

    func testLoadTemplateReturnsNonEmpty() {
        let template = manager.loadTemplate()
        XCTAssertFalse(template.isEmpty)
    }

    func testLoadTemplateContainsExpectedPlaceholders() {
        let template = manager.loadTemplate()
        XCTAssertTrue(template.contains("{{meetingTitle}}"))
        XCTAssertTrue(template.contains("{{transcript}}"))
    }

    // MARK: - Available Variables

    func testAvailableVariablesContainsExpectedTokens() {
        let tokens = PromptManager.availableVariables.map(\.token)
        XCTAssertTrue(tokens.contains("{{meetingTitle}}"))
        XCTAssertTrue(tokens.contains("{{date}}"))
        XCTAssertTrue(tokens.contains("{{duration}}"))
        XCTAssertTrue(tokens.contains("{{transcript}}"))
        XCTAssertTrue(tokens.contains("{{notes}}"))
    }

    func testAvailableVariablesHaveDescriptions() {
        for variable in PromptManager.availableVariables {
            XCTAssertFalse(variable.description.isEmpty, "\(variable.token) should have a description")
        }
    }

    // MARK: - Preview Substitution

    func testPreviewSubstitutionReplacesAllTokens() {
        let template = "Title: {{meetingTitle}} | Transcript: {{transcript}} | Notes: {{notes}}"
        let result = manager.previewSubstitution(template: template)

        XCTAssertFalse(result.contains("{{meetingTitle}}"))
        XCTAssertFalse(result.contains("{{transcript}}"))
        XCTAssertFalse(result.contains("{{notes}}"))
        XCTAssertTrue(result.contains("Sprint Planning"))
    }
}

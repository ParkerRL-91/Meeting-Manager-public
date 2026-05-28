import XCTest
@testable import MeetingManager

final class ExportServiceTests: XCTestCase {

    private let service = ExportService()

    // MARK: - Export Summary Markdown

    func testExportSummaryMarkdownIncludesTitle() {
        let meeting = SampleData.makeMeeting(title: "Quarterly Review")
        let summary = SampleData.makeMeetingSummary(summaryText: "We reviewed Q3 results.")

        let result = service.exportSummaryMarkdown(meeting: meeting, summary: summary)

        XCTAssertTrue(result.contains("# Quarterly Review"))
    }

    func testExportSummaryMarkdownIncludesDate() {
        let date = Date(timeIntervalSinceReferenceDate: 700_000_000)
        let meeting = SampleData.makeMeeting(scheduledStartDate: date)
        let summary = SampleData.makeMeetingSummary()

        let result = service.exportSummaryMarkdown(meeting: meeting, summary: summary)

        XCTAssertTrue(result.contains("**Date:**"))
    }

    func testExportSummaryMarkdownIncludesSummaryText() {
        let meeting = SampleData.makeMeeting()
        let summary = SampleData.makeMeetingSummary(summaryText: "Key takeaways from the meeting.")

        let result = service.exportSummaryMarkdown(meeting: meeting, summary: summary)

        XCTAssertTrue(result.contains("Key takeaways from the meeting."))
        XCTAssertTrue(result.contains("## Summary"))
    }

    func testExportSummaryMarkdownIncludesDurationWhenPresent() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let end = start.addingTimeInterval(3600) // 1 hour
        let meeting = SampleData.makeMeeting(startDate: start, endDate: end)
        let summary = SampleData.makeMeetingSummary()

        let result = service.exportSummaryMarkdown(meeting: meeting, summary: summary)

        XCTAssertTrue(result.contains("**Duration:**"))
    }

    func testExportSummaryMarkdownOmitsDurationWhenNil() {
        let meeting = SampleData.makeMeeting()
        let summary = SampleData.makeMeetingSummary()

        let result = service.exportSummaryMarkdown(meeting: meeting, summary: summary)

        XCTAssertFalse(result.contains("**Duration:**"))
    }

    // MARK: - Export Transcript Text

    func testExportTranscriptTextIncludesTimestampsAndSpeakers() {
        let meeting = SampleData.makeMeeting(title: "Team Sync")
        // Use explicit speaker names: "mic"/"system" resolve through
        // displayedSpeakerName to the local user's name / "Them"/"Other", which
        // are machine- and participant-count-dependent. Named labels pass through
        // verbatim (the default case), so the assertions are deterministic.
        let transcripts = [
            SampleData.makeTranscript(speakerLabel: "Alice", text: "Hello team", startTime: 0, endTime: 5),
            SampleData.makeTranscript(speakerLabel: "Bob", text: "Hi there", startTime: 5, endTime: 10),
        ]

        let result = service.exportTranscriptText(meeting: meeting, transcripts: transcripts)

        XCTAssertTrue(result.contains("Team Sync - Transcript"))
        XCTAssertTrue(result.contains("[00:00] Alice: Hello team"))
        XCTAssertTrue(result.contains("[00:05] Bob: Hi there"))
    }

    func testExportTranscriptTextIncludesDateHeader() {
        let meeting = SampleData.makeMeeting()
        let transcripts = [SampleData.makeTranscript()]

        let result = service.exportTranscriptText(meeting: meeting, transcripts: transcripts)

        XCTAssertTrue(result.contains("Date:"))
    }

    // MARK: - Export Full Report

    func testExportFullReportIncludesAllSections() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let end = start.addingTimeInterval(1800)
        let meeting = SampleData.makeMeeting(title: "Full Report Meeting", startDate: start, endDate: end)
        let summary = SampleData.makeMeetingSummary(summaryText: "Summary content here")
        let transcripts = [
            SampleData.makeTranscript(speakerLabel: "Dana", text: "Discussion point", startTime: 0, endTime: 5),
        ]
        let notes = [
            SampleData.makeMeetingNote(content: "Important note"),
        ]

        let result = service.exportFullReport(
            meeting: meeting,
            summary: summary,
            transcripts: transcripts,
            notes: notes
        )

        XCTAssertTrue(result.contains("# Full Report Meeting"))
        XCTAssertTrue(result.contains("## Summary"))
        XCTAssertTrue(result.contains("Summary content here"))
        XCTAssertTrue(result.contains("## Transcript"))
        XCTAssertTrue(result.contains("[00:00] Dana: Discussion point"))
        XCTAssertTrue(result.contains("## Notes"))
        XCTAssertTrue(result.contains("Important note"))
    }

    func testExportFullReportOmitsSummaryWhenNil() {
        let meeting = SampleData.makeMeeting()
        let result = service.exportFullReport(
            meeting: meeting,
            summary: nil,
            transcripts: [],
            notes: []
        )

        XCTAssertFalse(result.contains("## Summary"))
    }

    func testExportFullReportOmitsTranscriptWhenEmpty() {
        let meeting = SampleData.makeMeeting()
        let result = service.exportFullReport(
            meeting: meeting,
            summary: nil,
            transcripts: [],
            notes: [SampleData.makeMeetingNote(content: "Note only")]
        )

        XCTAssertFalse(result.contains("## Transcript"))
        XCTAssertTrue(result.contains("## Notes"))
    }

    func testExportFullReportOmitsNotesWhenEmpty() {
        let meeting = SampleData.makeMeeting()
        let result = service.exportFullReport(
            meeting: meeting,
            summary: nil,
            transcripts: [SampleData.makeTranscript()],
            notes: []
        )

        XCTAssertTrue(result.contains("## Transcript"))
        XCTAssertFalse(result.contains("## Notes"))
    }

    // MARK: - Sanitized Filename

    func testSanitizedFilenameBasic() {
        let result = ExportService.sanitizedFilename(from: "Sprint Planning")
        XCTAssertEqual(result, "sprint-planning")
    }

    func testSanitizedFilenameRemovesSpecialChars() {
        let result = ExportService.sanitizedFilename(from: "Q3 Review: Budget & Forecast!")
        XCTAssertEqual(result, "q3-review-budget--forecast")
    }

    func testSanitizedFilenameEmptyStringFallback() {
        let result = ExportService.sanitizedFilename(from: "!!!@@@###")
        XCTAssertEqual(result, "meeting-export")
    }

    func testSanitizedFilenamePreservesHyphensAndUnderscores() {
        let result = ExportService.sanitizedFilename(from: "my-meeting_notes")
        XCTAssertEqual(result, "my-meeting_notes")
    }

    func testSanitizedFilenameLowercases() {
        let result = ExportService.sanitizedFilename(from: "UPPERCASE TITLE")
        XCTAssertEqual(result, "uppercase-title")
    }
}

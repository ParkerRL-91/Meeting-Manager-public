import Foundation
import GRDB
@testable import MeetingManager

// MARK: - Test Database

enum TestDatabase {
    /// Creates a fresh in-memory database with all migrations applied.
    static func create() throws -> AppDatabase {
        try AppDatabase.empty()
    }
}

// MARK: - Sample Data Factory

enum SampleData {

    static let fixedDate = Date(timeIntervalSinceReferenceDate: 700_000_000) // 2023-03-07

    static func makeMeeting(
        id: String = "meeting-1",
        title: String = "Sprint Planning",
        startDate: Date? = nil,
        endDate: Date? = nil,
        scheduledStartDate: Date? = nil,
        scheduledEndDate: Date? = nil,
        status: MeetingStatus = .scheduled,
        calendarEventId: String? = nil,
        audioFilePaths: [String] = [],
        createdAt: Date = fixedDate,
        updatedAt: Date = fixedDate
    ) -> Meeting {
        Meeting(
            id: id,
            title: title,
            startDate: startDate,
            endDate: endDate,
            scheduledStartDate: scheduledStartDate,
            scheduledEndDate: scheduledEndDate,
            status: status,
            calendarEventId: calendarEventId,
            audioFilePaths: audioFilePaths,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    static func makeTranscript(
        id: Int64? = nil,
        meetingId: String = "meeting-1",
        speakerLabel: String? = "mic",
        text: String = "Hello everyone",
        startTime: Double = 0.0,
        endTime: Double = 5.0,
        confidence: Double? = 0.95,
        createdAt: Date = fixedDate
    ) -> Transcript {
        Transcript(
            id: id,
            meetingId: meetingId,
            speakerLabel: speakerLabel,
            text: text,
            startTime: startTime,
            endTime: endTime,
            confidence: confidence,
            createdAt: createdAt
        )
    }

    static func makeMeetingNote(
        id: Int64? = nil,
        meetingId: String = "meeting-1",
        content: String = "Important point discussed",
        createdAt: Date = fixedDate
    ) -> MeetingNote {
        MeetingNote(
            id: id,
            meetingId: meetingId,
            content: content,
            createdAt: createdAt
        )
    }

    static func makeMeetingSummary(
        id: Int64? = nil,
        meetingId: String = "meeting-1",
        promptUsed: String = "Summarize this meeting",
        summaryText: String = "The team discussed sprint goals and assigned tasks.",
        modelUsed: String? = "claude-sonnet-4-20250514",
        generatedAt: Date = fixedDate,
        isEdited: Bool = false
    ) -> MeetingSummary {
        MeetingSummary(
            id: id,
            meetingId: meetingId,
            promptUsed: promptUsed,
            summaryText: summaryText,
            modelUsed: modelUsed,
            generatedAt: generatedAt,
            isEdited: isEdited
        )
    }

    static func makeActionItem(
        id: Int64? = nil,
        meetingId: String = "meeting-1",
        title: String = "Update the roadmap document",
        assignee: String? = "Alice",
        dueDate: Date? = nil,
        isCompleted: Bool = false,
        extractedAt: Date = fixedDate
    ) -> ActionItem {
        ActionItem(
            id: id,
            meetingId: meetingId,
            title: title,
            assignee: assignee,
            dueDate: dueDate,
            isCompleted: isCompleted,
            extractedAt: extractedAt
        )
    }

    static func makeRecipe(
        id: String = "recipe-1",
        name: String = "Test Recipe",
        description: String = "A test recipe",
        promptTemplate: String = "Summarize: {{transcript}}",
        category: RecipeCategory = .summary,
        isBuiltIn: Bool = false,
        createdAt: Date = fixedDate
    ) -> Recipe {
        Recipe(
            id: id,
            name: name,
            description: description,
            promptTemplate: promptTemplate,
            category: category,
            isBuiltIn: isBuiltIn,
            createdAt: createdAt
        )
    }

    static func makeRecipeResult(
        id: Int64? = nil,
        meetingId: String = "meeting-1",
        recipeId: String = "recipe-1",
        outputText: String = "Generated output from recipe",
        generatedAt: Date = fixedDate
    ) -> RecipeResult {
        RecipeResult(
            id: id,
            meetingId: meetingId,
            recipeId: recipeId,
            outputText: outputText,
            generatedAt: generatedAt
        )
    }

    static func makeChatMessage(
        id: Int64? = nil,
        meetingId: String = "meeting-1",
        role: String = "user",
        content: String = "What were the key decisions?",
        createdAt: Date = fixedDate
    ) -> ChatMessage {
        ChatMessage(
            id: id,
            meetingId: meetingId,
            role: role,
            content: content,
            createdAt: createdAt
        )
    }
}

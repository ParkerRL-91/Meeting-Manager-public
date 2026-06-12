import Foundation
import GRDB

struct MeetingSummary: Identifiable, Codable, Equatable, Hashable {
    var id: Int64?
    var meetingId: String
    var promptUsed: String
    var summaryText: String
    /// TASK-070: the AI's text as it was BEFORE the user's first edit —
    /// (originalText → summaryText) pairs are the style examples injected
    /// into future summary prompts. Set once on the first edit; new
    /// generations start nil.
    var originalText: String? = nil
    var modelUsed: String?
    var generatedAt: Date
    var isEdited: Bool
    /// True when the user had captured notes for this meeting at the moment
    /// the summary was generated, so the summary was anchored to those notes
    /// as ground truth. Persisted at generation time (set `= !noteText.isEmpty`)
    /// rather than re-derived at view time — notes can be edited or deleted
    /// after the summary lands, and the cue should reflect how the summary was
    /// actually produced. Drives the "Shaped by your notes" badge in SummaryView.
    var notesInformedSummary: Bool

    init(
        id: Int64? = nil,
        meetingId: String,
        promptUsed: String,
        summaryText: String,
        modelUsed: String? = nil,
        generatedAt: Date = Date(),
        isEdited: Bool = false,
        notesInformedSummary: Bool = false
    ) {
        self.id = id
        self.meetingId = meetingId
        self.promptUsed = promptUsed
        self.summaryText = summaryText
        self.modelUsed = modelUsed
        self.generatedAt = generatedAt
        self.isEdited = isEdited
        self.notesInformedSummary = notesInformedSummary
    }
}

// MARK: - GRDB

extension MeetingSummary: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "meetingSummary"

    enum Columns: String, ColumnExpression {
        case id, meetingId, promptUsed, summaryText, modelUsed, generatedAt, isEdited, originalText
        case notesInformedSummary
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

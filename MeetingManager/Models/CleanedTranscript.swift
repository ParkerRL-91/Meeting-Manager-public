import Foundation
import GRDB

/// One cleaned-up transcript per meeting. The raw per-segment `transcript`
/// rows are preserved untouched (search, action-item extraction, voice
/// profiles, and re-processing all depend on them). The cleaned version
/// is a single readable blob — stitched into paragraphs, fillers stripped,
/// punctuation added, ready for the user to read or push to the KB.
///
/// `method` tracks how it was produced so we can re-run if the AI pass
/// failed and we want to retry, or downgrade gracefully when an LLM is
/// unavailable.
struct CleanedTranscript: Codable, FetchableRecord, MutablePersistableRecord {
    /// The owning meeting's id. Primary key — exactly one cleaned blob
    /// per meeting; subsequent generations replace.
    var meetingId: String
    /// The cleaned transcript text. Markdown — speaker turns are bold,
    /// timestamps in brackets, paragraph per turn.
    var text: String
    /// When this version was generated.
    var generatedAt: Date
    /// How it was produced: "stitch" (cheap deterministic merge),
    /// "stitch+ai" (stitch then LLM pass), or "ai-failed" (stitch only
    /// because LLM threw — recorded so we can retry later).
    var method: String

    static let databaseTableName = "cleanedTranscript"

    enum Columns {
        static let meetingId   = Column(CodingKeys.meetingId)
        static let text        = Column(CodingKeys.text)
        static let generatedAt = Column(CodingKeys.generatedAt)
        static let method      = Column(CodingKeys.method)
    }
}

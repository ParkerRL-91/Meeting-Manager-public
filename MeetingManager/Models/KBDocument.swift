import Foundation
import GRDB

/// One indexed chunk from a Knowledge Base file. The KB is a user-chosen
/// folder of plain-text-ish documents (`.md`, `.txt`, `.html`, `.docx`) walked
/// recursively. Files are split into chunks (Markdown sections, or
/// paragraph-sized blocks for unstructured text) so retrieval can return just
/// the relevant slice of a long document instead of the whole file.
struct KBDocument: Codable, Identifiable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    /// Absolute path on disk. Source of truth for re-indexing on file change.
    var filePath: String
    /// Display name (last path component).
    var fileName: String
    /// Path relative to the KB root, used for display + scoring boosts.
    var relativePath: String
    /// 0-based index within the file (chunk 0, 1, 2, …).
    var chunkIndex: Int
    /// Optional section heading (the Markdown heading for this chunk, when known).
    var heading: String?
    /// The chunk body text.
    var body: String
    var indexedAt: Date

    static let databaseTableName = "kbDocument"

    enum Columns {
        static let id           = Column(CodingKeys.id)
        static let filePath     = Column(CodingKeys.filePath)
        static let fileName     = Column(CodingKeys.fileName)
        static let relativePath = Column(CodingKeys.relativePath)
        static let chunkIndex   = Column(CodingKeys.chunkIndex)
        static let heading      = Column(CodingKeys.heading)
        static let body         = Column(CodingKeys.body)
        static let indexedAt    = Column(CodingKeys.indexedAt)
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

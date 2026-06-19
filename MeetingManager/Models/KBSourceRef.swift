import Foundation

/// A reference to a Knowledge Base chunk that grounded an AI response. Captured
/// at the single retrieval seam (`KnowledgeBaseService`) and persisted alongside
/// the surface that used it (summary, per-meeting chat) or held in memory
/// (global chat, daily brief) so the UI can show "Context from your Knowledge
/// Base" with click-through to the source document.
///
/// Honest framing: these are the chunks fed to the model as background, NOT a
/// claim the model quoted them.
struct KBSourceRef: Codable, Sendable, Equatable, Identifiable {
    /// Path relative to the KB root — the click-through key + display breadcrumb.
    let relativePath: String
    /// Last path component, stored so a chip never renders blank even if the
    /// file is later moved or deleted.
    let fileName: String
    /// Section heading of the cited chunk, when known (deep-link anchor hint).
    let heading: String?
    /// 0-based chunk index within the file, when known.
    let chunkIndex: Int?
    /// Retrieval score, when available.
    let score: Double?

    init(
        relativePath: String,
        fileName: String,
        heading: String? = nil,
        chunkIndex: Int? = nil,
        score: Double? = nil
    ) {
        self.relativePath = relativePath
        self.fileName = fileName
        self.heading = heading
        self.chunkIndex = chunkIndex
        self.score = score
    }

    /// Stable identity for SwiftUI lists. relativePath + chunkIndex uniquely
    /// identifies a chunk; falls back to relativePath when chunkIndex is nil.
    var id: String {
        chunkIndex.map { "\(relativePath)#\($0)" } ?? relativePath
    }

    /// Build a ref from an indexed chunk.
    init(chunk: KBDocument) {
        self.relativePath = chunk.relativePath
        self.fileName = chunk.fileName
        self.heading = chunk.heading
        self.chunkIndex = chunk.chunkIndex
        self.score = nil
    }
}

import Foundation
import AppKit
import PDFKit
import os

/// Indexes a user-chosen folder (recursive, plain-text-ish formats only) into
/// the SQLite FTS5 index, watches for filesystem changes, and exposes a
/// retrieval API used by meeting prep + chat to inject relevant chunks into
/// LLM context.
///
/// Scope: `.md`, `.txt`, `.html`, `.docx`, plus — since PRJ-010 TASK-068 —
/// `.pdf` (PDFKit text extraction, >20 MB skipped) and `.eml` (minimal
/// RFC-822 parse). Images, archives, and other binary formats stay ignored.
/// (The original text-only scope was the user's explicit ask; the PRJ-010
/// plan they approved widened it to contracts and email threads.)
@MainActor
final class KnowledgeBaseService {
    static let shared = KnowledgeBaseService()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.meetingmanager",
                                category: "KnowledgeBase")

    /// UserDefaults key for the persisted KB folder path.
    private let folderPathKey = "knowledgeBase.rootPath"

    /// Last-indexed timestamp for surfacing in Settings.
    private let lastIndexedKey = "knowledgeBase.lastIndexedAt"

    /// File extensions we'll attempt to index. Anything else is silently
    /// skipped — this matches the user's explicit ask to ignore PDFs/images.
    private let supportedExtensions: Set<String> = ["md", "markdown", "txt", "text", "html", "htm", "docx", "pdf", "eml"]

    /// Soft chunk size — paragraphs longer than this get split. Markdown
    /// section chunks ignore this and stay whole regardless of length, since
    /// breaking them mid-section loses semantic coherence.
    private let maxChunkChars: Int = 2_000

    private let repo = KBDocumentRepository()

    /// In-progress indexing flag. Surfaced to Settings so the UI can show a
    /// progress indicator without spawning a second indexing pass.
    private(set) var isIndexing: Bool = false
    private(set) var lastIndexFileCount: Int = 0
    private(set) var lastIndexChunkCount: Int = 0

    /// FSEvents stream for the configured folder. Cancelled + recreated when
    /// the user changes folders.
    private var watchSource: DispatchSourceFileSystemObject?
    private var watchedFD: Int32 = -1
    private var debounceTask: Task<Void, Never>?

    private init() {}

    // MARK: - Folder selection

    /// Returns the user's currently-configured KB root folder, or nil when
    /// none has been chosen. Resolved fresh from UserDefaults each call so
    /// onboarding + settings agree without explicit refresh.
    var rootURL: URL? {
        guard let path = UserDefaults.standard.string(forKey: folderPathKey),
              !path.isEmpty,
              FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    var lastIndexedAt: Date? {
        UserDefaults.standard.object(forKey: lastIndexedKey) as? Date
    }

    /// Persist a new root folder + kick off an immediate index. The picker
    /// itself lives in the SwiftUI view (NSOpenPanel via NSApp).
    func setRoot(url: URL) async {
        UserDefaults.standard.set(url.path, forKey: folderPathKey)
        AppState.shared?.kbConfigured = true
        startWatching(url: url)
        await enqueueReindex()
    }

    /// Enqueue a KB index task through the TaskQueueManager (preferred call site).
    /// Falls back to direct `reindex()` if the queue is not yet wired up.
    func enqueueReindex() async {
        if let queue = taskQueue {
            await queue.enqueue(
                type: .knowledgeBaseIndex,
                meetingId: "__kb_index__",
                priority: 9,
                metadata: nil
            )
        } else {
            await reindex()
        }
    }

    /// Set by AppState after the queue is initialised.
    weak var taskQueue: TaskQueueManager?

    /// Semantic indexer (TASK-050) — set by AppState. Changed files get
    /// re-embedded alongside the FTS chunks; nil disables silently.
    weak var embedder: EmbeddingService?

    /// Per-file content hashes from this launch's indexing passes: a
    /// watcher event or full reindex skips files whose bytes are unchanged
    /// (review M4 — otherwise every save re-parsed the whole folder and
    /// re-embedded everything).
    private var indexedHashes: [String: String] = [:]

    /// Clear the configured KB and wipe the index.
    func clearRoot() async {
        UserDefaults.standard.removeObject(forKey: folderPathKey)
        UserDefaults.standard.removeObject(forKey: lastIndexedKey)
        AppState.shared?.kbConfigured = false
        stopWatching()
        try? await repo.wipe()
    }

    // MARK: - Browse (viewer/editor support)

    /// A Sendable node in the on-disk KB tree. The viewer/editor treats files
    /// under `rootURL` as the source of truth (the `kbDocument` table holds
    /// search chunks, not whole files), so the browser walks the folder rather
    /// than the index.
    struct KBNode: Sendable, Identifiable, Equatable, Hashable {
        let path: String          // absolute path; stable identity for the tree
        let relativePath: String  // path relative to rootURL (breadcrumb label)
        let name: String          // last path component
        let isDirectory: Bool
        let modifiedAt: Date?
        var children: [KBNode]    // empty for files

        var id: String { path }
    }

    /// Whether a path extension is one the viewer can render or open. Mirrors
    /// `supportedExtensions` plus is reused by the browser to grey out nothing —
    /// unsupported files are simply not surfaced.
    nonisolated static func isSupportedExtension(_ ext: String) -> Bool {
        ["md", "markdown", "txt", "text", "html", "htm", "docx", "pdf", "eml"].contains(ext.lowercased())
    }

    /// Walk `rootURL` off the main actor and return a Sendable tree of folders
    /// and supported files. Hidden entries (leading `.`) and their descendants
    /// are skipped; symlinks are NOT followed (cycle guard). Folders that end up
    /// with no supported descendants are pruned so the browser never shows an
    /// empty branch.
    func documentTree() async -> KBNode? {
        guard let root = rootURL else { return nil }
        return await Task.detached(priority: .userInitiated) {
            Self.buildTreeSync(at: root, root: root)
        }.value
    }

    nonisolated private static func buildTreeSync(at url: URL, root: URL) -> KBNode? {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey, .contentModificationDateKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        if values.isSymbolicLink == true { return nil }          // no symlink-follow
        if url.lastPathComponent.hasPrefix(".") && url != root { return nil }

        let relative = relativePath(of: url, root: root)
        let name = url == root ? url.lastPathComponent : url.lastPathComponent

        if values.isDirectory == true {
            let contents = (try? fm.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )) ?? []
            var children: [KBNode] = []
            for child in contents {
                if let node = buildTreeSync(at: child, root: root) {
                    children.append(node)
                }
            }
            // Prune folders with no supported descendants.
            guard !children.isEmpty || url == root else { return nil }
            children.sort { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory && !rhs.isDirectory }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            return KBNode(path: url.path, relativePath: relative, name: name,
                          isDirectory: true, modifiedAt: values.contentModificationDate,
                          children: children)
        }

        guard isSupportedExtension(url.pathExtension) else { return nil }
        return KBNode(path: url.path, relativePath: relative, name: name,
                      isDirectory: false, modifiedAt: values.contentModificationDate,
                      children: [])
    }

    /// Read a whole text file (`.md`/`.txt`/`.html`) for the detail pane. Returns
    /// nil for unreadable or binary formats (PDF/docx are opened externally).
    func readTextFile(at url: URL) async -> String? {
        await Task.detached(priority: .userInitiated) {
            (try? String(contentsOf: url, encoding: .utf8))
                ?? (try? String(contentsOf: url, encoding: .isoLatin1))
        }.value
    }

    // MARK: - Edit / save (viewer/editor support)

    /// Content hash of a file as it currently sits on disk — the conflict
    /// detector. Same basis as `reindexFile` and the `kbExport` hash
    /// (`EmbeddingService.hash` over raw UTF-8 content). Nil when the file is
    /// gone or unreadable.
    func fileHash(at url: URL) async -> String? {
        await Task.detached(priority: .userInitiated) {
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return EmbeddingService.hash(raw)
        }.value
    }

    /// Outcome of a save attempt. `.conflict` carries the newer on-disk content
    /// so the editor can offer "discard mine and reload" without a second read.
    enum SaveOutcome: Sendable, Equatable {
        case saved
        case conflict(onDiskContent: String)
        case failed(String)
    }

    /// Atomically write `content` to `url`, but only if the file on disk still
    /// matches `expectedHash` (the hash captured when the editor loaded it).
    /// A nil `expectedHash` means "the file did not exist when we loaded"
    /// (create-new path) — a file appearing underneath us is still a conflict.
    ///
    /// On success the just-saved file is re-indexed via the targeted
    /// `reindexFile(url:)`, which records its raw-content hash in
    /// `indexedHashes`; the FSEvents-triggered full `reindex()` then skips it
    /// because that pass now hashes raw content too (no full re-walk reprocess).
    func saveTextFile(at url: URL, expectedHash: String?, content: String) async -> SaveOutcome {
        let currentHash = await fileHash(at: url)
        if currentHash != expectedHash {
            if let onDisk = await readTextFile(at: url) {
                return .conflict(onDiskContent: onDisk)
            }
            // File vanished or unreadable since load — treat as conflict so the
            // user decides rather than silently re-creating it.
            return .conflict(onDiskContent: "")
        }

        do {
            try await Task.detached(priority: .userInitiated) {
                try content.write(to: url, atomically: true, encoding: .utf8)
            }.value
        } catch {
            logger.error("KB save failed for \(url.path, privacy: .public): \(error.localizedDescription)")
            return .failed(error.localizedDescription)
        }

        await reindexFile(url: url)
        return .saved
    }

    /// Force-write `content` to `url` ignoring the conflict check. Used by the
    /// "Keep my changes" branch of the conflict prompt and the create-new path.
    /// Returns the new on-disk hash so the editor can refresh its baseline.
    @discardableResult
    func forceWriteTextFile(at url: URL, content: String) async -> String? {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await Task.detached(priority: .userInitiated) {
                try content.write(to: url, atomically: true, encoding: .utf8)
            }.value
        } catch {
            logger.error("KB force-write failed for \(url.path, privacy: .public): \(error.localizedDescription)")
            return nil
        }
        await reindexFile(url: url)
        return EmbeddingService.hash(content)
    }

    /// Result of a create attempt.
    enum CreateOutcome: Sendable, Equatable {
        case created(URL)
        case alreadyExists
        case outsideRoot
        case failed(String)
    }

    /// Create a new empty `.md` file named `name` inside `directory` (which must
    /// be within the KB root). Returns the created URL so the browser can select
    /// it. The file is seeded with a single H1 from the name so the rendered
    /// view isn't blank.
    func createMarkdownFile(name: String, in directory: URL) async -> CreateOutcome {
        guard let root = rootURL else { return .outsideRoot }
        let standardizedDir = directory.standardizedFileURL.path
        guard standardizedDir == root.standardizedFileURL.path
                || standardizedDir.hasPrefix(root.standardizedFileURL.path + "/") else {
            return .outsideRoot
        }

        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = sanitizeBaseName(trimmed.isEmpty ? "Untitled" : trimmed)
        let fileName = base.lowercased().hasSuffix(".md") ? base : base + ".md"
        let target = directory.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: target.path) { return .alreadyExists }

        let seed = "# \(base.replacingOccurrences(of: ".md", with: ""))\n\n"
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try await Task.detached(priority: .userInitiated) {
                try seed.write(to: target, atomically: true, encoding: .utf8)
            }.value
        } catch {
            logger.error("KB create failed for \(target.path, privacy: .public): \(error.localizedDescription)")
            return .failed(error.localizedDescription)
        }
        await reindexFile(url: target)
        return .created(target)
    }

    /// Delete a KB file (moves it to the Trash so the action is recoverable) and
    /// drop its chunks from the index.
    func deleteFile(at url: URL) async -> Bool {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            logger.error("KB delete failed for \(url.path, privacy: .public): \(error.localizedDescription)")
            return false
        }
        await reindexFile(url: url)   // file is gone → drops chunks + embeddings
        return true
    }

    private func sanitizeBaseName(_ name: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let safe = name
            .components(separatedBy: forbidden)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return safe.isEmpty ? "Untitled" : String(safe.prefix(100))
    }

    // MARK: - Indexing

    /// Walk the folder, parse every supported file, refresh chunks. Removes
    /// stale chunks for files that no longer exist. Idempotent.
    func reindex() async {
        guard let root = rootURL else { return }
        guard !isIndexing else {
            logger.info("Reindex requested while already indexing — skipping")
            return
        }
        isIndexing = true
        defer { isIndexing = false }

        // Report progress through the task queue if this reindex was triggered
        // via the task queue (knowledgeBaseIndex task). Per-file fractions are
        // actually accurate here because we loop over a known file count.
        taskQueue?.reportCurrentProgress(stage: "Scanning folder")

        let urls = enumerateSupportedFiles(root: root)
        logger.info("KB reindex: \(urls.count) supported file(s) found under \(root.path, privacy: .public)")

        taskQueue?.reportCurrentProgress(
            stage: "Parsing \(urls.count) file\(urls.count == 1 ? "" : "s")"
        )

        // Parse all files off the main actor so file I/O doesn't block the UI.
        // KBDocument is a value type (Sendable); URL, Int are also Sendable.
        // We also capture each file's RAW content hash inside the detached loop:
        // the per-file skip-check must hash raw file bytes (same basis as
        // `reindexFile` and the `kbExport` conflict hash), NOT joined chunk
        // bodies — otherwise a just-saved file (skipped via raw hash by the
        // targeted save path) gets re-processed here on the post-save full pass.
        let maxChars = maxChunkChars
        let fileResults: [(path: String, rawHash: String?, chunks: [KBDocument])] = await Task.detached(priority: .utility) {
            var out: [(String, String?, [KBDocument])] = []
            for url in urls {
                if let chunks = try? KnowledgeBaseService.parseFileSync(url: url, rootURL: root, maxChunkChars: maxChars),
                   !chunks.isEmpty {
                    let raw = try? String(contentsOf: url, encoding: .utf8)
                    let rawHash = raw.map { EmbeddingService.hash($0) }
                    out.append((url.path, rawHash, chunks))
                }
            }
            return out
        }.value

        // Persist chunks back on the main actor (GRDB operations).
        var indexedPaths: Set<String> = []
        var totalChunks = 0
        let totalFiles = max(fileResults.count, 1)
        for (idx, (path, rawHash, chunks)) in fileResults.enumerated() {
            do {
                // Binary formats (.pdf/.docx) have no UTF-8 raw hash — fall back
                // to the chunk-body hash so they still skip when unchanged.
                let hash = rawHash ?? EmbeddingService.hash(chunks.map(\.body).joined())
                if indexedHashes[path] == hash { indexedPaths.insert(path); continue }
                indexedHashes[path] = hash
                try await repo.replaceChunks(filePath: path, with: chunks)
                await embedChangedFile(path: path, chunks: chunks)
                indexedPaths.insert(path)
                totalChunks += chunks.count
            } catch {
                logger.error("KB index: failed to save \(path, privacy: .public): \(error.localizedDescription)")
            }
            taskQueue?.reportCurrentProgress(
                stage: "Indexing \(idx + 1)/\(totalFiles)",
                fraction: Double(idx + 1) / Double(totalFiles)
            )
        }

        // Drop chunks for files that have been deleted or moved out of the KB.
        try? await repo.deleteChunksNotIn(filePaths: indexedPaths)

        UserDefaults.standard.set(Date(), forKey: lastIndexedKey)
        lastIndexFileCount = indexedPaths.count
        lastIndexChunkCount = totalChunks
        logger.info("KB reindex complete: \(indexedPaths.count) file(s), \(totalChunks) chunk(s)")
    }

    /// Re-index a single file. Used by FSEvents watcher and KBWriteBackService.
    func reindexFile(url: URL) async {
        guard let root = rootURL else { return }
        guard supportedExtensions.contains(url.pathExtension.lowercased()) else { return }
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                if let raw = try? String(contentsOf: url, encoding: .utf8) {
                    let hash = EmbeddingService.hash(raw)
                    if indexedHashes[url.path] == hash { return }   // unchanged
                    indexedHashes[url.path] = hash
                }
                let chunks = try await chunksForFile(url: url, rootURL: root)
                try await repo.replaceChunks(filePath: url.path, with: chunks)
                await embedChangedFile(path: url.path, chunks: chunks)
            } else {
                indexedHashes[url.path] = nil
                try await repo.replaceChunks(filePath: url.path, with: [])
                try? await EmbeddingRepository(database: .shared)
                    .deleteForSource(sourceType: "kbDoc", sourceId: url.path)
            }
        } catch {
            logger.error("KB single-file reindex failed for \(url.path, privacy: .public): \(error.localizedDescription)")
        }
    }

    /// Re-embed a changed KB file's chunks (TASK-050). Best-effort and
    /// quiet — FTS already covers retrieval when embeddings are missing.
    private func embedChangedFile(path: String, chunks: [KBDocument]) async {
        guard let embedder, embedder.isAvailable else { return }
        let texts = chunks.map { chunk -> String in
            if let h = chunk.heading, !h.isEmpty { return h + "\n" + chunk.body }
            return chunk.body
        }
        try? await embedder.indexKBFile(filePath: path, chunkTexts: texts)
    }

    // MARK: - File enumeration

    private func enumerateSupportedFiles(root: URL) -> [URL] {
        var results: [URL] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isHiddenKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants],
            errorHandler: { [logger] url, error in
                logger.warning("KB enumeration error at \(url.path, privacy: .public): \(error.localizedDescription)")
                return true
            }
        ) else { return [] }

        for case let fileURL as URL in enumerator {
            let name = fileURL.lastPathComponent
            if name.hasPrefix(".") {
                // Only skip descendants for hidden DIRECTORIES (e.g. .git, .obsidian).
                // Calling skipDescendants() on a file (like .DS_Store) incorrectly
                // causes the enumerator to skip the remaining items in the parent
                // directory, which was preventing recursion into subfolders.
                let isDir = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if isDir { enumerator.skipDescendants() }
                continue
            }

            guard let values = try? fileURL.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            guard supportedExtensions.contains(fileURL.pathExtension.lowercased()) else { continue }
            results.append(fileURL)
        }
        return results
    }

    // MARK: - Parsing + chunking

    /// Instance wrapper used by `reindexFile` (single-file path, already async).
    private func chunksForFile(url: URL, rootURL: URL) async throws -> [KBDocument] {
        try Self.parseFileSync(url: url, rootURL: rootURL, maxChunkChars: maxChunkChars)
    }

    /// Static sync version — safe to call from `Task.detached` (no actor capture).
    /// Reads file content synchronously; call only from a non-main-actor context.
    nonisolated private static func parseFileSync(url: URL, rootURL: URL, maxChunkChars: Int) throws -> [KBDocument] {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "md", "markdown":
            let text = try String(contentsOf: url, encoding: .utf8)
            return chunkMarkdown(text: text, fileURL: url, rootURL: rootURL, maxChunkChars: maxChunkChars)
        case "txt", "text":
            let text = try String(contentsOf: url, encoding: .utf8)
            return chunkPlainText(text: text, fileURL: url, rootURL: rootURL, maxChunkChars: maxChunkChars)
        case "html", "htm":
            let data = try Data(contentsOf: url)
            let opts: [NSAttributedString.DocumentReadingOptionKey: Any] = [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue,
            ]
            let attr = try NSAttributedString(data: data, options: opts, documentAttributes: nil)
            return chunkPlainText(text: attr.string, fileURL: url, rootURL: rootURL, maxChunkChars: maxChunkChars)
        case "docx":
            let data = try Data(contentsOf: url)
            let opts: [NSAttributedString.DocumentReadingOptionKey: Any] = [
                .documentType: NSAttributedString.DocumentType.officeOpenXML,
            ]
            let attr = try NSAttributedString(data: data, options: opts, documentAttributes: nil)
            return chunkPlainText(text: attr.string, fileURL: url, rootURL: rootURL, maxChunkChars: maxChunkChars)
        case "pdf":
            // TASK-068: size guard — a 200 MB scan would stall the indexing
            // pass; the plan caps at 20 MB (typical contracts are ≤2 MB).
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= 20 * 1024 * 1024 else { return [] }
            guard let doc = PDFDocument(url: url) else { return [] }
            var pages: [String] = []
            for i in 0..<doc.pageCount {
                if let text = doc.page(at: i)?.string, !text.isEmpty { pages.append(text) }
            }
            let joined = pages.joined(separator: "\n\n")
            guard !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
            return chunkPlainText(text: joined, fileURL: url, rootURL: rootURL, maxChunkChars: maxChunkChars)
        case "eml":
            let raw = (try? String(contentsOf: url, encoding: .utf8))
                ?? (try? String(contentsOf: url, encoding: .isoLatin1))
                ?? ""
            let text = Self.parseEML(raw)
            guard !text.isEmpty else { return [] }
            return chunkPlainText(text: text, fileURL: url, rootURL: rootURL, maxChunkChars: maxChunkChars)
        default:
            return []
        }
    }

    /// TASK-068: minimal RFC-822 parse — the headers people search by
    /// (From/To/Subject/Date) plus the readable body. Multipart messages
    /// keep text parts and drop base64 attachment blobs; quoted-printable
    /// soft line breaks and =XX escapes are decoded. Deliberately not a
    /// full MIME implementation.
    nonisolated static func parseEML(_ raw: String) -> String {
        guard !raw.isEmpty else { return "" }
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        let parts = normalized.components(separatedBy: "\n\n")
        guard let headerBlock = parts.first else { return "" }
        let body = parts.dropFirst().joined(separator: "\n\n")

        // Unfold + pick the headers worth indexing.
        var headers: [String] = []
        var lastKept = false
        for line in headerBlock.components(separatedBy: "\n") {
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                if lastKept, !headers.isEmpty {
                    headers[headers.count - 1] += " " + line.trimmingCharacters(in: .whitespaces)
                }
                continue
            }
            let lower = line.lowercased()
            lastKept = ["from:", "to:", "cc:", "subject:", "date:"].contains { lower.hasPrefix($0) }
            if lastKept { headers.append(line) }
        }

        // Body: drop base64 attachment runs (≥3 consecutive long
        // base64-looking lines) and MIME boundary/header noise.
        var bodyLines: [String] = []
        var base64Run = 0
        for line in body.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let looksBase64 = trimmed.count >= 60
                && trimmed.range(of: "^[A-Za-z0-9+/=]+$", options: .regularExpression) != nil
            if looksBase64 {
                base64Run += 1
                if base64Run >= 3 {
                    if base64Run == 3 { bodyLines.removeLast(2) }
                    continue
                }
            } else {
                base64Run = 0
            }
            if trimmed.hasPrefix("--") && trimmed.count > 10 { continue }   // MIME boundary
            if trimmed.range(of: "^Content-(Type|Transfer-Encoding|Disposition):",
                             options: [.regularExpression, .caseInsensitive]) != nil { continue }
            bodyLines.append(line)
        }
        var bodyText = bodyLines.joined(separator: "\n")
        // Quoted-printable: soft breaks then =XX hex escapes.
        bodyText = bodyText.replacingOccurrences(of: "=\n", with: "")
        if bodyText.contains("=") {
            var decoded = ""
            decoded.reserveCapacity(bodyText.count)
            var i = bodyText.startIndex
            while i < bodyText.endIndex {
                let ch = bodyText[i]
                if ch == "=", let hexEnd = bodyText.index(i, offsetBy: 3, limitedBy: bodyText.endIndex) {
                    let hex = String(bodyText[bodyText.index(after: i)..<hexEnd])
                    if hex.count == 2, let byte = UInt8(hex, radix: 16) {
                        decoded.append(Character(UnicodeScalar(byte)))
                        i = hexEnd
                        continue
                    }
                }
                decoded.append(ch)
                i = bodyText.index(after: i)
            }
            bodyText = decoded
        }
        let combined = (headers.joined(separator: "\n") + "\n\n" + bodyText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return combined
    }

    /// Split Markdown on `# ` / `## ` / `### ` headings. Each section is one
    /// chunk; the heading is captured separately so it can boost FTS scoring.
    /// Sections that are too long get further split on blank lines.
    nonisolated private static func chunkMarkdown(text: String, fileURL: URL, rootURL: URL, maxChunkChars: Int) -> [KBDocument] {
        let relPath = relativePath(of: fileURL, root: rootURL)
        let fileName = fileURL.lastPathComponent
        let now = Date()

        // Strip YAML front-matter (TASK-050): our own exports carry a
        // meetingId/attendees block that would otherwise pollute FTS and
        // embeddings as body text.
        var text = text
        if text.hasPrefix("---\n"),
           let close = text.range(of: "\n---\n", range: text.index(text.startIndex, offsetBy: 4)..<text.endIndex) {
            text = String(text[close.upperBound...])
        }

        var sections: [(heading: String?, body: String)] = []
        var currentHeading: String? = nil
        var currentBody: [String] = []

        func flush() {
            let body = currentBody.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty {
                sections.append((heading: currentHeading, body: body))
            }
            currentBody.removeAll(keepingCapacity: true)
        }

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let m = trimmed.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                flush()
                currentHeading = String(trimmed[m.upperBound...]).trimmingCharacters(in: .whitespaces)
                continue
            }
            currentBody.append(line)
        }
        flush()

        // If the document had no headings, fall back to plain-text chunking.
        if sections.count == 1 && sections.first?.heading == nil {
            return chunkPlainText(text: text, fileURL: fileURL, rootURL: rootURL, maxChunkChars: maxChunkChars)
        }

        var chunks: [KBDocument] = []
        var idx = 0
        for (heading, body) in sections {
            // Long sections still get further split on blank lines.
            for piece in splitIfTooLong(body, maxChunkChars: maxChunkChars) {
                chunks.append(KBDocument(
                    id: nil,
                    filePath: fileURL.path,
                    fileName: fileName,
                    relativePath: relPath,
                    chunkIndex: idx,
                    heading: heading,
                    body: piece,
                    indexedAt: now
                ))
                idx += 1
            }
        }
        return chunks
    }

    /// Plain-text + .txt + extracted HTML/docx all flow through here. Splits
    /// on blank lines and caps chunk size at `maxChunkChars`.
    nonisolated private static func chunkPlainText(text: String, fileURL: URL, rootURL: URL, maxChunkChars: Int) -> [KBDocument] {
        let relPath = relativePath(of: fileURL, root: rootURL)
        let fileName = fileURL.lastPathComponent
        let now = Date()

        let paragraphs = text
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        // Group paragraphs into chunks under maxChunkChars.
        var chunks: [String] = []
        var current: String = ""
        for p in paragraphs {
            if current.isEmpty {
                current = p
            } else if current.count + p.count + 2 <= maxChunkChars {
                current += "\n\n" + p
            } else {
                chunks.append(current)
                current = p
            }
        }
        if !current.isEmpty { chunks.append(current) }

        // Final pass: any single chunk that's *still* too long gets hard-split.
        var expanded: [String] = []
        for c in chunks {
            expanded.append(contentsOf: splitIfTooLong(c, maxChunkChars: maxChunkChars))
        }

        return expanded.enumerated().map { idx, body in
            KBDocument(
                id: nil,
                filePath: fileURL.path,
                fileName: fileName,
                relativePath: relPath,
                chunkIndex: idx,
                heading: nil,
                body: body,
                indexedAt: now
            )
        }
    }

    nonisolated private static func splitIfTooLong(_ s: String, maxChunkChars: Int) -> [String] {
        guard s.count > maxChunkChars else { return [s] }
        var pieces: [String] = []
        var i = s.startIndex
        while i < s.endIndex {
            let end = s.index(i, offsetBy: maxChunkChars, limitedBy: s.endIndex) ?? s.endIndex
            pieces.append(String(s[i..<end]))
            i = end
        }
        return pieces
    }

    nonisolated private static func relativePath(of url: URL, root: URL) -> String {
        let full = url.path
        let prefix = root.path
        if full.hasPrefix(prefix) {
            let trimmed = String(full.dropFirst(prefix.count))
            return trimmed.hasPrefix("/") ? String(trimmed.dropFirst()) : trimmed
        }
        return url.lastPathComponent
    }

    // MARK: - FSEvents watcher

    /// Watch the KB root for changes. Debounced 5s — re-indexes the entire
    /// root after the user stops editing. Per-file targeted re-index would be
    /// more efficient but the indexer is fast enough that whole-folder is
    /// fine for typical KB sizes (≤ a few thousand files).
    func startWatching(url: URL) {
        stopWatching()
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            logger.error("KB watch: failed to open \(url.path, privacy: .public) for events")
            return
        }
        watchedFD = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete, .attrib],
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleDebouncedReindex()
            }
        }
        source.setCancelHandler { [fd] in
            close(fd)
        }
        source.resume()
        watchSource = source
        logger.info("KB watcher started on \(url.path, privacy: .public)")
    }

    func stopWatching() {
        watchSource?.cancel()
        watchSource = nil
        watchedFD = -1
    }

    private func scheduleDebouncedReindex() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            await self?.enqueueReindex()
        }
    }

    // MARK: - Retrieval

    /// Build a retrieval query from a meeting's surrounding context — title,
    /// participant names, latest user notes, and any cached pre-meeting
    /// brief. Returns the formatted Markdown block to inject into the LLM
    /// prompt under a `## Knowledge Base` header. Empty string when the KB
    /// is unconfigured or no chunks match.
    /// The single retrieval seam. Returns the formatted prompt block AND the
    /// structured sources behind it. `promptText` is byte-identical to
    /// `formatChunks(hits)`; the sources are the same chunks, so the UI can show
    /// exactly what the model was given as background. Empty values when the KB
    /// is unconfigured or nothing matches.
    func retrieve(for meeting: Meeting, additionalQuery: String? = nil) async -> (promptText: String, sources: [KBSourceRef]) {
        guard rootURL != nil else { return ("", []) }

        var queryParts: [String] = []
        queryParts.append(meeting.title)
        // Limit to 3 participants — more tokens reduce FTS precision without adding value.
        queryParts.append(contentsOf: meeting.participantList.prefix(3))
        if let extra = additionalQuery, !extra.isEmpty { queryParts.append(extra) }

        let query = queryParts
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return ("", []) }

        let hits = (try? await repo.search(query: query, limit: 5)) ?? []
        return (Self.formatChunks(hits), Self.sourceRefs(hits))
    }

    /// Free-form retrieval — used by GlobalChatView where there is no specific
    /// meeting to anchor the query. Searches across all indexed KB documents.
    func retrieve(query: String) async -> (promptText: String, sources: [KBSourceRef]) {
        guard rootURL != nil, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return ("", []) }
        let hits = (try? await repo.search(query: query, limit: 5)) ?? []
        return (Self.formatChunks(hits), Self.sourceRefs(hits))
    }

    /// For the chat path — query is the user's latest message + the meeting
    /// title to keep the retrieval anchored.
    func retrieve(for meeting: Meeting, chatQuery: String) async -> (promptText: String, sources: [KBSourceRef]) {
        guard rootURL != nil else { return ("", []) }

        let query = (meeting.title + " " + chatQuery)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return ("", []) }

        let hits = (try? await repo.search(query: query, limit: 5)) ?? []
        return (Self.formatChunks(hits), Self.sourceRefs(hits))
    }

    // MARK: - Retrieval (legacy string-only overloads)
    //
    // Kept for callers that only need the prompt block. Delegate to the seam so
    // there is exactly one retrieval path.

    func retrieveContext(for meeting: Meeting, additionalQuery: String? = nil) async -> String {
        await retrieve(for: meeting, additionalQuery: additionalQuery).promptText
    }

    func retrieveContext(query: String) async -> String {
        await retrieve(query: query).promptText
    }

    func retrieveContext(for meeting: Meeting, chatQuery: String) async -> String {
        await retrieve(for: meeting, chatQuery: chatQuery).promptText
    }

    /// Retrieve KB chunks scoped to a single meeting for the daily brief, with
    /// a strict relevance gate. Unlike `retrieveContext`, this returns the raw
    /// chunks (not a formatted blob) so the daily-brief pipeline can assign
    /// stable citation ids and verify quotes against the chunk bodies.
    ///
    /// The gate is deliberately stricter than chat/summary retrieval. The brief
    /// is generated unattended and narrates several meetings in one pass, so a
    /// loosely-matched chunk risks being attributed to the wrong meeting (the
    /// failure ADR-005 was written to kill). FTS5 OR-matches any single token,
    /// which would let a chunk that merely shares a common first name qualify.
    /// We require a chunk to share at least two *distinctive* query terms (or
    /// the one available when the query is that short). Better to show no
    /// background than misleading background — the same stance as
    /// `DailyBriefAIService.cleanPriorExcerpt`.
    func retrieveScopedChunks(for meeting: Meeting, limit: Int = 4) async -> [KBDocument] {
        guard rootURL != nil else { return [] }

        var queryParts: [String] = [meeting.title]
        queryParts.append(contentsOf: meeting.participantList.prefix(3))
        let query = queryParts
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }

        let terms = Self.distinctiveTerms(in: query)
        guard !terms.isEmpty else { return [] }
        let required = terms.count >= 2 ? 2 : 1

        // Over-fetch, then filter by term overlap so the gate has candidates to
        // work with even after dropping weak matches.
        let hits = (try? await repo.search(query: query, limit: max(limit * 3, 8))) ?? []

        var kept: [KBDocument] = []
        var perFile: [String: Int] = [:]
        for hit in hits {
            let haystack = (hit.heading.map { $0 + " " } ?? "") + hit.body
            let overlap = terms.intersection(Self.distinctiveTerms(in: haystack)).count
            guard overlap >= required else { continue }
            // Cap two chunks per file so one document can't dominate a meeting's
            // background.
            let count = perFile[hit.filePath, default: 0]
            guard count < 2 else { continue }
            perFile[hit.filePath] = count + 1
            kept.append(hit)
            if kept.count >= limit { break }
        }
        return kept
    }

    /// Lowercased, de-duplicated set of "distinctive" tokens: alphanumeric runs
    /// of length ≥ 4 that aren't common/meeting-domain stopwords. Backs the
    /// daily-brief relevance gate and the misattribution guard in
    /// `DailyBriefAIService.verify` — a chunk matching only a short or generic
    /// token ("the", "call", a first name) contributes no distinctive term and
    /// therefore can't qualify as real background.
    nonisolated static func distinctiveTerms(in text: String) -> Set<String> {
        let tokens = text.lowercased().split { !$0.isLetter && !$0.isNumber }
        var out: Set<String> = []
        for token in tokens where token.count >= 4 {
            let s = String(token)
            if !stopwords.contains(s) { out.insert(s) }
        }
        return out
    }

    /// Generic + meeting-domain words that carry no disambiguating signal. A
    /// meeting titled "Weekly Standup" yields no distinctive term and so gets
    /// no KB background — exactly the conservative behavior we want for generic
    /// recurring slots.
    private nonisolated static let stopwords: Set<String> = [
        "this", "that", "with", "from", "have", "will", "your", "about", "there",
        "meeting", "meetings", "call", "calls", "sync", "standup", "weekly",
        "daily", "monthly", "biweekly", "update", "updates", "review", "reviews",
        "discussion", "catch", "chat", "intro", "introduction", "team", "teams",
        "notes", "note", "into", "over", "they", "them", "what", "when", "where",
        "which", "while", "would", "could", "should", "been", "being", "than",
        "then", "time", "week", "month", "today", "tomorrow", "google", "meet",
        "zoom", "session", "check", "checkin",
    ]

    /// Format retrieved chunks into a single Markdown block ready for the
    /// LLM. Each chunk is preceded by its source path so the model can cite.
    static func formatChunks(_ chunks: [KBDocument]) -> String {
        guard !chunks.isEmpty else { return "" }
        return chunks.map { c in
            let head = c.heading.map { "**\($0)**\n" } ?? ""
            return "_\(c.relativePath)_\n\(head)\(c.body.trimmingCharacters(in: .whitespacesAndNewlines))"
        }.joined(separator: "\n\n---\n\n")
    }

    /// Map retrieved chunks to citation refs, de-duplicated to one ref per
    /// (relativePath, chunkIndex). These are the same chunks `formatChunks`
    /// emitted, so the UI shows exactly the background the model was given.
    static func sourceRefs(_ chunks: [KBDocument]) -> [KBSourceRef] {
        var seen = Set<String>()
        var out: [KBSourceRef] = []
        for c in chunks {
            let key = "\(c.relativePath)#\(c.chunkIndex)"
            guard seen.insert(key).inserted else { continue }
            out.append(KBSourceRef(chunk: c))
        }
        return out
    }
}

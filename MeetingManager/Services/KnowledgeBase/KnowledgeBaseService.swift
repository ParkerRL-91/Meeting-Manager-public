import Foundation
import AppKit
import os

/// Indexes a user-chosen folder (recursive, plain-text-ish formats only) into
/// the SQLite FTS5 index, watches for filesystem changes, and exposes a
/// retrieval API used by meeting prep + chat to inject relevant chunks into
/// LLM context.
///
/// Scope is intentionally narrow: `.md`, `.txt`, `.html`, `.docx`. Images,
/// PDFs, archives, and binary formats are ignored on purpose — the user was
/// explicit about wanting just text-like documents.
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
    private let supportedExtensions: Set<String> = ["md", "markdown", "txt", "text", "html", "htm", "docx"]

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
        startWatching(url: url)
        await reindex()
    }

    /// Clear the configured KB and wipe the index.
    func clearRoot() async {
        UserDefaults.standard.removeObject(forKey: folderPathKey)
        UserDefaults.standard.removeObject(forKey: lastIndexedKey)
        stopWatching()
        try? await repo.wipe()
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

        let urls = enumerateSupportedFiles(root: root)
        logger.info("KB reindex: \(urls.count) supported file(s) found under \(root.path, privacy: .public)")

        var indexedPaths: Set<String> = []
        var totalChunks = 0
        for url in urls {
            do {
                let chunks = try await chunksForFile(url: url, rootURL: root)
                if !chunks.isEmpty {
                    try await repo.replaceChunks(filePath: url.path, with: chunks)
                    indexedPaths.insert(url.path)
                    totalChunks += chunks.count
                }
            } catch {
                logger.error("KB index: failed for \(url.path, privacy: .public): \(error.localizedDescription)")
            }
        }

        // Drop chunks for files that have been deleted or moved out of the KB.
        try? await repo.deleteChunksNotIn(filePaths: indexedPaths)

        UserDefaults.standard.set(Date(), forKey: lastIndexedKey)
        lastIndexFileCount = indexedPaths.count
        lastIndexChunkCount = totalChunks
        logger.info("KB reindex complete: \(indexedPaths.count) file(s), \(totalChunks) chunk(s)")
    }

    /// Re-index a single file (used by the FSEvents watcher).
    private func reindexFile(url: URL) async {
        guard let root = rootURL else { return }
        guard supportedExtensions.contains(url.pathExtension.lowercased()) else { return }
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                let chunks = try await chunksForFile(url: url, rootURL: root)
                try await repo.replaceChunks(filePath: url.path, with: chunks)
            } else {
                try await repo.replaceChunks(filePath: url.path, with: [])
            }
        } catch {
            logger.error("KB single-file reindex failed for \(url.path, privacy: .public): \(error.localizedDescription)")
        }
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
            // Skip hidden files (.DS_Store, .git, dotfile dirs)
            let name = fileURL.lastPathComponent
            if name.hasPrefix(".") { enumerator.skipDescendants(); continue }

            guard let values = try? fileURL.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            guard supportedExtensions.contains(fileURL.pathExtension.lowercased()) else { continue }
            results.append(fileURL)
        }
        return results
    }

    // MARK: - Parsing + chunking

    /// Reads the file, extracts plain text by format, splits into chunks.
    /// The result is fully-formed `KBDocument` rows ready to insert.
    private func chunksForFile(url: URL, rootURL: URL) async throws -> [KBDocument] {
        let ext = url.pathExtension.lowercased()
        let plainText: String
        switch ext {
        case "md", "markdown":
            plainText = try String(contentsOf: url, encoding: .utf8)
            return chunkMarkdown(text: plainText, fileURL: url, rootURL: rootURL)
        case "txt", "text":
            plainText = try String(contentsOf: url, encoding: .utf8)
            return chunkPlainText(text: plainText, fileURL: url, rootURL: rootURL)
        case "html", "htm":
            plainText = try extractHTML(url: url)
            return chunkPlainText(text: plainText, fileURL: url, rootURL: rootURL)
        case "docx":
            plainText = try extractDocx(url: url)
            return chunkPlainText(text: plainText, fileURL: url, rootURL: rootURL)
        default:
            return []
        }
    }

    /// Use NSAttributedString's HTML reader (available on macOS) to strip
    /// markup and return readable plain text.
    private func extractHTML(url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let opts: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]
        let attr = try NSAttributedString(data: data, options: opts, documentAttributes: nil)
        return attr.string
    }

    /// Same trick for `.docx` — Office Open XML has a built-in reader.
    private func extractDocx(url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let opts: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.officeOpenXML,
        ]
        let attr = try NSAttributedString(data: data, options: opts, documentAttributes: nil)
        return attr.string
    }

    /// Split Markdown on `# ` / `## ` / `### ` headings. Each section is one
    /// chunk; the heading is captured separately so it can boost FTS scoring.
    /// Sections that are too long get further split on blank lines.
    private func chunkMarkdown(text: String, fileURL: URL, rootURL: URL) -> [KBDocument] {
        let relPath = relativePath(of: fileURL, root: rootURL)
        let fileName = fileURL.lastPathComponent
        let now = Date()

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
            return chunkPlainText(text: text, fileURL: fileURL, rootURL: rootURL)
        }

        var chunks: [KBDocument] = []
        var idx = 0
        for (heading, body) in sections {
            // Long sections still get further split on blank lines.
            for piece in splitIfTooLong(body) {
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
    private func chunkPlainText(text: String, fileURL: URL, rootURL: URL) -> [KBDocument] {
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
            expanded.append(contentsOf: splitIfTooLong(c))
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

    private func splitIfTooLong(_ s: String) -> [String] {
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

    private func relativePath(of url: URL, root: URL) -> String {
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
            await self?.reindex()
        }
    }

    // MARK: - Retrieval

    /// Build a retrieval query from a meeting's surrounding context — title,
    /// participant names, latest user notes, and any cached pre-meeting
    /// brief. Returns the formatted Markdown block to inject into the LLM
    /// prompt under a `## Knowledge Base` header. Empty string when the KB
    /// is unconfigured or no chunks match.
    func retrieveContext(for meeting: Meeting, additionalQuery: String? = nil) async -> String {
        guard rootURL != nil else { return "" }

        var queryParts: [String] = []
        queryParts.append(meeting.title)
        queryParts.append(contentsOf: meeting.participantList)
        if let extra = additionalQuery, !extra.isEmpty { queryParts.append(extra) }

        let query = queryParts
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return "" }

        let hits = (try? await repo.search(query: query, limit: 6)) ?? []
        return Self.formatChunks(hits)
    }

    /// For the chat path — query is the user's latest message + the meeting
    /// title to keep the retrieval anchored.
    func retrieveContext(for meeting: Meeting, chatQuery: String) async -> String {
        guard rootURL != nil else { return "" }

        let query = (meeting.title + " " + chatQuery)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return "" }

        let hits = (try? await repo.search(query: query, limit: 5)) ?? []
        return Self.formatChunks(hits)
    }

    /// Format retrieved chunks into a single Markdown block ready for the
    /// LLM. Each chunk is preceded by its source path so the model can cite.
    static func formatChunks(_ chunks: [KBDocument]) -> String {
        guard !chunks.isEmpty else { return "" }
        return chunks.map { c in
            let head = c.heading.map { "**\($0)**\n" } ?? ""
            return "_\(c.relativePath)_\n\(head)\(c.body.trimmingCharacters(in: .whitespacesAndNewlines))"
        }.joined(separator: "\n\n---\n\n")
    }
}

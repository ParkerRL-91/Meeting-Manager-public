import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// File/image attachments for tasks (PRJ-013 Phase 4). Owns the on-disk side of
/// attachments: copying a picked/dropped/pasted file into the canonical
/// per-task directory, generating an optional image thumbnail, deleting files,
/// and the purge that removes orphaned files after the soft-delete window.
///
/// The DB rows live in `TaskAttachmentRepository`; the on-disk locations are its
/// static path helpers. This service is the ONLY place that writes/removes the
/// bytes, so the disk and the rows stay consistent through one owner.
enum TaskAttachmentError: LocalizedError {
    case tooLarge(byteSize: Int64, limit: Int64)
    case copyFailed

    var errorDescription: String? {
        switch self {
        case let .tooLarge(byteSize, limit):
            let f = ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file)
            let l = ByteCountFormatter.string(fromByteCount: limit, countStyle: .file)
            return "That file is \(f), over the \(l) attachment limit."
        case .copyFailed:
            return "The file couldn't be copied into the task."
        }
    }
}

final class TaskAttachmentService {
    /// Max attachment size. Configurable here (the only knob the plan calls for).
    static let maxByteSize: Int64 = 25 * 1024 * 1024 // 25 MB
    private static let thumbnailMaxPixel: CGFloat = 256

    private let repository: TaskAttachmentRepository

    init(repository: TaskAttachmentRepository = TaskAttachmentRepository()) {
        self.repository = repository
    }

    // MARK: - Add

    /// Copies the file at `sourceURL` into the task's attachment directory and
    /// records the row. Throws `TaskAttachmentError.tooLarge` (so the UI can toast)
    /// when the file exceeds the limit — nothing is copied in that case.
    @discardableResult
    func attach(fileURL sourceURL: URL, toTask taskId: Int64) async throws -> TaskAttachment {
        let byteSize = Self.fileSize(of: sourceURL)
        guard byteSize <= Self.maxByteSize else {
            throw TaskAttachmentError.tooLarge(byteSize: byteSize, limit: Self.maxByteSize)
        }
        let ext = sourceURL.pathExtension
        let kind = Self.kind(forExtension: ext)
        let (relativePath, _) = try Self.copyIntoTask(
            taskId: taskId, sourceURL: sourceURL, preferredExtension: ext
        )
        var attachment = TaskAttachment(
            taskId: taskId,
            kind: kind,
            originalName: sourceURL.lastPathComponent,
            relativePath: relativePath,
            byteSize: byteSize
        )
        try await repository.save(&attachment)
        return attachment
    }

    /// Writes pasted/dropped raw image data (no source file) into the task as a
    /// PNG image attachment.
    @discardableResult
    func attach(imageData: Data, originalName: String, toTask taskId: Int64) async throws -> TaskAttachment {
        let byteSize = Int64(imageData.count)
        guard byteSize <= Self.maxByteSize else {
            throw TaskAttachmentError.tooLarge(byteSize: byteSize, limit: Self.maxByteSize)
        }
        let dir = TaskAttachmentRepository.attachmentsDirectory(forTask: taskId)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileName = "\(UUID().uuidString).png"
        let dest = dir.appendingPathComponent(fileName)
        do {
            try imageData.write(to: dest)
        } catch {
            throw TaskAttachmentError.copyFailed
        }
        var attachment = TaskAttachment(
            taskId: taskId,
            kind: .image,
            originalName: originalName,
            relativePath: "TaskAttachments/\(taskId)/\(fileName)",
            byteSize: byteSize
        )
        try await repository.save(&attachment)
        return attachment
    }

    // MARK: - Read

    /// A small thumbnail for an image attachment, or nil for non-images / failures.
    func thumbnail(for attachment: TaskAttachment) -> NSImage? {
        guard attachment.kind == .image else { return nil }
        let url = TaskAttachmentRepository.absoluteURL(forRelativePath: attachment.relativePath)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.thumbnailMaxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cg, size: .zero)
    }

    func revealInFinder(_ attachment: TaskAttachment) {
        let url = TaskAttachmentRepository.absoluteURL(forRelativePath: attachment.relativePath)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Remove

    /// Removes a single attachment's row AND its on-disk file.
    func remove(_ attachment: TaskAttachment) async throws {
        if let id = attachment.id {
            try await repository.delete(id: id)
        }
        let url = TaskAttachmentRepository.absoluteURL(forRelativePath: attachment.relativePath)
        try? FileManager.default.removeItem(at: url)
    }

    /// Purges tasks soft-deleted before `cutoff` and deletes their on-disk
    /// attachment files. The DB cascade removes the rows when the task rows are
    /// hard-deleted; this method removes the bytes those rows referenced. This is
    /// the single wiring point the plan specifies for meeting-driven cleanup.
    func purgeDeletedTasks(
        olderThan cutoff: Date,
        repository taskRepo: TaskRepository = TaskRepository()
    ) async throws {
        let paths = try await taskRepo.purgeDeleted(olderThan: cutoff)
        for path in paths {
            let url = TaskAttachmentRepository.absoluteURL(forRelativePath: path)
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Helpers

    private static func fileSize(of url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    private static func kind(forExtension ext: String) -> TaskAttachmentKind {
        guard let type = UTType(filenameExtension: ext.lowercased()),
              type.conforms(to: .image) else { return .file }
        return .image
    }

    /// Copies `sourceURL` into `…/TaskAttachments/<taskId>/<uuid>.<ext>` and returns
    /// the stored relative path plus the absolute destination.
    private static func copyIntoTask(
        taskId: Int64, sourceURL: URL, preferredExtension ext: String
    ) throws -> (relativePath: String, destination: URL) {
        let dir = TaskAttachmentRepository.attachmentsDirectory(forTask: taskId)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let suffix = ext.isEmpty ? "" : ".\(ext)"
        let fileName = "\(UUID().uuidString)\(suffix)"
        let dest = dir.appendingPathComponent(fileName)
        do {
            try FileManager.default.copyItem(at: sourceURL, to: dest)
        } catch {
            throw TaskAttachmentError.copyFailed
        }
        return ("TaskAttachments/\(taskId)/\(fileName)", dest)
    }
}

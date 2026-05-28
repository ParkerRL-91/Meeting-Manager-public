import Foundation
import os

/// Per-keystroke sidecar-file autosave for meeting notes. Lives next to the
/// SQLite database under `app-support/MeetingManager/note-drafts/<meetingId>.md`.
///
/// Why a separate file when we already write to SQLite?
/// - SQLite saves are debounced (1s) and run inside a Task. A `kill -9` (which
///   `install-local.sh` does on every reinstall) can drop the in-flight save.
/// - `.onDisappear`'s save was fire-and-forget — Tasks die when the view goes
///   away, so the last typed content never made it to disk.
/// - Drafts are plain UTF-8 Markdown files: trivially recoverable by any tool,
///   surveyable in Finder, and never lost to a corrupt sqlite-wal.
///
/// Write strategy:
/// - Atomic write on every change (rename-into-place; no torn files).
/// - Synchronous on the writing thread — caller decides whether to dispatch.
/// - File is `unicode-normalized` and trimmed only on explicit save calls,
///   never silently.
///
/// Lifecycle:
/// - `loadDraft(meetingId:)` returns the file content (or nil).
/// - `saveDraft(meetingId:, content:)` writes the file. Cheap enough to call
///   on every keystroke.
/// - `clearDraft(meetingId:)` deletes the file. Call after a successful DB
///   save so the draft and the canonical record stay in sync.
/// - `recoverableDrafts(noteRepo:)` lists drafts whose content diverges from
///   (or exceeds) the meeting's stored note. It backs a future app-wide
///   "unsaved draft" startup banner. NOTE: that banner is not wired yet — the
///   live recovery today is per-meeting in `NotepadPaneView.loadNote`, which
///   restores the sidecar the moment you reopen the affected meeting.
@MainActor
enum NoteDraftStore {

    private static let fm = FileManager.default

    private static func directory() -> URL {
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MeetingManager", isDirectory: true)
            .appendingPathComponent("note-drafts", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func draftURL(meetingId: String) -> URL {
        // Meeting IDs are UUIDs (path-safe). Adding the .md suffix makes the
        // file openable in any Markdown reader if the user navigates here.
        directory().appendingPathComponent("\(meetingId).md")
    }

    // MARK: - Load / Save

    static func loadDraft(meetingId: String) -> String? {
        let url = draftURL(meetingId: meetingId)
        guard let data = try? Data(contentsOf: url),
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    /// Write the draft atomically. Cheap enough to call from `.onChange` per
    /// keystroke — for any realistic note size the cost is dominated by the
    /// rename syscall, which is microseconds on APFS.
    static func saveDraft(meetingId: String, content: String) {
        let url = draftURL(meetingId: meetingId)
        guard let data = content.data(using: .utf8) else { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            Logger.database.error("NoteDraftStore: failed to write draft \(meetingId, privacy: .public): \(error.localizedDescription)")
        }
    }

    /// Delete the draft. Called after a confirmed SQLite save commit so the
    /// draft doesn't permanently shadow the canonical record.
    static func clearDraft(meetingId: String) {
        let url = draftURL(meetingId: meetingId)
        try? fm.removeItem(at: url)
    }

    static func draftExists(meetingId: String) -> Bool {
        fm.fileExists(atPath: draftURL(meetingId: meetingId).path)
    }

    // MARK: - Recovery

    /// Returns every draft whose content differs from (or is longer than) the
    /// corresponding meeting's stored note, or where no stored note exists.
    /// Intended to back an app-launch "unsaved draft for X" recovery banner.
    /// Not yet wired to any UI — see the type doc comment. The mtime is
    /// returned only for sorting/display; the recover/skip decision is by
    /// content, matching `NotepadPaneView.loadNote`.
    static func recoverableDrafts(noteRepo: NoteRepository) async -> [(meetingId: String, content: String, modifiedAt: Date)] {
        var out: [(String, String, Date)] = []
        let dir = directory()
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return []
        }
        for url in entries where url.pathExtension == "md" {
            let meetingId = url.deletingPathExtension().lastPathComponent
            guard let content = try? String(contentsOf: url, encoding: .utf8), !content.isEmpty else { continue }
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? Date.distantPast

            // Compare against stored note. Recover if no DB note OR draft is
            // longer / strictly newer.
            let stored = try? await noteRepo.latestNote(meetingId: meetingId)
            if let stored {
                if content.count > stored.content.count || content != stored.content {
                    out.append((meetingId, content, mtime))
                }
            } else {
                out.append((meetingId, content, mtime))
            }
        }
        return out.sorted { $0.2 > $1.2 }
    }
}

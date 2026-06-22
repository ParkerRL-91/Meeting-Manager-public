import Foundation
import os

/// Single source of truth for where meeting audio (`.wav`) recordings are
/// written. The app is **not** sandboxed, so a plain path string is enough to
/// retain access to any location the user picks (including TCC-gated
/// Documents/Desktop once the open panel grants access) — no security-scoped
/// bookmark is required. Mirrors `KnowledgeBaseService`'s UserDefaults-backed
/// folder persistence.
///
/// The resolver never lets a recording hard-fail on a bad location: it probes
/// the preferred directory and, if that can't be written, falls back to a
/// guaranteed-writable temp directory while reporting the real error so the UI
/// can prompt the user to fix it.
@MainActor
final class RecordingStorage {
    static let shared = RecordingStorage()

    nonisolated static let customPathKey = "recordingStorage.customPath"
    private let defaults = UserDefaults.standard

    private init() {}

    // MARK: - Persistence

    /// The user-chosen storage directory, or `nil` to use the default.
    var customDirectory: URL? {
        get {
            guard let path = defaults.string(forKey: Self.customPathKey), !path.isEmpty else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        set {
            if let url = newValue {
                defaults.set(url.path, forKey: Self.customPathKey)
            } else {
                defaults.removeObject(forKey: Self.customPathKey)
            }
        }
    }

    /// The location recordings *should* go (configured override, else default),
    /// without any fallback. Used for display and for the writability gate.
    func preferredDirectory() -> URL {
        if let custom = customDirectory { return custom }
        return (try? Self.defaultDirectory()) ?? Self.fallbackDirectory()
    }

    // MARK: - Resolution

    enum Resolution {
        /// Preferred location is writable; use it.
        case ok(URL)
        /// Preferred location failed; using a temp fallback so the recording is
        /// not lost. `original` is what the user expected; `error` is why it failed.
        case fellBack(URL, original: URL, error: Error)
    }

    /// Resolve a directory that is verified writable *right now*, creating it if
    /// needed. Never throws — on failure it routes to the temp fallback so the
    /// session is still captured, and the caller can surface the problem.
    func resolveWritableDirectory() -> Resolution {
        let preferred = preferredDirectory()
        if let error = Self.probe(preferred) {
            Logger.audio.error("Recording storage not writable at \(preferred.path, privacy: .public): \(error.localizedDescription, privacy: .public) — falling back to temp")
            let fallback = Self.fallbackDirectory()
            _ = Self.probe(fallback) // best-effort create
            return .fellBack(fallback, original: preferred, error: error)
        }
        // Default location is owner-only for privacy; never clamp a folder the
        // user explicitly picked (it may be intentionally shared).
        if customDirectory == nil {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: preferred.path)
        }
        return .ok(preferred)
    }

    // MARK: - Probe (pure, callable from any context)

    /// Create `directory` if needed and verify a file can actually be written
    /// and removed there. Returns `nil` on success, or the underlying error.
    /// This is the real test — `createDirectory` succeeding does not prove the
    /// directory is writable (e.g. an existing folder owned by another uid).
    nonisolated static func probe(_ directory: URL) -> Error? {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return error
        }
        let testURL = directory.appendingPathComponent(".mm-write-test-\(UUID().uuidString)")
        do {
            try Data([0]).write(to: testURL, options: .atomic)
            try? fm.removeItem(at: testURL)
            return nil
        } catch {
            return error
        }
    }

    /// Convenience: is the preferred (or a given) directory writable?
    func isPreferredWritable() -> Bool {
        Self.probe(preferredDirectory()) == nil
    }

    // MARK: - Well-known locations

    /// `~/Library/Application Support/MeetingManager/Audio` — the zero-config default.
    nonisolated static func defaultDirectory() throws -> URL {
        try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("MeetingManager/Audio", isDirectory: true)
    }

    /// Last-resort, essentially-always-writable location so a recording is never
    /// lost to a misconfigured destination.
    nonisolated static func fallbackDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingManagerAudio", isDirectory: true)
    }

    /// Every directory that may contain recordings (custom override, if set,
    /// plus the default). Used by crash-recovery to find orphaned WAVs wherever
    /// they were written. `nonisolated` so off-main recovery can call it without
    /// an actor hop; reads UserDefaults directly (thread-safe).
    nonisolated static func knownAudioDirectories() -> [URL] {
        var dirs: [URL] = []
        if let path = UserDefaults.standard.string(forKey: customPathKey), !path.isEmpty {
            dirs.append(URL(fileURLWithPath: path, isDirectory: true))
        }
        if let def = try? defaultDirectory() { dirs.append(def) }
        return dirs
    }
}

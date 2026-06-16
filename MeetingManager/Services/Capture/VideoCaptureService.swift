import Foundation
import GRDB
import ScreenCaptureKit
import os

// MARK: - MeetingVideo (TASK-080, migration v59)

/// One recorded video per meeting. Kept in its own table (not a Meeting
/// column) so retention sweeps and the off-by-default feature stay
/// self-contained. The mixed-audio WAV remains the transcript-sync
/// timeline; this is a parallel artifact aligned to recording start.
struct MeetingVideo: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "meetingVideo"
    var meetingId: String
    var filePath: String
    var createdAt: Date
}

final class MeetingVideoRepository {
    private let database: AppDatabase
    init(database: AppDatabase) { self.database = database }

    func video(meetingId: String) async throws -> MeetingVideo? {
        try await database.writer.read { db in try MeetingVideo.fetchOne(db, key: meetingId) }
    }
    func save(_ v: MeetingVideo) async throws {
        try await database.writer.write { db in try v.save(db) }
    }
    func all() async throws -> [MeetingVideo] {
        try await database.writer.read { db in try MeetingVideo.fetchAll(db) }
    }
    func delete(meetingId: String) async throws {
        _ = try await database.writer.write { db in try MeetingVideo.deleteOne(db, key: meetingId) }
    }
}

// MARK: - Retention (pure, tested)

enum VideoRetention {
    /// Files whose age exceeds `retentionDays` — the sweep deletes these
    /// (video only; transcript/audio are never touched). Pure.
    static func expired(_ entries: [(meetingId: String, createdAt: Date)],
                        retentionDays: Int, now: Date) -> [String] {
        guard retentionDays > 0 else { return [] }
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400)
        return entries.filter { $0.createdAt < cutoff }.map(\.meetingId)
    }
}

// MARK: - Recording-output delegate (macOS 15+)

@available(macOS 15.0, *)
private final class VideoRecordingDelegate: NSObject, SCRecordingOutputDelegate {
    let logger: Logger
    init(logger: Logger) { self.logger = logger }
    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        logger.error("Video recording output failed: \(error.localizedDescription, privacy: .public)")
    }
}

// MARK: - Capture service (off by default, macOS 15+, fail-safe)

/// Optional video capture (TASK-080 / ADR-017). A SEPARATE SCStream from
/// the audio tap, filtered to the call window, written by
/// `SCRecordingOutput`. Created only when `video.captureEnabled` is on AND
/// a recording starts AND a call window resolves. Any failure is swallowed
/// — audio capture is never affected. UNVERIFIED until the TASK-080 gate.
@MainActor
final class VideoCaptureService {
    static let shared = VideoCaptureService()
    private init() {}

    private let logger = Logger(subsystem: "com.meetingmanager.app", category: "VideoCapture")
    private var activeMeetingId: String?

    static var captureEnabled: Bool {
        UserDefaults.standard.bool(forKey: "video.captureEnabled")   // default false
    }
    static var retentionDays: Int {
        let v = UserDefaults.standard.object(forKey: "video.retentionDays") as? Int
        return v ?? 14
    }

    static var videoDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("MeetingManager/video", isDirectory: true)
    }
    static func fileURL(meetingId: String) -> URL {
        videoDir.appendingPathComponent("\(meetingId).mov")
    }

    private var stream: SCStream?
    private var _recordingOutput: AnyObject?
    private var _recordingDelegate: AnyObject?

    /// Begin video capture for a meeting. No-op unless enabled, macOS 15+,
    /// and a call window resolves. Never throws into the caller.
    func start(meetingId: String, database: AppDatabase) async {
        guard Self.captureEnabled, activeMeetingId == nil else { return }
        guard #available(macOS 15.0, *) else {
            logger.info("Video capture requested but unavailable on this macOS (needs 15+)")
            return
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let candidates = content.windows.enumerated().compactMap { idx, win -> SlideCapture.WindowCandidate? in
                guard let app = win.owningApplication else { return nil }
                let area = Double(win.frame.width * win.frame.height)
                guard area >= 200 * 200 else { return nil }
                return SlideCapture.WindowCandidate(index: idx, bundleID: app.bundleIdentifier,
                                                    title: win.title ?? "", area: area)
            }
            guard let pick = SlideCapture.pickWindow(
                candidates,
                isCallApp: { CallAppRegistry.isCallApp(bundleIdentifier: $0) },
                titleLooksLikeCall: { SlideCapture.titleLooksLikeCall($0) },
                isPWA: { SlideCapture.isPWABundle($0) }),
                pick < content.windows.count else {
                logger.info("Video capture: no call window resolved — skipping (audio unaffected)")
                return
            }
            let window = content.windows[pick]

            try FileManager.default.createDirectory(at: Self.videoDir, withIntermediateDirectories: true)
            let url = Self.fileURL(meetingId: meetingId)
            try? FileManager.default.removeItem(at: url)

            let config = SCStreamConfiguration()
            let scale = min(1.0, 1280.0 / max(1.0, window.frame.width))
            config.width = Int(window.frame.width * scale)
            config.height = Int(window.frame.height * scale)
            config.minimumFrameInterval = CMTime(value: 1, timescale: 10) // ~10 fps — plenty for slides
            config.showsCursor = true
            let filter = SCContentFilter(desktopIndependentWindow: window)

            let s = SCStream(filter: filter, configuration: config, delegate: nil)
            let recConfig = SCRecordingOutputConfiguration()
            recConfig.outputURL = url
            recConfig.outputFileType = .mov
            let delegate = VideoRecordingDelegate(logger: logger)
            let output = SCRecordingOutput(configuration: recConfig, delegate: delegate)
            try s.addRecordingOutput(output)
            try await s.startCapture()
            stream = s
            _recordingOutput = output
            _recordingDelegate = delegate
            activeMeetingId = meetingId
            logger.info("Video capture started for \(meetingId, privacy: .public) on '\(window.title ?? "", privacy: .public)'")
        } catch {
            logger.error("Video capture start failed (audio unaffected): \(error.localizedDescription, privacy: .public)")
            stream = nil
            activeMeetingId = nil
        }
    }

    /// Stop capture and persist the MeetingVideo row. Never throws.
    func stop(database: AppDatabase) async {
        guard let meetingId = activeMeetingId, let s = stream else { return }
        activeMeetingId = nil
        stream = nil
        do {
            try await s.stopCapture()
            let url = Self.fileURL(meetingId: meetingId)
            if FileManager.default.fileExists(atPath: url.path) {
                try? await MeetingVideoRepository(database: database)
                    .save(MeetingVideo(meetingId: meetingId, filePath: url.path, createdAt: Date()))
                logger.info("Video capture saved for \(meetingId, privacy: .public)")
            }
        } catch {
            logger.error("Video capture stop error: \(error.localizedDescription, privacy: .public)")
        }
        _recordingOutput = nil
        _recordingDelegate = nil
    }

    /// Governed retention sweep — delete video files past the window and
    /// their rows. Audio/transcript untouched.
    func sweepRetention(database: AppDatabase) async {
        let repo = MeetingVideoRepository(database: database)
        let all = (try? await repo.all()) ?? []
        let expired = VideoRetention.expired(
            all.map { ($0.meetingId, $0.createdAt) },
            retentionDays: Self.retentionDays, now: Date())
        for meetingId in expired {
            try? FileManager.default.removeItem(at: Self.fileURL(meetingId: meetingId))
            try? await repo.delete(meetingId: meetingId)
        }
        if !expired.isEmpty { logger.info("Video retention: removed \(expired.count) file(s)") }
    }
}

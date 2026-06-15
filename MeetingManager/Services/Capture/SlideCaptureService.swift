import Foundation
import GRDB
import ScreenCaptureKit
import Vision
import os

// MARK: - MeetingSlide (TASK-069, migration v55)

/// One captured slide's OCR text. Manual capture only — the user clicks
/// while recording; there is no polling and no always-on capture. Slides
/// are a SEARCH/BROWSE surface: deliberately excluded from chat
/// retrieval so OCR fragments never crowd transcript chunks out of the
/// local model's context (qwen-first decision).
struct MeetingSlide: Codable, FetchableRecord, MutablePersistableRecord, Identifiable {
    static let databaseTableName = "meetingSlide"

    var id: Int64?
    var meetingId: String
    var atSeconds: Double
    var text: String
    var createdAt: Date

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

final class MeetingSlideRepository {
    private let database: AppDatabase
    init(database: AppDatabase) { self.database = database }

    func slides(meetingId: String) async throws -> [MeetingSlide] {
        try await database.writer.read { db in
            try MeetingSlide
                .filter(Column("meetingId") == meetingId)
                .order(Column("atSeconds").asc)
                .fetchAll(db)
        }
    }

    func save(_ slide: MeetingSlide) async throws {
        var copy = slide
        _ = try await database.writer.write { db in try copy.save(db) }
    }

    /// ⌘K keyword hits — one best row per meeting, newest meetings first.
    func search(query: String, limit: Int = 5) async throws -> [MeetingSlide] {
        try await database.writer.read { db in
            try MeetingSlide
                .filter(sql: "text LIKE ?", arguments: ["%\(query)%"])
                .order(Column("createdAt").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }
}

// MARK: - Capture (TASK-069)

enum SlideCapture {

    /// OCR results shorter than this are webcam grids and empty frames,
    /// not slides.
    static let minTextLength = 40

    enum Outcome: Equatable {
        case captured(chars: Int)
        case duplicate
        case noWindow
        case noText
        case failed(String)

        var message: String {
            switch self {
            case .captured(let chars): return "Slide captured (\(chars) chars)"
            case .duplicate: return "Already captured this slide"
            case .noWindow: return "Couldn't identify the call window"
            case .noText: return "No readable text on screen"
            case .failed(let why): return "Capture failed: \(why)"
            }
        }
    }

    struct WindowCandidate {
        let index: Int
        let bundleID: String
        let title: String
        let area: Double
    }

    /// Title substrings that identify a meeting window, regardless of which
    /// app owns it. Reuses the call detector's canonical keyword list and
    /// adds the patterns the Google Meet PWA / standalone app uses for its
    /// window title ("Meet - <name>", various dashes). Lowercased compare.
    static let callTitleKeywords: [String] = (
        CallAppRegistry.browserMeetingKeywords.map { $0.lowercased() }
        + ["google meet", "meet.google.com", "meet - ", "meet – ", "meet — ", "is presenting"]
    )

    static func titleLooksLikeCall(_ title: String) -> Bool {
        let t = title.lowercased()
        return callTitleKeywords.contains { t.contains($0) }
    }

    /// Bundle-ID prefixes for browser-installed web apps (PWAs). The Google
    /// Meet "app" is a Chrome PWA — `com.google.Chrome.app.<hash>` — so it
    /// is neither a registered native call app nor the bare browser bundle.
    static let pwaBundlePrefixes = [
        "com.google.Chrome.app.", "com.microsoft.edgemac.app.",
        "com.brave.Browser.app.", "com.google.Chrome.canary.app.",
    ]

    static func isPWABundle(_ bundleID: String) -> Bool {
        pwaBundlePrefixes.contains { bundleID.hasPrefix($0) }
    }

    /// Pure window choice — fail closed. Tiers, each picking the largest
    /// matching window: (1) a registered native call app (Zoom, Teams);
    /// (2) ANY window whose TITLE looks like a meeting — this is the robust
    /// path that catches the Google Meet PWA, browser tabs, and Electron
    /// apps alike; (3) a browser-installed web-app (PWA) window, since the
    /// Meet app sometimes titles its window just the meeting name. Anything
    /// else (Finder, the user's editor, this app) returns nil and the
    /// capture aborts — we never fall back to whole-display capture.
    static func pickWindow(_ candidates: [WindowCandidate],
                           isCallApp: (String) -> Bool,
                           titleLooksLikeCall: (String) -> Bool,
                           isPWA: (String) -> Bool) -> Int? {
        let byArea: (WindowCandidate, WindowCandidate) -> Bool = { $0.area < $1.area }
        if let best = candidates.filter({ isCallApp($0.bundleID) }).max(by: byArea) { return best.index }
        if let best = candidates.filter({ titleLooksLikeCall($0.title) }).max(by: byArea) { return best.index }
        // Tier 3 only when UNAMBIGUOUS: a single browser-installed web-app
        // window with a real title. Grabbing "the only PWA" is safe; if the
        // user has several PWAs open we refuse rather than guess (fail closed).
        let pwaWindows = candidates.filter { isPWA($0.bundleID) && !$0.title.isEmpty }
        if pwaWindows.count == 1 { return pwaWindows[0].index }
        return nil
    }

    /// Dedupe key: case/whitespace-insensitive text equality.
    static func normalized(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// One full manual capture: resolve window → screenshot → OCR →
    /// gate → dedupe → save. Runs the pixel work off the main actor.
    @MainActor
    static func capture(meetingId: String,
                        recordingStart: Date,
                        database: AppDatabase) async -> Outcome {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            return .failed("screen access unavailable")
        }
        let windows = content.windows
        let candidates = windows.enumerated().compactMap { idx, win -> WindowCandidate? in
            guard let app = win.owningApplication else { return nil }
            let area = Double(win.frame.width * win.frame.height)
            guard area >= 200 * 200 else { return nil }
            return WindowCandidate(index: idx, bundleID: app.bundleIdentifier,
                                   title: win.title ?? "", area: area)
        }
        guard let pick = pickWindow(candidates,
                                    isCallApp: { CallAppRegistry.isCallApp(bundleIdentifier: $0) },
                                    titleLooksLikeCall: { titleLooksLikeCall($0) },
                                    isPWA: { isPWABundle($0) }),
              pick < windows.count else {
            // Log what we DID see so a "can't find the window" report is
            // diagnosable instead of opaque.
            let seen = candidates
                .sorted { $0.area > $1.area }
                .prefix(8)
                .map { "\($0.bundleID)|'\($0.title)'" }
                .joined(separator: "  ")
            Logger(subsystem: "com.meetingmanager.app", category: "SlideCapture")
                .error("SlideCapture noWindow — \(candidates.count) candidate(s): \(seen, privacy: .public)")
            return .noWindow
        }
        let window = windows[pick]

        let config = SCStreamConfiguration()
        let scale = min(1.0, 1400.0 / max(1.0, window.frame.width))
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        config.showsCursor = false
        let filter = SCContentFilter(desktopIndependentWindow: window)

        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            return .failed("couldn't capture the window")
        }

        let atSeconds = max(0, Date().timeIntervalSince(recordingStart))
        let text: String = await Task.detached(priority: .utility) {
            ocrText(from: image)
        }.value
        guard text.count >= minTextLength else { return .noText }

        let repo = MeetingSlideRepository(database: database)
        let existing = (try? await repo.slides(meetingId: meetingId)) ?? []
        let key = normalized(text)
        if existing.contains(where: { normalized($0.text) == key }) { return .duplicate }

        do {
            try await repo.save(MeetingSlide(
                id: nil, meetingId: meetingId, atSeconds: atSeconds,
                text: text, createdAt: Date()))
            return .captured(chars: text.count)
        } catch {
            return .failed("couldn't save")
        }
    }

    nonisolated static func ocrText(from image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image)
        guard (try? handler.perform([request])) != nil,
              let observations = request.results else { return "" }
        return observations
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

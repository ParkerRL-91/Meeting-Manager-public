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

    /// Title keywords that mark a browser window as the call window.
    static let browserCallTitleKeywords = ["meet", "zoom", "teams", "webex", "huddle", "whereby", "gather"]

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

    /// Pure window choice — fail closed. A call-app window wins by
    /// largest area; otherwise a browser window whose title looks like a
    /// call. Anything else (Finder, the user's editor, this app) returns
    /// nil and the capture aborts: we never fall back to display capture.
    static func pickWindow(_ candidates: [WindowCandidate],
                           isCallApp: (String) -> Bool,
                           isBrowser: (String) -> Bool) -> Int? {
        let callWindows = candidates.filter { isCallApp($0.bundleID) }
        if let best = callWindows.max(by: { $0.area < $1.area }) { return best.index }
        let browserCalls = candidates.filter { c in
            guard isBrowser(c.bundleID) else { return false }
            let t = c.title.lowercased()
            return browserCallTitleKeywords.contains { t.contains($0) }
        }
        return browserCalls.max(by: { $0.area < $1.area })?.index
    }

    /// Dedupe key: case/whitespace-insensitive text equality.
    static func normalized(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static let knownBrowserBundleIDs: Set<String> = [
        "com.google.Chrome", "com.apple.Safari", "org.mozilla.firefox",
        "com.microsoft.edgemac", "company.thebrowser.Browser", "com.brave.Browser",
    ]

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
                                    isBrowser: { knownBrowserBundleIDs.contains($0) }),
              pick < windows.count else {
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

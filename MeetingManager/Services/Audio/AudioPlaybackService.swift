import Foundation
import AVFoundation
import os

/// Transcript-synced playback of a completed meeting's audio (TASK-077,
/// PRJ-011). Owns exactly one `AVPlayer` over the meeting's mixed WAV
/// (mic+system, summed at stop onto the transcript's second-based
/// timeline). Multiple `audioFilePaths` (appended/reopened sessions) are
/// stitched into one logical timeline via `AVMutableComposition`, so
/// `currentTime` always matches transcript `startTime`.
///
/// A single shared instance lives on AppState so the transport persists
/// across detail tabs. TASK-078 (clips) reuses `playRange`; TASK-080
/// (video) will extend the same player with a video surface.
@MainActor
@Observable
final class AudioPlaybackService {

    private let logger = Logger(subsystem: "com.meetingmanager.app", category: "Playback")

    private(set) var loadedMeetingId: String?
    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var isAvailable = false
    private(set) var rate: Float = UserDefaults.standard.object(forKey: "playback.rate") as? Float ?? 1.0

    static let rateKey = "playback.rate"
    static let availableRates: [Float] = [0.75, 1.0, 1.25, 1.5, 2.0]

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    /// Range auto-stop boundary (TASK-078 clip playback).
    private var rangeEnd: Double?

    // MARK: - Load

    /// Build a player for the meeting's audio. `isAvailable` is false (and
    /// the transport hides) when there is no readable audio file.
    func load(meetingId: String, audioFilePaths: [String], segments: [Transcript]) {
        if loadedMeetingId == meetingId, player != nil { return }
        unload()
        loadedMeetingId = meetingId

        let existing = audioFilePaths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else {
            isAvailable = false
            logger.info("Playback: no audio file for meeting \(meetingId, privacy: .public)")
            return
        }

        let item: AVPlayerItem
        if existing.count == 1 {
            item = AVPlayerItem(url: URL(fileURLWithPath: existing[0]))
        } else if let composed = Self.composition(for: existing) {
            item = AVPlayerItem(asset: composed)
        } else {
            item = AVPlayerItem(url: URL(fileURLWithPath: existing[0]))
            logger.warning("Playback: composition failed; playing first segment only")
        }
        // Speech-friendly time stretch — rate changes don't pitch-shift.
        item.audioTimePitchAlgorithm = .timeDomain

        let p = AVPlayer(playerItem: item)
        p.actionAtItemEnd = .pause
        player = p
        isAvailable = true
        duration = Self.seconds(item.asset.duration)

        let interval = CMTime(seconds: 0.15, preferredTimescale: 600)
        timeObserver = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] t in
            guard let self else { return }
            self.currentTime = t.seconds.isFinite ? t.seconds : 0
            if let end = self.rangeEnd, self.currentTime >= end {
                self.pause()
                self.rangeEnd = nil
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            // Direct main-queue mutation, matching the sibling periodic
            // observer above (self.currentTime = …). Synchronous with the end
            // event; no Task hop needed.
            self?.isPlaying = false
        }
    }

    func unload() {
        if let player, let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        timeObserver = nil
        endObserver = nil
        player?.pause()
        player = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        isAvailable = false
        rangeEnd = nil
        loadedMeetingId = nil
    }

    // MARK: - Transport

    func play() {
        guard let player, let item = player.currentItem else { return }
        // Once the head parks at the end (actionAtItemEnd == .pause), setting
        // rate is a no-op — rewind first. Use the item's own time, not the
        // published currentTime, which the 0.15s observer can leave a hair
        // short of duration.
        if item.currentTime() >= item.duration {
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            currentTime = 0
        }
        player.rate = rate           // applying rate also resumes playback
        isPlaying = true
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func toggle() { isPlaying ? pause() : play() }

    func seek(to seconds: Double) {
        guard let player else { return }
        rangeEnd = nil
        let clamped = Self.clampSeek(seconds, duration: duration)
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = clamped
    }

    func skip(by delta: Double) { seek(to: currentTime + delta) }

    func setRate(_ newRate: Float) {
        rate = newRate
        UserDefaults.standard.set(newRate, forKey: Self.rateKey)
        if isPlaying { player?.rate = newRate }
    }

    /// Play exactly `[start, end]` and auto-stop at the end — the TASK-078
    /// clip/key-quote primitive.
    func playRange(start: Double, end: Double) {
        guard player != nil, end > start else { return }
        seek(to: start)
        rangeEnd = min(end, duration)
        play()
    }

    // MARK: - Pure helpers (unit-tested)

    /// Binary search: the last segment whose start is ≤ time. nil before the
    /// first segment or when there are none.
    static func activeSegmentIndex(forTime time: Double, sortedStarts: [Double]) -> Int? {
        guard !sortedStarts.isEmpty, time >= sortedStarts[0] else { return nil }
        var lo = 0, hi = sortedStarts.count - 1, ans = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if sortedStarts[mid] <= time { ans = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return ans
    }

    static func clampSeek(_ seconds: Double, duration: Double) -> Double {
        if seconds < 0 { return 0 }
        if duration > 0, seconds > duration { return duration }
        return seconds
    }

    /// Stitch ordered audio files into one timeline. Pure given the asset
    /// durations; the cumulative offset of file i is the sum of 0..<i.
    static func cumulativeOffsets(durations: [Double]) -> [Double] {
        var offsets: [Double] = []
        var running = 0.0
        for d in durations { offsets.append(running); running += d }
        return offsets
    }

    private static func composition(for paths: [String]) -> AVMutableComposition? {
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }
        var cursor = CMTime.zero
        for path in paths {
            let asset = AVURLAsset(url: URL(fileURLWithPath: path))
            guard let src = asset.tracks(withMediaType: .audio).first else { continue }
            let range = CMTimeRange(start: .zero, duration: asset.duration)
            try? track.insertTimeRange(range, of: src, at: cursor)
            cursor = CMTimeAdd(cursor, asset.duration)
        }
        return cursor > .zero ? composition : nil
    }

    private static func seconds(_ t: CMTime) -> Double {
        let s = t.seconds
        return s.isFinite ? s : 0
    }
}

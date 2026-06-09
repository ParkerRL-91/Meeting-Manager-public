import Foundation
import FluidAudio
import AVFoundation
import os

/// On-device speaker diarization backed by FluidAudio (pyannote_segmentation +
/// wespeaker_v2, Apache-2.0, runs on the ANE). This is the alternate diarizer
/// selected when `AppSettings.useFluidAudioDiarization` is on; SpeakerKit
/// remains the default. The two services expose the same shape so AppState can
/// switch between them without changing the downstream attribution pipeline.
///
/// Flow mirrors `SpeakerDiarizationService`:
///   1. `diarize(audioArray:participantCount:)` — loads models lazily, runs
///      FluidAudio's full segmenter → embedder → clustering pipeline.
///   2. `alignToTranscripts(_:result:)` — maps each system Transcript row to the
///      best-overlapping diarization segment, returning transcriptId → "Speaker N".
///
/// Failure at any stage is non-fatal: callers get a thrown error and leave
/// existing labels intact. Unlike SpeakerKit's `Speaker.speakerId` (Int),
/// FluidAudio emits string cluster ids ("1", "2", ...); they're normalized to
/// 1-based Ints in `FluidDiarizationResult` so the downstream "Speaker N"
/// labelling is identical regardless of which engine ran.
/// Not `@MainActor`: FluidAudio's `performCompleteDiarization` is a SYNCHRONOUS,
/// multi-minute CPU/ANE call. Running it on the main actor would freeze the UI
/// for the whole meeting (SpeakerKit's path is async and suspends internally, so
/// it could be @MainActor; this one can't). We mirror `WhisperEngine`: a plain
/// `@unchecked Sendable` class with an `NSLock` guarding the model, and the heavy
/// call dispatched onto a background queue.
final class FluidAudioDiarizationService: @unchecked Sendable {
    static let shared = FluidAudioDiarizationService()

    private let lock = NSLock()
    private var manager: DiarizerManager?          // guarded by `lock`
    private var _modelState: ModelState = .unloaded // guarded by `lock`
    var modelState: ModelState { lock.withLock { _modelState } }

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.meetingmanager",
                                category: "FluidAudioDiarization")

    private init() {}

    // MARK: - Model Management

    enum ModelState: Sendable {
        case unloaded, downloading, loaded, failed
    }

    /// Load (and download if needed) the FluidAudio CoreML models. Safe to call
    /// repeatedly — no-ops once loaded. Wrapped in a 5-minute timeout race
    /// because the HuggingFace download can hang on a bad network or corrupt
    /// cache, matching the SpeakerKit/WhisperKit pattern.
    func loadModels() async throws {
        guard lock.withLock({ _modelState != .loaded }) else { return }

        try Self.ensureDiskSpaceForDownload()

        lock.withLock { _modelState = .downloading }
        logger.info("Loading FluidAudio diarization models...")

        do {
            let models = try await withThrowingTaskGroup(of: DiarizerModels.self) { group in
                group.addTask {
                    try await DiarizerModels.downloadIfNeeded()
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(300))
                    throw DiarizationError.modelLoadTimeout
                }
                let loaded = try await group.next()!
                group.cancelAll()
                return loaded
            }

            // Auto-clustering (numClusters = -1, the default). Unlike SpeakerKit's
            // Pyannote path — which treats a speaker-count hint as an EXACT count
            // and over-/under-splits when wrong — FluidAudio's clusterer finds the
            // speaker count itself. Auto-clustering is precisely what fixes the
            // collapse the count-hint heuristics were working around, so we let it
            // decide rather than forcing a possibly-wrong K.
            let mgr = DiarizerManager(config: .default)
            mgr.initialize(models: models)
            lock.withLock {
                self.manager = mgr
                self._modelState = .loaded
            }
            logger.info("FluidAudio diarization models ready.")
        } catch {
            lock.withLock { _modelState = .failed }
            logger.error("FluidAudio model load failed: \(error.localizedDescription)")
            throw error
        }
    }

    /// Prewarm the models on a background-priority task without blocking the
    /// caller. Used at app idle so the first real diarization isn't gated on a
    /// cold download/compile.
    func prewarm() {
        guard lock.withLock({ _modelState == .unloaded }) else { return }
        Task(priority: .utility) { [weak self] in
            try? await self?.loadModels()
        }
    }

    /// Best-effort: skips when a diarization run holds the lock — `diarize`
    /// holds it for the full multi-minute run, and the idle-unload caller is
    /// on the MainActor, which must never block on it.
    func unloadModels() {
        guard lock.try() else { return }
        defer { lock.unlock() }
        manager?.cleanup()
        manager = nil
        _modelState = .unloaded
    }

    /// FluidAudio downloads pyannote_segmentation + wespeaker_v2 (~100 MB
    /// combined) into the diarizer model directory on first use. Preflight the
    /// download with headroom for the snapshot's temporary files and CoreML's
    /// on-device compile, mirroring `TranscriptionService.ensureDiskSpaceForDownload`.
    private static func ensureDiskSpaceForDownload() throws {
        // Skip the check entirely once the models are cached on disk.
        let modelDir = DiarizerModels.defaultModelsDirectory()
        if FileManager.default.fileExists(atPath: modelDir.path),
           let contents = try? FileManager.default.contentsOfDirectory(atPath: modelDir.path),
           !contents.isEmpty {
            return
        }

        let requiredBytes: Int64 = 600 * 1024 * 1024 // ~100 MB models + temp + compile headroom
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
              let freeBytes = attrs[.systemFreeSize] as? Int64 else {
            return // Can't read free space — don't block; the download surfaces any real failure.
        }
        if freeBytes < requiredBytes {
            let freeMB = freeBytes / (1024 * 1024)
            throw DiarizationError.insufficientDiskSpace(freeMB: freeMB)
        }
    }

    // MARK: - Diarization

    /// Diarize a system-audio (or mixed) WAV file.
    ///
    /// - Parameter enrolledSpeakers: Phase 2 cross-meeting identity. Known voices
    ///   (built by `SpeakerEnrollmentService` from prior confirmed segments) seeded
    ///   into the clusterer so matching clusters come back tagged with the enrolled
    ///   `Speaker.id` (= `Person.id`) instead of a fresh numeric cluster.
    func diarize(
        systemAudioURL: URL,
        participantCount: Int?,
        enrolledSpeakers: [Speaker] = []
    ) async throws -> FluidDiarizationResult {
        guard FileManager.default.fileExists(atPath: systemAudioURL.path) else {
            throw DiarizationError.audioFileNotFound(systemAudioURL.path)
        }
        let samples = try loadAsSamples(url: systemAudioURL)
        logger.info("FluidAudio diarizing \(systemAudioURL.lastPathComponent), speakers hint: \(participantCount.map(String.init) ?? "auto"), enrolled: \(enrolledSpeakers.count)")
        return try await diarize(audioArray: samples, participantCount: participantCount, enrolledSpeakers: enrolledSpeakers)
    }

    /// Diarize an already-loaded 16 kHz mono Float32 sample buffer.
    ///
    /// - Parameter participantCount: advisory speaker-count hint. FluidAudio's
    ///   clusterer determines the count itself (auto-clustering), so the hint is
    ///   logged for diagnostics but not forced — forcing K is the SpeakerKit
    ///   footgun this engine swap is meant to remove.
    func diarize(
        audioArray: [Float],
        participantCount: Int?,
        enrolledSpeakers: [Speaker] = []
    ) async throws -> FluidDiarizationResult {
        guard !audioArray.isEmpty else {
            throw DiarizationError.emptyAudio
        }

        if lock.withLock({ _modelState != .loaded }) {
            try await loadModels()
        }

        // FluidAudio's performCompleteDiarization is synchronous and runs for
        // minutes on a long meeting. Dispatch it to a background queue so it
        // never blocks the main thread / cooperative pool. The NSLock serializes
        // access to the shared manager (one diarization at a time).
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<FluidDiarizationResult, Error>) in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                lock.lock()
                defer { lock.unlock() }
                guard let manager else {
                    cont.resume(throwing: DiarizationError.modelNotLoaded)
                    return
                }
                do {
                    // Seed cross-meeting voice identity, then FULLY clear it for
                    // the next call. mode:.reset with preserveIfPermanent:false
                    // wipes ALL prior known speakers — including the permanent
                    // enrolled voices from an earlier meeting — so a person
                    // enrolled for one meeting can't keep matching in later
                    // meetings they aren't in. Within THIS meeting the enrolled
                    // speakers stay permanent (set by SpeakerEnrollmentService),
                    // protecting them from mid-meeting pruning/merging.
                    manager.speakerManager.initializeKnownSpeakers(
                        enrolledSpeakers, mode: .reset, preserveIfPermanent: false
                    )
                    let result = try manager.performCompleteDiarization(audioArray, sampleRate: 16000)
                    let mapped = FluidDiarizationResult(result)
                    logger.info("FluidAudio diarization complete: \(mapped.speakerCount) speakers, \(mapped.segments.count) segments")
                    cont.resume(returning: mapped)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Alignment

    /// Map system transcript rows to diarization segments by time overlap.
    /// Returns `[transcriptId: "Speaker N"]` for rows with ≥25% overlap; rows
    /// with no confident match are omitted so callers keep their existing label.
    func alignToTranscripts(
        _ transcripts: [Transcript],
        result: FluidDiarizationResult
    ) -> [Int64: String] {
        var mapping: [Int64: String] = [:]

        for transcript in transcripts {
            // Legacy "system" bucket plus anonymous "Speaker N"/"Speaker" rows
            // are re-alignable; resolved names and "mic" are never re-labelled.
            let label = (transcript.speakerLabel ?? "").lowercased().trimmingCharacters(in: .whitespaces)
            guard let id = transcript.id,
                  label == "system" || label == "speaker" || label.hasPrefix("speaker ") else { continue }

            let txStart = Float(transcript.startTime)
            let txEnd   = Float(transcript.endTime)
            let txLen   = txEnd - txStart
            guard txLen > 0 else { continue }

            var bestSpeaker: Int? = nil
            var bestOverlap: Float = 0
            for segment in result.segments {
                let overlapStart = max(txStart, segment.startTime)
                let overlapEnd   = min(txEnd,   segment.endTime)
                let overlap      = max(0, overlapEnd - overlapStart)
                if overlap > bestOverlap {
                    bestOverlap = overlap
                    bestSpeaker = segment.speakerId
                }
            }

            guard let sid = bestSpeaker, bestOverlap / txLen >= 0.25 else { continue }
            mapping[id] = "Speaker \(sid)"
        }

        return mapping
    }

    // MARK: - Private

    /// Read a 16kHz mono Float32 WAV into a plain [Float] array.
    private func loadAsSamples(url: URL) throws -> [Float] {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!

        let file = try AVAudioFile(forReading: url)
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else {
            return []
        }
        try file.read(into: buffer)

        guard let channelData = buffer.floatChannelData else { return [] }
        _ = format
        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))
    }
}

// MARK: - Result Shape

/// Engine-neutral diarization result mirroring the slice of SpeakerKit's
/// `DiarizationResult` that AppState consumes. FluidAudio's string cluster ids
/// are normalized to stable 1-based Ints so "Speaker N" labelling is identical
/// to the SpeakerKit path.
struct FluidDiarizationResult: Sendable {
    struct Segment: Sendable {
        let speakerId: Int        // 1-based, matches the "Speaker N" convention
        /// The raw FluidAudio cluster id. For a newly-discovered cluster this is
        /// an arbitrary string ("1", "2", ...). When a known speaker was enrolled
        /// (Phase 2) and this segment matched it, FluidAudio returns the enrolled
        /// `Speaker.id` here — which `SpeakerEnrollmentService` sets to the
        /// `Person.id`. This is how an enrolled cluster is mapped back to a name.
        let rawSpeakerId: String
        let startTime: Float
        let endTime: Float
        let qualityScore: Float
        /// 256-dim wespeaker embedding for this segment. Used to (re)build a
        /// person's `VoiceReference` from their highest-confidence segments.
        let embedding: [Float]
    }

    let segments: [Segment]
    let speakerCount: Int

    init(_ result: DiarizationResult) {
        // FluidAudio cluster ids are arbitrary strings ("1", "2", "spk0", ...),
        // OR an enrolled Speaker.id when known speakers were seeded. Map each
        // distinct id to a deterministic 1-based Int (in first-appearance order)
        // for the engine-neutral "Speaker N" labelling, but keep the raw id so
        // enrollment matches can be resolved back to a Person.
        var idForCluster: [String: Int] = [:]
        var next = 1
        var segs: [Segment] = []
        for s in result.segments {
            let mapped: Int
            if let existing = idForCluster[s.speakerId] {
                mapped = existing
            } else {
                mapped = next
                idForCluster[s.speakerId] = next
                next += 1
            }
            segs.append(Segment(
                speakerId: mapped,
                rawSpeakerId: s.speakerId,
                startTime: s.startTimeSeconds,
                endTime: s.endTimeSeconds,
                qualityScore: s.qualityScore,
                embedding: s.embedding
            ))
        }
        self.segments = segs
        self.speakerCount = idForCluster.count
    }
}

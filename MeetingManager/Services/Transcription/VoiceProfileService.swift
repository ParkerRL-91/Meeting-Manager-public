import Foundation
import Accelerate
import AVFoundation
import SpeakerKit
import os

/// Builds and matches per-person voice fingerprints using 40-band mel-spectrum
/// features averaged over the speaker's confirmed audio segments.
///
/// ## Why mel-spectrum rather than full MFCC
/// Full MFCC adds a DCT decorrelation step that helps with ASR tasks but is
/// unnecessary here — we're comparing whole-speaker averages, not frame-level
/// patterns. Mel-spectrum gives similar speaker-discriminative power with ~30%
/// less compute and simpler code.
///
/// ## Cross-meeting learning
/// After each meeting where speakers are identified (via LLM or manual rename):
///   1. `extractEmbedding(for:from:segments:)` computes a 40-dim fingerprint
///      from that speaker's audio.
///   2. `VoiceProfileRepository.merge()` blends it into the stored profile
///      using a 0.3-α EMA so recent meetings progressively refine the model.
///
/// Before LLM attribution runs:
///   1. `matchProfiles(clusters:audioURL:diarizationResult:stored:)` computes
///      fingerprints for each speaker cluster in the new meeting.
///   2. Clusters with cosine similarity ≥ 0.82 against a stored profile are
///      pre-assigned to that person — the LLM never needs to guess.
@MainActor
final class VoiceProfileService {
    static let shared = VoiceProfileService()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.meetingmanager",
                                category: "VoiceProfile")

    private let sampleRate: Double = 16_000
    private let frameSize: Int    = 512        // ~32ms at 16kHz
    private let hopSize: Int      = 256        // ~16ms overlap
    private let numMelBands: Int  = 40
    private let minHz: Float      = 80
    private let maxHz: Float      = 7_600
    private let matchThreshold: Float = 0.82  // cosine similarity required for a confident match
    private let minSegmentSeconds: Float = 3.0 // ignore very short segments

    private init() {}

    // MARK: - Embedding extraction

    /// Extract a 40-dim mel-spectrum embedding from the speaker segments of an audio file.
    /// - Parameters:
    ///   - speakerLabel: "Speaker 0", "Speaker 1", etc.
    ///   - audioURL: Path to the system-audio WAV (16kHz mono Float32).
    ///   - diarizationResult: Segment timing from SpeakerKit.
    /// - Returns: Normalised 40-dim embedding, or nil if there's not enough audio.
    func extractEmbedding(
        forSpeaker speakerLabel: String,
        from audioURL: URL,
        diarizationResult: DiarizationResultBox
    ) async -> [Float]? {
        guard let speakerId = parseSpeakerId(from: speakerLabel) else { return nil }
        guard let allSamples = loadSamples(from: audioURL) else { return nil }

        // Collect audio windows for this speaker.
        let segments = diarizationResult.segments.filter {
            $0.speaker.speakerId == speakerId &&
            ($0.endTime - $0.startTime) >= minSegmentSeconds
        }
        guard !segments.isEmpty else { return nil }

        // Use the longest segments up to 60s total to keep compute bounded.
        var collected: [Float] = []
        let sorted = segments.sorted { ($0.endTime - $0.startTime) > ($1.endTime - $1.startTime) }
        for seg in sorted {
            let start  = Int(seg.startTime * Float(sampleRate))
            let end    = min(Int(seg.endTime * Float(sampleRate)), allSamples.count)
            guard start < end, end <= allSamples.count else { continue }
            collected.append(contentsOf: allSamples[start..<end])
            if Double(collected.count) / sampleRate >= 60 { break }
        }
        guard collected.count >= frameSize else { return nil }

        return melSpectrumEmbedding(samples: collected)
    }

    /// Time-range variant of `extractEmbedding` — builds a fingerprint directly
    /// from `(start, end)` second pairs, no DiarizationResult required. Used by
    /// callers that have transcript rows (which already carry start/end times)
    /// but no live SpeakerKit result — e.g. retroactive scans, manual rename
    /// learning, or rebuilding the profile DB from history.
    ///
    /// Mirrors the diarization-result path: takes up to 60s of the longest
    /// segments, runs the mel-spectrum pipeline, returns an L2-normalised
    /// 40-dim embedding.
    func extractEmbedding(
        audioURL: URL,
        timeRanges: [(start: Float, end: Float)]
    ) async -> [Float]? {
        guard let allSamples = loadSamples(from: audioURL) else { return nil }

        let qualifying = timeRanges.filter { ($0.end - $0.start) >= minSegmentSeconds }
        guard !qualifying.isEmpty else { return nil }

        var collected: [Float] = []
        let sorted = qualifying.sorted { ($0.end - $0.start) > ($1.end - $1.start) }
        for r in sorted {
            let start = Int(r.start * Float(sampleRate))
            let end   = min(Int(r.end * Float(sampleRate)), allSamples.count)
            guard start < end, end <= allSamples.count else { continue }
            collected.append(contentsOf: allSamples[start..<end])
            if Double(collected.count) / sampleRate >= 60 { break }
        }
        guard collected.count >= frameSize else { return nil }
        return melSpectrumEmbedding(samples: collected)
    }

    /// Match per-cluster pre-computed time ranges against stored profiles.
    /// Returns `[clusterLabel: personName]` for high-confidence matches.
    /// Used by `applySpeakerAttribution` to skip the LLM for voices the
    /// profile DB already recognises, even when no live DiarizationResult
    /// is available (e.g. retro-scan, re-attribution).
    func matchProfiles(
        audioURL: URL,
        clusterRanges: [String: [(start: Float, end: Float)]],
        stored: [VoiceProfile]
    ) async -> [String: String] {
        let result = await matchProfilesWithConfidence(
            audioURL: audioURL,
            clusterRanges: clusterRanges,
            stored: stored
        )
        return result.mapping
    }

    /// v3.10 — same as `matchProfiles` but also returns the cosine similarity
    /// for each match, used by callers as a confidence score. Per-profile
    /// dynamic threshold is applied (LLM-only profiles need higher similarity).
    func matchProfilesWithConfidence(
        audioURL: URL,
        clusterRanges: [String: [(start: Float, end: Float)]],
        stored: [VoiceProfile]
    ) async -> (mapping: [String: String], confidence: [String: Float]) {
        guard !stored.isEmpty, !clusterRanges.isEmpty else { return ([:], [:]) }
        var matches: [String: String] = [:]
        var confidences: [String: Float] = [:]
        for (label, ranges) in clusterRanges {
            guard let newEmb = await extractEmbedding(audioURL: audioURL, timeRanges: ranges) else { continue }
            var bestName: String? = nil
            var bestSim: Float = 0
            var bestProfile: VoiceProfile? = nil
            for profile in stored {
                let storedEmb = profile.embedding
                guard storedEmb.count == newEmb.count else { continue }
                let sim = cosineSimilarity(newEmb, storedEmb)
                // Per-profile threshold gate: must exceed the profile's own
                // dynamic threshold AND be the best match seen so far.
                if sim >= profile.dynamicMatchThreshold && sim > bestSim {
                    bestSim = sim
                    bestName = profile.personName
                    bestProfile = profile
                }
            }
            if let name = bestName {
                matches[label] = name
                confidences[label] = bestSim
                let thr = bestProfile?.dynamicMatchThreshold ?? matchThreshold
                logger.info("Voice match (range): \(label) → \(name) (sim \(String(format: "%.3f", bestSim)), thr \(String(format: "%.2f", thr)))")
            }
        }
        return (matches, confidences)
    }

    // MARK: - Profile matching

    /// Compare new-meeting clusters against stored voice profiles.
    /// Returns a `[speakerLabel: personName]` dictionary for high-confidence matches.
    func matchProfiles(
        clusters: [String],
        audioURL: URL,
        diarizationResult: DiarizationResultBox,
        stored: [VoiceProfile]
    ) async -> [String: String] {
        guard !stored.isEmpty, !clusters.isEmpty else { return [:] }
        guard let allSamples = loadSamples(from: audioURL) else { return [:] }

        var matches: [String: String] = [:]

        for label in clusters {
            guard let speakerId = parseSpeakerId(from: label) else { continue }

            let segments = diarizationResult.segments.filter {
                $0.speaker.speakerId == speakerId &&
                ($0.endTime - $0.startTime) >= minSegmentSeconds
            }
            guard !segments.isEmpty else { continue }

            var collected: [Float] = []
            let sortedSegs = segments.sorted { ($0.endTime - $0.startTime) > ($1.endTime - $1.startTime) }
            for seg in sortedSegs {
                let start = Int(seg.startTime * Float(sampleRate))
                let end   = min(Int(seg.endTime * Float(sampleRate)), allSamples.count)
                guard start < end else { continue }
                collected.append(contentsOf: allSamples[start..<end])
                if Double(collected.count) / sampleRate >= 30 { break }
            }
            guard collected.count >= frameSize,
                  let newEmb = melSpectrumEmbedding(samples: collected) else { continue }

            // Find the stored profile with highest cosine similarity.
            var bestName: String? = nil
            var bestSim: Float = matchThreshold  // must exceed threshold

            for profile in stored {
                let storedEmb = profile.embedding
                guard storedEmb.count == newEmb.count else { continue }
                let sim = cosineSimilarity(newEmb, storedEmb)
                if sim > bestSim {
                    bestSim = sim
                    bestName = profile.personName
                }
            }

            if let name = bestName {
                matches[label] = name
                logger.info("Voice match: \(label) → \(name) (similarity \(String(format: "%.3f", bestSim)))")
            }
        }

        return matches
    }

    // MARK: - MFCC / mel-spectrum internals

    /// Compute a 40-dim mel-spectrum embedding from raw PCM samples.
    /// Each frame is FFT'd, mel filterbank applied, log-compressed, then
    /// all frames are averaged into a single fixed-length vector.
    private func melSpectrumEmbedding(samples: [Float]) -> [Float]? {
        let filterbank = melFilterbank()
        var accumulator = [Float](repeating: 0, count: numMelBands)
        var frameCount = 0

        var i = 0
        while i + frameSize <= samples.count {
            let frame = Array(samples[i..<(i + frameSize)])
            if let melFrame = melFrame(frame, filterbank: filterbank) {
                for b in 0..<numMelBands { accumulator[b] += melFrame[b] }
                frameCount += 1
            }
            i += hopSize
        }
        guard frameCount > 0 else { return nil }

        // Average over frames
        var embedding = accumulator.map { $0 / Float(frameCount) }

        // L2-normalise so cosine similarity == dot product
        var sumSq: Float = 0
        vDSP_svesq(&embedding, 1, &sumSq, vDSP_Length(embedding.count))
        let norm = sqrt(sumSq)
        guard norm > 1e-8 else { return nil }
        var scale = 1 / norm
        vDSP_vsmul(embedding, 1, &scale, &embedding, 1, vDSP_Length(embedding.count))

        return embedding
    }

    /// Compute one windowed FFT frame and project onto the mel filterbank.
    private func melFrame(_ frame: [Float], filterbank: [[Float]]) -> [Float]? {
        var windowed = frame
        // Apply Hann window
        var window = [Float](repeating: 0, count: frame.count)
        vDSP_hann_window(&window, vDSP_Length(frame.count), Int32(vDSP_HANN_NORM))
        vDSP_vmul(windowed, 1, window, 1, &windowed, 1, vDSP_Length(frame.count))

        // Real FFT
        let log2n = vDSP_Length(log2(Double(frameSize)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        defer { vDSP_destroy_fftsetup(setup) }

        var realPart = windowed
        var imagPart = [Float](repeating: 0, count: frameSize)
        var splitComplex = DSPSplitComplex(
            realp: &realPart,
            imagp: &imagPart
        )

        realPart.withUnsafeMutableBytes { realBytes in
            windowed.withUnsafeBytes { srcBytes in
                guard let realBase = realBytes.baseAddress,
                      let srcBase  = srcBytes.baseAddress else { return }
                realBase.copyMemory(from: srcBase, byteCount: frameSize * MemoryLayout<Float>.size)
            }
        }

        vDSP_fft_zrip(setup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))

        // Power spectrum
        var magnitudes = [Float](repeating: 0, count: frameSize / 2)
        vDSP_zvmags(&splitComplex, 1, &magnitudes, 1, vDSP_Length(frameSize / 2))

        // Apply mel filterbank
        return filterbank.map { filter in
            var energy: Float = 0
            vDSP_dotpr(magnitudes, 1, filter, 1, &energy, vDSP_Length(min(magnitudes.count, filter.count)))
            return log(max(energy, 1e-10))  // log-compress
        }
    }

    /// Build 40 triangular mel filterbank filters covering minHz–maxHz.
    private func melFilterbank() -> [[Float]] {
        let numBins = frameSize / 2
        let nyquist = Float(sampleRate / 2)

        func hzToMel(_ hz: Float) -> Float { 2595 * log10(1 + hz / 700) }
        func melToHz(_ mel: Float) -> Float { 700 * (pow(10, mel / 2595) - 1) }

        let melMin = hzToMel(minHz)
        let melMax = hzToMel(maxHz)
        let melPoints = (0...(numMelBands + 1)).map { i in
            melToHz(melMin + Float(i) * (melMax - melMin) / Float(numMelBands + 1))
        }

        // Convert mel centre frequencies to FFT bin indices
        let binPoints = melPoints.map { hz in
            Int(((hz / nyquist) * Float(numBins)).rounded())
                .clamped(to: 0...numBins - 1)
        }

        var filterbank: [[Float]] = []
        for m in 1...numMelBands {
            var filter = [Float](repeating: 0, count: numBins)
            let left   = binPoints[m - 1]
            let centre = binPoints[m]
            let right  = binPoints[m + 1]

            for k in left..<centre where centre > left {
                filter[k] = Float(k - left) / Float(centre - left)
            }
            for k in centre..<right where right > centre {
                filter[k] = Float(right - k) / Float(right - centre)
            }
            filterbank.append(filter)
        }
        return filterbank
    }

    // MARK: - Utilities

    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        var dot: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        return dot  // both vectors are L2-normalised, so dot == cosine similarity
    }

    private func loadSamples(from url: URL) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              (try? file.read(into: buffer)) != nil,
              let data = buffer.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
    }

    private func parseSpeakerId(from label: String) -> Int? {
        let parts = label.split(separator: " ")
        guard parts.count == 2, parts[0] == "Speaker" else { return nil }
        return Int(parts[1])
    }
}

// MARK: - DiarizationResultBox

/// Sendable wrapper around DiarizationResult so VoiceProfileService (MainActor)
/// can hold it without the compiler complaining about non-Sendable capture.
struct DiarizationResultBox: @unchecked Sendable {
    let segments: [SpeakerSegment]
    let speakerCount: Int

    init(_ result: DiarizationResult) {
        self.segments     = result.segments
        self.speakerCount = result.speakerCount
    }
}

// MARK: - Comparable clamped

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

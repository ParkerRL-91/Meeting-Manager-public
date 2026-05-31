import AVFoundation
import FluidAudio
import Foundation

// Phase 0 gate spike: confirm FluidAudio resolves, links with WhisperKit, the
// diarization API works on a real meeting WAV, and embeddings are exposed.
// Usage: fluid-spike <16k-mono-wav> [maxSeconds]

func loadMono16k(_ path: String, maxSeconds: Double?) -> (samples: [Float], sr: Double)? {
    guard let f = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { return nil }
    let fmt = f.processingFormat
    guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(f.length)) else { return nil }
    do { try f.read(into: buf) } catch { return nil }
    guard let ch = buf.floatChannelData else { return nil }
    var samples = Array(UnsafeBufferPointer(start: ch[0], count: Int(buf.frameLength)))
    if let maxSeconds {
        let cap = Int(maxSeconds * fmt.sampleRate)
        if samples.count > cap { samples = Array(samples[0..<cap]) }
    }
    return (samples, fmt.sampleRate)
}

let args = CommandLine.arguments
guard args.count >= 2 else { print("usage: fluid-spike <wav> [maxSeconds]"); exit(1) }
let path = args[1]
let maxSec = args.count >= 3 ? Double(args[2]) : nil

print("Loading \(path) ...")
guard let (samples, sr) = loadMono16k(path, maxSeconds: maxSec) else { print("FAILED to load audio"); exit(1) }
print("samples=\(samples.count) sr=\(sr)Hz dur=\(String(format: "%.1f", Double(samples.count) / sr))s")
guard sr == 16000 else { print("expected 16kHz audio, got \(sr) — aborting"); exit(1) }

do {
    print("Downloading/loading diarizer models (first run downloads from HuggingFace) ...")
    let models = try await DiarizerModels.downloadIfNeeded()
    let diarizer = DiarizerManager()
    diarizer.initialize(models: models)
    print("Diarizing \(String(format: "%.0f", Double(samples.count) / sr))s ...")
    let result = try diarizer.performCompleteDiarization(samples, sampleRate: 16000)
    let speakers = Set(result.segments.map { $0.speakerId }).sorted()
    print("=== RESULT ===")
    print("segments: \(result.segments.count)")
    print("unique speakers: \(speakers.count) -> \(speakers)")
    if let db = result.speakerDatabase {
        print("speakerDatabase: \(db.count) speakers; embedding dim = \(db.first?.value.count ?? 0)")
    } else {
        print("speakerDatabase: nil")
    }
    for seg in result.segments.prefix(8) {
        print(String(format: "  %@  %.1f-%.1fs  q=%.2f  embDim=%d",
                     seg.speakerId, seg.startTimeSeconds, seg.endTimeSeconds, seg.qualityScore, seg.embedding.count))
    }
    let embOK = (result.speakerDatabase?.isEmpty == false) || (result.segments.first?.embedding.isEmpty == false)
    print("GATE-CHECK splits=\(speakers.count > 1 ? "PASS" : "FAIL(1cluster)") embeddingsExposed=\(embOK ? "PASS" : "FAIL")")
} catch {
    print("DIARIZATION ERROR: \(error)")
    exit(1)
}

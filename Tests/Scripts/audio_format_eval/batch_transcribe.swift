// batch_transcribe.swift — load WhisperKit ONCE, transcribe many files.
//
// The existing Tools/TranscribeAudio CLI loads the 632 MB model on every
// invocation (~3 min on an M4). The format eval needs 60+ transcriptions, so
// per-file model loading dominates the runtime. This variant amortises the load.
//
// Decoding options are copied verbatim from Tools/TranscribeAudio/main.swift so
// results stay comparable with the existing WER harness.
//
// Standalone: compiled with swiftc against the already-built SPM artifacts,
// NOT added to Package.swift.
//
//   swiftc -O -o batch_transcribe batch_transcribe.swift \
//     -I .build/release/Modules -L .build/release -lArgmaxOSSDynamic \
//     -Xlinker -rpath -Xlinker "$PWD/.build/release"
//
// Usage:
//   batch_transcribe <jobs.json> <out.json>
//   jobs.json: [{"key": "...", "path": "/abs/path.wav"}, ...]
//   out.json:  {"key": {"text": "...", "seconds": 1.2}, ...}
//
// Already-present keys in out.json are skipped, so a killed run resumes.

import Foundation
import WhisperKit

struct Job: Codable { let key: String; let path: String }

guard CommandLine.arguments.count >= 3 else {
    fputs("usage: batch_transcribe <jobs.json> <out.json>\n", stderr)
    exit(1)
}
let jobsPath = CommandLine.arguments[1]
let outPath = CommandLine.arguments[2]

guard let jobsData = FileManager.default.contents(atPath: jobsPath),
      let jobs = try? JSONDecoder().decode([Job].self, from: jobsData) else {
    fputs("error: cannot read jobs from \(jobsPath)\n", stderr)
    exit(1)
}

// Resume support: keep whatever a previous run already produced.
var results: [String: [String: Any]] = [:]
if let existing = FileManager.default.contents(atPath: outPath),
   let parsed = try? JSONSerialization.jsonObject(with: existing) as? [String: [String: Any]] {
    results = parsed
}

func flush() {
    guard let data = try? JSONSerialization.data(withJSONObject: results,
                                                options: [.sortedKeys, .prettyPrinted]) else { return }
    try? data.write(to: URL(fileURLWithPath: outPath))
}

let modelName = "openai_whisper-large-v3-v20240930_turbo_632MB"
let group = DispatchGroup()
group.enter()

Task {
    do {
        fputs("loading \(modelName)...\n", stderr)
        let loadStart = Date()
        let pipe = try await WhisperKit(
            model: modelName,
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true,
            download: true
        )
        fputs("model ready in \(Int(-loadStart.timeIntervalSinceNow))s\n", stderr)

        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: "en",
            temperature: 0.0,
            temperatureIncrementOnFallback: 0.2,
            temperatureFallbackCount: 3,
            usePrefillPrompt: true,
            skipSpecialTokens: true,
            wordTimestamps: true,
            suppressBlank: true,
            suppressTokens: [Int]?.none,
            compressionRatioThreshold: 2.4,
            logProbThreshold: -1.0,
            noSpeechThreshold: 0.6
        )

        for (index, job) in jobs.enumerated() {
            if results[job.key] != nil {
                fputs("[\(index + 1)/\(jobs.count)] \(job.key) — cached\n", stderr)
                continue
            }
            guard FileManager.default.fileExists(atPath: job.path) else {
                fputs("[\(index + 1)/\(jobs.count)] \(job.key) — MISSING \(job.path)\n", stderr)
                results[job.key] = ["error": "missing file"]
                flush()
                continue
            }
            let start = Date()
            fputs("[\(index + 1)/\(jobs.count)] \(job.key)...", stderr)
            do {
                let segments = try await pipe.transcribe(audioPath: job.path, decodeOptions: options)
                let text = segments
                    .compactMap { $0.text }
                    .map { $0.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                let elapsed = -start.timeIntervalSinceNow
                results[job.key] = ["text": text, "seconds": elapsed]
                fputs(" \(Int(elapsed))s, \(text.split(separator: " ").count) words\n", stderr)
            } catch {
                fputs(" FAILED: \(error)\n", stderr)
                results[job.key] = ["error": "\(error)"]
            }
            flush()
        }
        flush()
        group.leave()
    } catch {
        fputs("error: \(error)\n", stderr)
        exit(1)
    }
}

group.wait()

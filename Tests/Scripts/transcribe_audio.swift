#!/usr/bin/env swift
//
// transcribe_audio.swift
// CLI helper that transcribes a single audio file using the same
// WhisperKit configuration as the main Meeting Manager app.
//
// Usage:
//   swift repo/Tests/Scripts/transcribe_audio.swift path/to/audio.aiff
//
// Output:
//   Transcript text on stdout.
//   Exits 0 on success, 1 on failure.
//
// Note: This is a standalone Swift script. For faster repeated runs,
// add it as an executable target in Package.swift and compile it:
//   swift build --product transcribe-audio
// Then use the compiled binary instead of running via `swift`.
//
// This script intentionally mirrors TranscriptionConfiguration.swift —
// if you change the decoding options in the app, update them here too.

import Foundation
import WhisperKit

// ─── Configuration (must match TranscriptionConfiguration.swift) ─────────────

let modelName = "openai_whisper-large-v3"
let modelCacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
    .first!
    .appendingPathComponent("MeetingManager/WhisperKit")

func makeDecodingOptions() -> DecodingOptions {
    var options = DecodingOptions()
    options.temperature = 0.0
    options.temperatureFallbackCount = 3
    options.suppressBlank = true
    options.noSpeechThreshold = 0.6
    options.logProbThreshold = -1.0
    options.compressionRatioThreshold = 2.4
    options.wordTimestamps = true
    return options
}

// ─── Main ──────────────────────────────────────────────────────────────────

guard CommandLine.arguments.count >= 2 else {
    fputs("Usage: transcribe_audio <audio-file>\n", stderr)
    exit(1)
}

let audioPath = CommandLine.arguments[1]

guard FileManager.default.fileExists(atPath: audioPath) else {
    fputs("Error: file not found: \(audioPath)\n", stderr)
    exit(1)
}

// Run synchronously on the main thread via a DispatchGroup
let group = DispatchGroup()
group.enter()

Task {
    do {
        // Initialize WhisperKit with the accuracy-optimized model
        fputs("Loading \(modelName)...\n", stderr)
        let pipe = try await WhisperKit(
            model: modelName,
            modelFolder: modelCacheDir.path
        )

        fputs("Transcribing \(audioPath)...\n", stderr)
        let options = makeDecodingOptions()
        let results = try await pipe.transcribe(
            audioPath: audioPath,
            decodeOptions: options
        )

        let transcript = results
            .compactMap { $0.text }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        print(transcript)
        group.leave()
    } catch {
        fputs("Error: \(error)\n", stderr)
        exit(1)
    }
}

group.wait()

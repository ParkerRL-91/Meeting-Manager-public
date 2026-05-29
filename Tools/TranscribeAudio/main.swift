import Foundation
import WhisperKit

// CLI tool: transcribe a single audio file using WhisperKit large-v3
// with the same decoding options as the main Meeting Manager app.
//
// Usage:  .build/debug/transcribe-audio path/to/audio.aiff
// Output: transcript text on stdout, progress on stderr
// Exit:   0 on success, 1 on failure
//
// Used by Tests/Scripts/measure_wer.py to evaluate transcription quality
// against synthetic test fixtures.
//
// Configuration mirrors TranscriptionConfiguration.default — if you change
// the app's decoding options, update these to match.

guard CommandLine.arguments.count >= 2 else {
    fputs("usage: transcribe-audio <audio-file>\n", stderr)
    exit(1)
}

let audioPath = CommandLine.arguments[1]

guard FileManager.default.fileExists(atPath: audioPath) else {
    fputs("error: file not found: \(audioPath)\n", stderr)
    exit(1)
}

let modelName = "openai_whisper-large-v3-v20240930_turbo_632MB"

let group = DispatchGroup()
group.enter()

Task {
    do {
        fputs("loading \(modelName) (downloads ~632MB on first run)...\n", stderr)
        let pipe = try await WhisperKit(
            model: modelName,
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true,
            download: true
        )

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

        fputs("transcribing...\n", stderr)
        let results = try await pipe.transcribe(audioPath: audioPath, decodeOptions: options)

        let transcript = results
            .compactMap { $0.text }
            .map { $0.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        print(transcript)
        group.leave()
    } catch {
        fputs("error: \(error)\n", stderr)
        exit(1)
    }
}

group.wait()

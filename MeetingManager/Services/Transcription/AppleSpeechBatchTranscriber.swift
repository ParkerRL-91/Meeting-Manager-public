import AVFoundation
import Foundation
import Speech
import os

/// Shared helpers for Apple's on-device speech recognizer.
///
/// SFSpeechRecognizer needs an explicit one-time authorization grant before
/// any recognition task will run, and a recognizer instance bound to a locale
/// the host actually supports. Both the live (`AppleSpeechTranscriber`) and the
/// batch (`AppleSpeechBatchTranscriber`) fallbacks route through here so the
/// authorization prompt and locale selection live in one place.
enum AppleSpeechSupport {

    /// Request (or confirm) Speech authorization. Returns true only when the
    /// user has granted access. Safe to call repeatedly — once decided, the
    /// status is cached by the system.
    static func ensureAuthorized() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        default:
            return false
        }
    }

    /// A recognizer for the user's locale, falling back to US English and then
    /// the system default. `SFSpeechRecognizer(locale:)` returns nil for an
    /// unsupported locale, so this never forces en-US on, say, a French Mac.
    static func makeRecognizer() -> SFSpeechRecognizer? {
        SFSpeechRecognizer(locale: Locale.current)
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
            ?? SFSpeechRecognizer()
    }
}

/// File/buffer-based transcription using Apple's on-device speech recognizer.
///
/// This is the batch counterpart to `AppleSpeechTranscriber` (which is
/// streaming-only). It exists so the WhisperKit-load-failure fallback actually
/// produces a transcript for completed meetings instead of throwing
/// `.modelNotLoaded` — the failure mode that left other Macs with a permanent
/// "Transcription failed" when WhisperKit couldn't load.
///
/// SFSpeechAudioBufferRecognitionRequest has a practical per-request duration
/// limit, so the input is recognized in fixed-length chunks and the per-chunk
/// word segments are re-based onto the global meeting timeline.
final class AppleSpeechBatchTranscriber: Sendable {

    private let sampleRate: Double = 16_000
    /// Stay comfortably under SFSpeech's per-request ceiling.
    private let chunkSeconds: Double = 45

    /// Transcribe 16 kHz mono Float32 samples. Throws if Speech access is
    /// denied, no recognizer is available, or a chunk fails to recognize.
    func transcribe(samples: [Float]) async throws -> [TranscriptSegment] {
        guard !samples.isEmpty else { throw TranscriptionError.invalidSamples }

        guard await AppleSpeechSupport.ensureAuthorized() else {
            throw TranscriptionError.transcriptionFailed("Speech recognition access was denied. Enable it in System Settings → Privacy & Security → Speech Recognition.")
        }
        guard let recognizer = AppleSpeechSupport.makeRecognizer() else {
            throw TranscriptionError.transcriptionFailed("No speech recognizer is available for this Mac's language.")
        }

        let chunkSize = Int(chunkSeconds * sampleRate)
        var results: [TranscriptSegment] = []
        var offset = 0
        while offset < samples.count {
            let end = min(offset + chunkSize, samples.count)
            let chunk = Array(samples[offset..<end])
            let chunkStart = Double(offset) / sampleRate
            let segments = try await recognize(chunk, recognizer: recognizer, startOffset: chunkStart)
            results.append(contentsOf: segments)
            offset = end
        }

        Logger.transcription.info("Apple Speech batch fallback produced \(results.count) segments from \(Int(Double(samples.count) / self.sampleRate))s of audio")
        return results
    }

    private func recognize(
        _ samples: [Float],
        recognizer: SFSpeechRecognizer,
        startOffset: Double
    ) async throws -> [TranscriptSegment] {
        guard !samples.isEmpty else { return [] }

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else {
            throw TranscriptionError.transcriptionFailed("Could not build audio buffer for speech recognition.")
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = true
        request.append(buffer)
        request.endAudio()

        return try await withCheckedThrowingContinuation { continuation in
            let box = ContinuationBox(continuation)
            recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    box.finish(throwing: TranscriptionError.transcriptionFailed(error.localizedDescription))
                    return
                }
                guard let result, result.isFinal else { return }
                let segments = result.bestTranscription.segments.compactMap { seg -> TranscriptSegment? in
                    let text = seg.substring.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return nil }
                    return TranscriptSegment(
                        text: text,
                        startTime: startOffset + seg.timestamp,
                        endTime: startOffset + seg.timestamp + seg.duration,
                        confidence: Double(seg.confidence)
                    )
                }
                box.finish(returning: segments)
            }
        }
    }
}

/// Guards a checked continuation so it can only be resumed once, even though
/// SFSpeech may invoke its callback multiple times before `isFinal`.
private final class ContinuationBox: @unchecked Sendable {
    private let continuation: CheckedContinuation<[TranscriptSegment], Error>
    private var resumed = false
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<[TranscriptSegment], Error>) {
        self.continuation = continuation
    }

    func finish(returning value: [TranscriptSegment]) {
        lock.withLock {
            guard !resumed else { return }
            resumed = true
            continuation.resume(returning: value)
        }
    }

    func finish(throwing error: Error) {
        lock.withLock {
            guard !resumed else { return }
            resumed = true
            continuation.resume(throwing: error)
        }
    }
}

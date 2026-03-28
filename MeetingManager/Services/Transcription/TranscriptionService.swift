import Foundation
import os

// TODO: Replace with actual WhisperKit import when SPM dependency is added
// import WhisperKit

// MARK: - Transcription Segment

/// A single segment produced by the transcription engine.
struct TranscriptionSegment: Sendable {
    /// The transcribed text.
    let text: String
    /// Start time in seconds relative to the beginning of the chunk.
    let startTime: Double
    /// End time in seconds relative to the beginning of the chunk.
    let endTime: Double
    /// Model confidence for this segment (0.0 – 1.0).
    let confidence: Double
}

// MARK: - Transcription Engine Protocol

/// Abstraction over the speech-to-text engine so the real WhisperKit
/// implementation can be swapped in without touching call sites.
protocol TranscriptionEngine: Sendable {
    /// Load the model from disk or download it. Report progress via the callback.
    func loadModel(
        named model: WhisperModel,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws

    /// Transcribe a buffer of 16 kHz mono Float32 samples.
    func transcribe(
        samples: [Float],
        language: String,
        temperature: Float,
        suppressBlank: Bool
    ) async throws -> [TranscriptionSegment]

    /// Release model resources.
    func unload()
}

// MARK: - Errors

enum TranscriptionError: LocalizedError {
    case modelNotLoaded
    case transcriptionFailed(String)
    case downloadFailed(String)
    case alreadyTranscribing
    case invalidSamples

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "No transcription model is loaded. Please select and download a model first."
        case .transcriptionFailed(let reason):
            return "Transcription failed: \(reason)"
        case .downloadFailed(let reason):
            return "Model download failed: \(reason)"
        case .alreadyTranscribing:
            return "A transcription session is already in progress."
        case .invalidSamples:
            return "The audio samples provided were empty or invalid."
        }
    }
}

// MARK: - Whisper Engine Stub

/// Stub engine used until the real WhisperKit SPM package is added.
/// Replace the body of each method with actual WhisperKit calls.
final class WhisperEngine: TranscriptionEngine, @unchecked Sendable {
    // TODO: Replace with actual WhisperKit instance when SPM dependency is added
    // private var whisperKit: WhisperKit?

    private let lock = NSLock()
    private var isLoaded = false

    func loadModel(
        named model: WhisperModel,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws {
        Logger.transcription.info("Loading model: \(model.rawValue)")

        // TODO: Replace with actual WhisperKit calls when SPM dependency is added
        // ──────────────────────────────────────────────────────────
        // let config = WhisperKitConfig(
        //     model: model.rawValue,
        //     downloadBase: nil,  // uses default HuggingFace repo
        //     verbose: false,
        //     logLevel: .none,
        //     prewarm: true,
        //     load: true,
        //     useBackgroundDownloadSession: false
        // )
        // whisperKit = try await WhisperKit(config)
        // ──────────────────────────────────────────────────────────

        // Simulate progressive download for UI development
        for step in stride(from: 0.0, through: 1.0, by: 0.1) {
            try await Task.sleep(for: .milliseconds(100))
            progressHandler(min(step, 1.0))
        }
        progressHandler(1.0)

        lock.lock()
        isLoaded = true
        lock.unlock()

        Logger.transcription.info("Model loaded successfully: \(model.rawValue)")
    }

    func transcribe(
        samples: [Float],
        language: String,
        temperature: Float,
        suppressBlank: Bool
    ) async throws -> [TranscriptionSegment] {
        lock.lock()
        let loaded = isLoaded
        lock.unlock()
        guard loaded else { throw TranscriptionError.modelNotLoaded }
        guard !samples.isEmpty else { throw TranscriptionError.invalidSamples }

        // TODO: Replace with actual WhisperKit calls when SPM dependency is added
        // ──────────────────────────────────────────────────────────
        // let decodingOptions = DecodingOptions(
        //     verbose: false,
        //     task: .transcribe,
        //     language: language,
        //     temperature: temperature,
        //     temperatureIncrementOnFallback: 0.2,
        //     temperatureFallbackCount: 3,
        //     sampleLength: 224,
        //     topK: 5,
        //     usePrefillPrompt: true,
        //     usePrefillCache: true,
        //     skipSpecialTokens: true,
        //     withoutTimestamps: false,
        //     suppressBlank: suppressBlank
        // )
        //
        // guard let whisperKit else { throw TranscriptionError.modelNotLoaded }
        // let results = try await whisperKit.transcribe(
        //     audioArray: samples,
        //     decodeOptions: decodingOptions
        // )
        //
        // return results.flatMap { result in
        //     result.segments.map { seg in
        //         TranscriptionSegment(
        //             text: seg.text.trimmingCharacters(in: .whitespacesAndNewlines),
        //             startTime: seg.start,
        //             endTime: seg.end,
        //             confidence: Double(seg.avgLogprob).normalized
        //         )
        //     }
        // }
        // ──────────────────────────────────────────────────────────

        // Stub: return an empty array so the pipeline compiles and runs
        return []
    }

    func unload() {
        // TODO: Replace with actual WhisperKit calls when SPM dependency is added
        // whisperKit = nil

        lock.lock()
        isLoaded = false
        lock.unlock()

        Logger.transcription.info("Model unloaded")
    }
}

// MARK: - Transcription Service

/// Observable service that manages the WhisperKit lifecycle and exposes
/// transcription capabilities to the rest of the app.
@Observable
@MainActor
final class TranscriptionService {
    // MARK: Published State

    /// True once a model has been loaded and is ready for inference.
    private(set) var isModelLoaded = false

    /// Model download / load progress (0.0 – 1.0).
    private(set) var downloadProgress: Double = 0

    /// True while a transcription call is in flight.
    private(set) var isTranscribing = false

    /// The currently loaded model, if any.
    private(set) var currentModel: WhisperModel?

    /// The last error encountered, for UI display.
    private(set) var lastError: TranscriptionError?

    // MARK: Configuration

    var configuration: TranscriptionConfiguration = .default

    // MARK: Private

    private let engine: TranscriptionEngine

    // MARK: Init

    /// Create a service with the default WhisperEngine.
    init() {
        self.engine = WhisperEngine()
    }

    /// Create a service with a custom engine (useful for testing).
    init(engine: TranscriptionEngine) {
        self.engine = engine
    }

    // MARK: - Model Management

    /// Load the specified model, downloading it on first use.
    /// Progress is reported through `downloadProgress`.
    func loadModel(_ model: WhisperModel) async throws {
        guard !isModelLoaded || currentModel != model else {
            Logger.transcription.debug("Model \(model.rawValue) already loaded")
            return
        }

        // Unload any previously loaded model
        if isModelLoaded {
            unloadModel()
        }

        downloadProgress = 0
        lastError = nil

        do {
            try await engine.loadModel(named: model) { [weak self] progress in
                Task { @MainActor in
                    self?.downloadProgress = progress
                }
            }

            await MainActor.run {
                self.isModelLoaded = true
                self.currentModel = model
                self.downloadProgress = 1.0
            }
        } catch {
            let txError = TranscriptionError.downloadFailed(error.localizedDescription)
            await MainActor.run {
                self.lastError = txError
                self.downloadProgress = 0
            }
            throw txError
        }
    }

    /// Transcribe raw 16 kHz mono samples and return segments.
    /// Segments with confidence below `configuration.minimumConfidence` are filtered out.
    func transcribe(samples: [Float]) async throws -> [TranscriptionSegment] {
        guard isModelLoaded else { throw TranscriptionError.modelNotLoaded }
        guard !samples.isEmpty else { throw TranscriptionError.invalidSamples }

        isTranscribing = true
        defer { isTranscribing = false }

        do {
            let segments = try await engine.transcribe(
                samples: samples,
                language: configuration.language,
                temperature: configuration.temperature,
                suppressBlank: configuration.suppressBlank
            )

            // Filter low-confidence segments
            return segments.filter { $0.confidence >= configuration.minimumConfidence }
        } catch {
            let txError = TranscriptionError.transcriptionFailed(error.localizedDescription)
            lastError = txError
            throw txError
        }
    }

    /// Release the loaded model and free memory.
    func unloadModel() {
        engine.unload()
        isModelLoaded = false
        currentModel = nil
        downloadProgress = 0
        Logger.transcription.info("Transcription model unloaded")
    }
}

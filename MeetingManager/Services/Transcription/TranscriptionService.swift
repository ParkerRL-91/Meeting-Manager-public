import Foundation
import WhisperKit
import os

// MARK: - Transcription Segment

/// A single segment produced by the transcription engine.
/// Named `TranscriptSegment` to avoid conflict with `WhisperKit.TranscriptSegment`.
struct TranscriptSegment: Sendable {
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
    /// The full configuration is passed so the engine can apply all
    /// accuracy and anti-hallucination options in one place.
    func transcribe(
        samples: [Float],
        configuration: TranscriptionConfiguration
    ) async throws -> [TranscriptSegment]

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

// MARK: - WhisperKit Engine

/// Real transcription engine backed by WhisperKit (on-device Whisper).
final class WhisperEngine: TranscriptionEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var whisperKit: WhisperKit?
    private var isLoaded = false

    /// The default HuggingFace cache path where WhisperKit stores downloaded CoreML models.
    private static var cachedModelFolder: String? {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/huggingface/models/argmaxinc/whisperkit-coreml")
        // Check if the model directory exists with required files
        let modelDir = base.appendingPathComponent("openai_whisper-large-v3")
        let required = ["AudioEncoder.mlmodelc", "MelSpectrogram.mlmodelc", "TextDecoder.mlmodelc"]
        let allExist = required.allSatisfy {
            FileManager.default.fileExists(atPath: modelDir.appendingPathComponent($0).path)
        }
        return allExist ? modelDir.path : nil
    }

    func loadModel(
        named model: WhisperModel,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws {
        Logger.transcription.info("Downloading/loading WhisperKit model: \(model.rawValue)")
        progressHandler(0.05)

        // Use cached model folder if available — avoids network check on HuggingFace
        // which can intermittently fail and cause "Model not found" errors.
        let cachedFolder = Self.cachedModelFolder
        let config: WhisperKitConfig
        if let cachedFolder {
            Logger.transcription.info("Using cached model at: \(cachedFolder)")
            config = WhisperKitConfig(
                model: model.rawValue,
                modelFolder: cachedFolder,
                verbose: false,
                logLevel: .error,
                prewarm: true,
                load: true,
                download: false
            )
        } else {
            Logger.transcription.info("No cached model found — downloading from HuggingFace")
            config = WhisperKitConfig(
                model: model.rawValue,
                verbose: false,
                logLevel: .error,
                prewarm: true,
                load: true,
                download: true,
                useBackgroundDownloadSession: false
            )
        }

        let kit = try await WhisperKit(config)
        progressHandler(1.0)

        lock.lock()
        whisperKit = kit
        isLoaded = true
        lock.unlock()

        Logger.transcription.info("WhisperKit model ready: \(model.rawValue)")
    }

    func transcribe(
        samples: [Float],
        configuration: TranscriptionConfiguration
    ) async throws -> [TranscriptSegment] {
        lock.lock()
        let kit = whisperKit
        let loaded = isLoaded
        lock.unlock()

        guard loaded, let kit else { throw TranscriptionError.modelNotLoaded }
        guard !samples.isEmpty else { throw TranscriptionError.invalidSamples }

        // Build full decoding options from configuration.
        // These settings work together as a hallucination prevention system:
        // - temperature=0 → deterministic greedy decoding (most accurate)
        // - noSpeechThreshold → discard silent segments before they hallucinate
        // - logProbThreshold → discard low-confidence segments
        // - compressionRatioThreshold → detect and discard repetitive output
        // - suppressBlank → eliminate empty stretch tokens
        let decodingOptions = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: configuration.language.isEmpty ? nil : configuration.language,
            temperature: configuration.temperature,
            temperatureIncrementOnFallback: 0.2,
            temperatureFallbackCount: configuration.temperatureFallbackCount,
            usePrefillPrompt: true,
            usePrefillCache: true,
            skipSpecialTokens: true,
            wordTimestamps: configuration.wordTimestamps,
            suppressBlank: configuration.suppressBlank,
            supressTokens: [Int]?.none,
            compressionRatioThreshold: configuration.compressionRatioThreshold,
            logProbThreshold: configuration.logProbThreshold,
            noSpeechThreshold: configuration.noSpeechThreshold
        )

        let results = try await kit.transcribe(
            audioArray: samples,
            decodeOptions: decodingOptions
        )

        return results.flatMap { result in
            result.segments.compactMap { seg in
                let text = seg.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                // Convert log-probability to a 0–1 confidence score.
                let confidence = min(max(Double(Foundation.exp(seg.avgLogprob)), 0), 1)
                return TranscriptSegment(
                    text: text,
                    startTime: Double(seg.start),
                    endTime: Double(seg.end),
                    confidence: confidence
                )
            }
        }
    }

    func unload() {
        lock.lock()
        whisperKit = nil
        isLoaded = false
        lock.unlock()
        Logger.transcription.info("WhisperKit model unloaded")
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

    /// Checks available system memory and logs a warning if it may be tight for the model.
    /// Returns true if memory is likely sufficient, false if critically low.
    private func checkMemoryAvailability() -> Bool {
        let available = ProcessInfo.processInfo.physicalMemory
        let availableMB = available / (1024 * 1024)
        // WhisperKit large-v3 needs ~3 GB for inference
        let requiredMB: UInt64 = 3072
        let warningThresholdMB: UInt64 = 4096

        if availableMB < requiredMB {
            Logger.transcription.warning("Very low memory for WhisperKit: \(availableMB) MB available, ~\(requiredMB) MB needed. Transcription may be slow or fail.")
            return false
        } else if availableMB < warningThresholdMB {
            Logger.transcription.info("Tight memory for WhisperKit: \(availableMB) MB available. Performance may be reduced.")
        } else {
            Logger.transcription.info("Memory check OK: \(availableMB) MB available for WhisperKit")
        }
        return true
    }

    /// True when available memory is critically low for the model.
    /// UI can observe this to show a warning to the user.
    private(set) var lowMemoryWarning = false

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

        // Check memory before loading — warn but don't block (user chose large-v3)
        lowMemoryWarning = !checkMemoryAvailability()

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
    func transcribe(samples: [Float]) async throws -> [TranscriptSegment] {
        guard isModelLoaded else { throw TranscriptionError.modelNotLoaded }
        guard !samples.isEmpty else { throw TranscriptionError.invalidSamples }

        isTranscribing = true
        defer { isTranscribing = false }

        do {
            let segments = try await engine.transcribe(
                samples: samples,
                configuration: configuration
            )

            // Filter low-confidence segments
            return segments.filter { $0.confidence >= configuration.minimumConfidence }
        } catch {
            let txError = TranscriptionError.transcriptionFailed(error.localizedDescription)
            lastError = txError
            throw txError
        }
    }

    /// Clear any stored error so the UI can dismiss error state (e.g. before retry).
    func clearError() {
        lastError = nil
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

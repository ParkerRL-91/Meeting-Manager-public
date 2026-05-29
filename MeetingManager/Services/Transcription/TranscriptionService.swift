import Foundation
import CoreML
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
@preconcurrency protocol TranscriptionEngine: Sendable {
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
/// Uses NSLock to protect the internal WhisperKit instance across concurrent callers.
final class WhisperEngine: TranscriptionEngine, @unchecked Sendable {
    private var whisperKit: WhisperKit?
    private var isLoaded = false
    private let lock = NSLock()

    /// Pick compute units appropriate for the current Mac. On Apple Silicon
    /// the WhisperKit defaults (mel: cpuAndGPU, audio encoder + text decoder:
    /// cpuAndNeuralEngine) are already optimal. On Intel Macs the Neural
    /// Engine doesn't exist and CoreML's automatic fallback to CPU is slower
    /// than just routing to the GPU explicitly. Returns nil on Apple Silicon
    /// so WhisperKit's own defaults apply.
    private static func computeOptionsForCurrentHardware() -> ModelComputeOptions? {
        #if arch(x86_64)
        return ModelComputeOptions(
            melCompute: .cpuAndGPU,
            audioEncoderCompute: .cpuAndGPU,
            textDecoderCompute: .cpuAndGPU
        )
        #else
        return nil
        #endif
    }

    /// The default HuggingFace cache path where WhisperKit stores downloaded CoreML models.
    /// Returns the path for the given model if the required CoreML files are already cached.
    private static func cachedModelFolder(for model: WhisperModel) -> String? {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/huggingface/models/argmaxinc/whisperkit-coreml")
        let modelDir = base.appendingPathComponent(model.rawValue)
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
        let cachedFolder = Self.cachedModelFolder(for: model)
        let computeOptions = Self.computeOptionsForCurrentHardware()
        let config: WhisperKitConfig
        if let cachedFolder {
            Logger.transcription.info("Using cached model at: \(cachedFolder)")
            config = WhisperKitConfig(
                model: model.rawValue,
                modelFolder: cachedFolder,
                computeOptions: computeOptions,
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
                computeOptions: computeOptions,
                verbose: false,
                logLevel: .error,
                prewarm: true,
                load: true,
                download: true,
                useBackgroundDownloadSession: false
            )
        }

        // Wrap with a 5-minute timeout — WhisperKit(config) can hang indefinitely
        // on network issues or corrupt model caches. withThrowingTaskGroup cancels
        // the hung task when the timeout fires (unlike a naive Task.sleep race).
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                let kit = try await WhisperKit(config)
                self.lock.withLock {
                    self.whisperKit = kit
                    self.isLoaded = true
                }
                progressHandler(1.0)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(300))
                throw TranscriptionError.transcriptionFailed("Model load timed out after 5 minutes")
            }
            // First task to finish wins; cancel the other
            try await group.next()!
            group.cancelAll()
        }

        Logger.transcription.info("WhisperKit model ready: \(model.rawValue)")
    }

    func transcribe(
        samples: [Float],
        configuration: TranscriptionConfiguration
    ) async throws -> [TranscriptSegment] {
        let (loaded, kit) = lock.withLock { (isLoaded, whisperKit) }
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
            skipSpecialTokens: true,
            wordTimestamps: configuration.wordTimestamps,
            suppressBlank: configuration.suppressBlank,
            suppressTokens: [Int]?.none,
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
        lock.withLock {
            whisperKit = nil
            isLoaded = false
        }
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

    /// Indicates which transcription engine is currently active.
    private(set) var transcriptionMode: TranscriptionMode = .none

    // MARK: Configuration

    var configuration: TranscriptionConfiguration = .default

    // MARK: Private

    private let engine: TranscriptionEngine

    /// Batch fallback used when WhisperKit failed to load and the service is
    /// running in `.appleSpeech` mode. Without this, completed-meeting
    /// transcription threw `.modelNotLoaded` and the "fallback" was dead code.
    private let appleSpeechBatch = AppleSpeechBatchTranscriber()

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
    private func checkMemoryAvailability(for model: WhisperModel) -> Bool {
        let available = ProcessInfo.processInfo.physicalMemory
        let availableMB = available / (1024 * 1024)
        let requiredMB = UInt64(model.estimatedMemoryMB)
        let warningThresholdMB = requiredMB + 1024

        if availableMB < requiredMB {
            Logger.transcription.warning("Very low memory for WhisperKit \(model.displayName): \(availableMB) MB available, ~\(requiredMB) MB needed. Transcription may be slow or fail.")
            return false
        } else if availableMB < warningThresholdMB {
            Logger.transcription.info("Tight memory for WhisperKit \(model.displayName): \(availableMB) MB available. Performance may be reduced.")
        } else {
            Logger.transcription.info("Memory check OK: \(availableMB) MB available for WhisperKit \(model.displayName)")
        }
        return true
    }

    /// True when available memory is critically low for the model.
    /// UI can observe this to show a warning to the user.
    private(set) var lowMemoryWarning = false

    /// Load the specified model, downloading it on first use.
    /// Progress is reported through `downloadProgress`.
    /// If WhisperKit fails to load, automatically falls back to Apple Speech.
    func loadModel(_ model: WhisperModel) async throws {
        guard !isModelLoaded || currentModel != model else {
            Logger.transcription.debug("Model \(model.rawValue) already loaded")
            return
        }

        // Unload any previously loaded model
        if isModelLoaded {
            unloadModel()
        }

        // Check memory before loading — warn but don't block
        lowMemoryWarning = !checkMemoryAvailability(for: model)

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
                self.transcriptionMode = .whisperKit
            }
        } catch {
            Logger.transcription.error("WhisperKit model load failed: \(error.localizedDescription) — attempting Apple Speech fallback")

            // Attempt Apple Speech fallback
            await MainActor.run {
                self.transcriptionMode = .appleSpeech
                self.isModelLoaded = true
                self.currentModel = model
                self.downloadProgress = 1.0
            }
            Logger.transcription.info("Transcription mode set to .appleSpeech (WhisperKit unavailable)")
            // Don't throw — fallback is available. Callers read transcriptionMode.
        }
    }

    /// Transcribe raw 16 kHz mono samples and return segments.
    /// Segments with confidence below `configuration.minimumConfidence` are filtered out.
    func transcribe(samples: [Float]) async throws -> [TranscriptSegment] {
        guard isModelLoaded else { throw TranscriptionError.modelNotLoaded }
        guard !samples.isEmpty else { throw TranscriptionError.invalidSamples }

        isTranscribing = true
        defer { isTranscribing = false }

        // When WhisperKit couldn't load we run in .appleSpeech mode: route batch
        // transcription to Apple's on-device recognizer instead of WhisperEngine
        // (which would throw .modelNotLoaded). Apple's confidence scores use a
        // different scale than WhisperKit's log-prob conversion, so the
        // WhisperKit confidence floor is not applied here.
        if transcriptionMode == .appleSpeech {
            do {
                return try await appleSpeechBatch.transcribe(samples: samples)
            } catch {
                let txError = TranscriptionError.transcriptionFailed(error.localizedDescription)
                lastError = txError
                throw txError
            }
        }

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

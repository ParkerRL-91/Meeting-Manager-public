import Foundation
import os

// MARK: - Ollama API Types

private struct OllamaMessage: Codable {
    let role: String
    let content: String
}

private struct OllamaChatRequest: Encodable {
    let model: String
    let messages: [OllamaMessage]
    let stream: Bool
    /// Thinking-model toggle (qwen3, deepseek-r1). nil = model default.
    /// Setting false skips the chain-of-thought phase — much faster for
    /// simple tasks (classification, bounded summarization) that don't need it.
    let think: Bool?
    /// Constrained output. "json" forces syntactically valid JSON, so the
    /// model emits just the object instead of rambling reasoning into the
    /// content (the failure mode when thinking is off but format is free).
    let format: String?
    let options: OllamaOptions?
    init(model: String, messages: [OllamaMessage], stream: Bool = false,
         think: Bool? = nil, format: String? = nil, options: OllamaOptions?) {
        self.model = model
        self.messages = messages
        self.stream = stream
        self.think = think
        self.format = format
        self.options = options
    }
}

private struct OllamaOptions: Encodable {
    let temperature: Double
    let num_predict: Int
    let num_ctx: Int?

    init(temperature: Double, num_predict: Int, num_ctx: Int? = nil) {
        self.temperature = temperature
        self.num_predict = num_predict
        self.num_ctx = num_ctx
    }
}

private struct OllamaChatResponseMessage: Decodable {
    let role: String
    let content: String
    let thinking: String?
}

private struct OllamaChatResponse: Decodable {
    let message: OllamaChatResponseMessage
    let done: Bool
}

private struct OllamaTagsResponse: Decodable {
    let models: [OllamaModelInfo]
}

private struct OllamaModelInfo: Decodable {
    let name: String
    let size: Int64
}

// MARK: - OllamaServiceError

enum OllamaServiceError: LocalizedError {
    case notRunning
    case noModels
    case httpError(statusCode: Int)
    case emptyResponse
    case networkError(Error)
    case decodingError(Error)
    /// Request hit its (generously sized) timeout. Terminal, NOT retried:
    /// the budget can be up to 30 min for Qwen3 thinking on long inputs, so
    /// 3 identical retries against a wedged server would stall the serial
    /// task queue — and everything queued behind it — for over an hour.
    case timedOut

    var errorDescription: String? {
        switch self {
        case .notRunning:
            return "Ollama is not running. Start Ollama and try again."
        case .noModels:
            return "No models found in Ollama. Run: ollama pull qwen3:4b"
        case .httpError(let statusCode):
            return "Ollama returned HTTP \(statusCode)."
        case .emptyResponse:
            return "Ollama returned an empty response."
        case .networkError(let error):
            return "Could not reach Ollama: \(error.localizedDescription)"
        case .decodingError(let error):
            return "Failed to parse Ollama response: \(error.localizedDescription)"
        case .timedOut:
            return "Ollama timed out before producing a response. The server may be wedged — try restarting Ollama, or switch to a smaller model."
        }
    }
}

// MARK: - OllamaService

/// Calls a locally running Ollama server (http://localhost:11434) to generate text.
/// No data leaves the device. Requires the user to have Ollama installed and running.
@Observable
@MainActor
final class OllamaService {

    static let baseURL = URL(string: "http://localhost:11434")!

    // MARK: Model Ladder (single source of truth)
    //
    // Two-tier ladder upgraded to Qwen3 in v3.10.4 (ADR-007). Qwen3 4B replaces
    // Llama 3.2 3B as the small/fast tier; Qwen3 8B replaces Llama 3.1 8B for
    // long transcripts. Same memory envelope on a 16GB M4 baseline; materially
    // better instruction-following and JSON adherence (the two things this
    // app's structured-output paths — action items, attribution — depend on).
    //
    // Llama 3.x is NOT removed: if the user already pulled it, the picker
    // still exposes it and the truncation fallback (line ~145) prefers
    // qwen3:8b but falls back to llama3.1:8b when the user has only Llama
    // installed. ADR-007 has the rationale and migration story.
    static let smallTier   = "qwen3:4b"
    static let defaultTier = "qwen3:8b"
    static let defaultModel = defaultTier

    /// Model tiers ranked by capability. The adaptive selector picks the best
    /// installed model that can handle the input size. Top tier raised to
    /// 131K because Qwen3 8B's native context goes to 128K — well above
    /// Llama 3.1 8B's effective 65K limit.
    static let modelTiers: [(name: String, maxInputTokens: Int, contextWindow: Int)] = [
        // NOTE: explicit "qwen3:4b"/"qwen3:8b" rather than Self.smallTier — Swift
        // won't let a static stored property reference Self in its initializer.
        // Keep these identifiers in sync with smallTier / defaultTier above.
        ("qwen3:4b",  4000,   8192),   // Fast — short 1:1s
        ("qwen3:4b",  8000,  16384),   // Medium — standard meetings
        ("qwen3:4b", 14000,  32768),   // Large — extended meetings
        ("qwen3:8b", 22000,  32768),   // XL — long meetings, better reasoning
        ("qwen3:8b", 60000, 131072),   // XXL — marathon sessions, native 128K context
    ]

    // MARK: - Status

    private(set) var isReachable = false
    private(set) var availableModels: [String] = []
    private(set) var isCheckingStatus = false

    // MARK: - Adaptive Model Selection

    /// Selects the best model and context window for the given input.
    /// Returns (model, contextWindow, truncatedPrompt) — the prompt is
    /// truncated only if no installed model can fit the full input.
    func adaptiveSelect(
        systemPrompt: String,
        userPrompt: String
    ) -> (model: String, numCtx: Int, systemPrompt: String, userPrompt: String) {
        let totalChars = systemPrompt.count + userPrompt.count
        // Rough token estimate: ~4 chars per token for English
        let estimatedTokens = totalChars / 4
        let outputReserve = 2048 // tokens reserved for the summary output

        let models = self.availableModels
        Logger.ai.info("Adaptive select: ~\(estimatedTokens) input tokens, \(models.count) models available")

        // Walk tiers from smallest to largest, pick the first that fits AND is installed
        for tier in Self.modelTiers {
            guard models.contains(where: { $0.hasPrefix(tier.name.components(separatedBy: ":").first ?? tier.name) && $0.contains(tier.name.components(separatedBy: ":").last ?? "") }) || models.contains(tier.name) else {
                continue
            }
            if estimatedTokens + outputReserve <= tier.contextWindow {
                Logger.ai.info("Adaptive: selected \(tier.name) ctx=\(tier.contextWindow) for ~\(estimatedTokens) tokens")
                return (tier.name, tier.contextWindow, systemPrompt, userPrompt)
            }
        }

        // No tier fits — use the largest available model with truncation.
        // Prefer the new Qwen3 tier when present; fall back to the legacy
        // Llama 3.1 8B for users who only ever pulled the old default and
        // haven't yet picked up the Qwen upgrade.
        let bestModel: String
        let bestCtx: Int
        if models.contains(Self.defaultTier) {
            bestModel = Self.defaultTier
            bestCtx = 131072
        } else if models.contains("llama3.1:8b") {
            bestModel = "llama3.1:8b"
            bestCtx = 65536
        } else {
            bestModel = models.first ?? Self.defaultModel
            bestCtx = 16384
        }

        // Truncate: keep system prompt + first 10% of user prompt (intro/agenda) + last 90% (decisions/actions)
        let maxUserChars = (bestCtx - outputReserve) * 4 - systemPrompt.count
        let truncatedUser: String
        if userPrompt.count > maxUserChars && maxUserChars > 0 {
            let keepStart = maxUserChars / 10
            let keepEnd = maxUserChars - keepStart - 100 // 100 chars for the truncation notice
            let start = String(userPrompt.prefix(keepStart))
            let end = String(userPrompt.suffix(keepEnd))
            truncatedUser = start + "\n\n[... transcript truncated for length ...]\n\n" + end
            Logger.ai.info("Adaptive: truncated \(userPrompt.count) → \(truncatedUser.count) chars for \(bestModel) ctx=\(bestCtx)")
        } else {
            truncatedUser = userPrompt
        }

        Logger.ai.info("Adaptive: selected \(bestModel) ctx=\(bestCtx) (truncated) for ~\(estimatedTokens) tokens")
        return (bestModel, bestCtx, systemPrompt, truncatedUser)
    }

    // MARK: - Text Generation

    /// Generate a response given a system prompt and user message using the specified model.
    /// When `model` is `"auto"`, adaptive selection picks the best model for the input size.
    /// `maxOutputTokens` defaults to 2048; bump to 8192+ for long structured output
    /// (e.g. the detailed outline path, where 2048 was silently truncating mid-meeting).
    func generate(
        systemPrompt: String,
        userPrompt: String,
        model: String,
        maxOutputTokens: Int = 2048,
        think: Bool = true,    // default ON — Qwen3 with think:false leaks its
                               // chain-of-thought (and restated prompt text) into
                               // the content field; think:true keeps reasoning in
                               // the separate `thinking` field, then we strip it.
        jsonMode: Bool = false
    ) async throws -> String {
        let selectedModel: String
        let numCtx: Int
        let finalSystem: String
        let finalUser: String

        if model == "auto" {
            let selection = adaptiveSelect(systemPrompt: systemPrompt, userPrompt: userPrompt)
            selectedModel = selection.model
            numCtx = selection.numCtx
            finalSystem = selection.systemPrompt
            finalUser = selection.userPrompt
        } else {
            selectedModel = model
            // Compute a tight context window even for explicit models —
            // Ollama's default (131K) is too large and causes multi-minute stalls.
            let estimatedTokens = (systemPrompt.count + userPrompt.count) / 4
            let needed = estimatedTokens + maxOutputTokens // input + output reserve
            // Round up to nearest power-of-2 bucket: 8K, 16K, 32K, 64K
            if needed <= 8192       { numCtx = 8192 }
            else if needed <= 16384 { numCtx = 16384 }
            else if needed <= 32768 { numCtx = 32768 }
            else                    { numCtx = 65536 }
            finalSystem = systemPrompt
            finalUser = userPrompt
        }

        // Dynamic timeout: account for both input processing and output
        // generation. Qwen3's thinking mode can spend minutes reasoning
        // before emitting any output tokens, so the timeout must cover
        // thinking time (proportional to input) + generation time
        // (proportional to num_predict). Formula: ~1 min per 2K input
        // tokens + ~1 min per 4K output tokens, minimum 120s, max 1800s.
        let inputChars = finalSystem.count + finalUser.count
        let inputTime = Double(inputChars / 4) / 2000.0 * 60.0
        let outputTime = Double(maxOutputTokens) / 4000.0 * 60.0
        let estimatedSeconds = max(120, min(1800, inputTime + outputTime))

        let url = Self.baseURL.appendingPathComponent("api/chat")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = estimatedSeconds

        let body = OllamaChatRequest(
            model: selectedModel,
            messages: [
                OllamaMessage(role: "system", content: finalSystem),
                OllamaMessage(role: "user", content: finalUser),
            ],
            // Only send the `think` field to thinking-capable models (qwen3,
            // deepseek-r1). Instruct models (qwen2.5, llama) don't support it and
            // can error/stall on it — omit so they just generate directly.
            think: selectedModel.contains("qwen3") ? think : nil,
            format: jsonMode ? "json" : nil,
            options: OllamaOptions(
                temperature: 0.3,
                num_predict: maxOutputTokens,
                num_ctx: numCtx > 0 ? numCtx : nil
            )
        )
        request.httpBody = try JSONEncoder().encode(body)

        Logger.ai.info("Sending request to Ollama (model: \(selectedModel), ctx: \(numCtx > 0 ? "\(numCtx)" : "default"), maxOut: \(maxOutputTokens))")

        // Retry up to 3 times on transient failures — network errors and 5xx.
        // /api/chat is idempotent at the protocol level (the model is the only
        // mutable resource, and we don't pass any state-changing options here),
        // so re-sending the same prompt is safe. 4xx and decode errors are
        // terminal — they won't get better with another attempt. Match the
        // ClaudeService backoff: 2^attempt + random(0...1)s.
        let decoded: OllamaChatResponse = try await Self.withRetry(maxAttempts: 3) {
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await URLSession.shared.data(for: request)
            } catch {
                Logger.ai.error("Ollama network error: \(error.localizedDescription)")
                if (error as? URLError)?.code == .timedOut {
                    throw OllamaServiceError.timedOut
                }
                throw OllamaServiceError.networkError(error)
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                throw OllamaServiceError.networkError(URLError(.badServerResponse))
            }
            guard (200...299).contains(httpResponse.statusCode) else {
                throw OllamaServiceError.httpError(statusCode: httpResponse.statusCode)
            }

            do {
                return try JSONDecoder().decode(OllamaChatResponse.self, from: data)
            } catch {
                Logger.ai.error("Ollama decode error: \(error.localizedDescription)")
                throw OllamaServiceError.decodingError(error)
            }
        }

        var text = decoded.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty, let thinking = decoded.message.thinking?.trimmingCharacters(in: .whitespacesAndNewlines), !thinking.isEmpty {
            Logger.ai.warning("Ollama: content was empty but thinking had \(thinking.count) chars — using thinking as fallback")
            text = thinking
        }
        text = Self.stripThinkBlock(text)
        guard !text.isEmpty else {
            throw OllamaServiceError.emptyResponse
        }

        Logger.ai.info("Ollama response received (\(text.count) chars, model: \(selectedModel))")
        return text
    }

    /// Retry helper for idempotent Ollama calls. Retries on network errors
    /// and HTTP 5xx; treats 4xx and decode errors as terminal. Mirrors the
    /// ClaudeService pattern (2^attempt + random(0...1)s backoff). Static so
    /// the generate flow can call it without capturing self.
    private static func withRetry<T>(
        maxAttempts: Int = 3,
        operation: () async throws -> T
    ) async throws -> T {
        var lastError: Error?
        for attempt in 0..<maxAttempts {
            do {
                return try await operation()
            } catch {
                lastError = error
                let retryable: Bool
                switch error {
                case OllamaServiceError.networkError:
                    retryable = true
                case OllamaServiceError.httpError(let status):
                    retryable = (500...599).contains(status)
                default:
                    retryable = false
                }
                guard retryable, attempt < maxAttempts - 1 else { throw error }
                let delay = pow(2.0, Double(attempt)) + Double.random(in: 0...1)
                try? await Task.sleep(for: .seconds(delay))
            }
        }
        throw lastError ?? OllamaServiceError.networkError(URLError(.unknown))
    }

    /// Strip a chain-of-thought block from content. Normally Ollama separates
    /// thinking into its own field, but some Qwen3 builds emit reasoning inline
    /// (especially with think:false), leaving a "<think>…</think>" block — or a
    /// dangling preamble that ends in a stray "</think>" with no opening tag —
    /// ahead of the real answer. Keep only what follows the last "</think>".
    static func stripThinkBlock(_ s: String) -> String {
        guard let closeRange = s.range(of: "</think>", options: .backwards) else { return s }
        return String(s[closeRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Streaming Generation (for task queue / long meetings)

    /// Generate a response using streaming — reads chunks incrementally so there's no
    /// single timeout. Ideal for long meetings processed in the background via the task queue.
    /// Never times out as long as Ollama keeps sending chunks.
    func generateStreaming(systemPrompt: String, userPrompt: String, model: String) async throws -> String {
        let selectedModel: String
        let numCtx: Int
        let finalSystem: String
        let finalUser: String

        if model == "auto" {
            let selection = adaptiveSelect(systemPrompt: systemPrompt, userPrompt: userPrompt)
            selectedModel = selection.model
            numCtx = selection.numCtx
            finalSystem = selection.systemPrompt
            finalUser = selection.userPrompt
        } else {
            selectedModel = model
            let estimatedTokens = (systemPrompt.count + userPrompt.count) / 4
            let needed = estimatedTokens + 2048
            if needed <= 8192       { numCtx = 8192 }
            else if needed <= 16384 { numCtx = 16384 }
            else if needed <= 32768 { numCtx = 32768 }
            else                    { numCtx = 65536 }
            finalSystem = systemPrompt
            finalUser = userPrompt
        }

        let url = Self.baseURL.appendingPathComponent("api/chat")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // No overall timeout — streaming means we get chunks continuously
        request.timeoutInterval = 3600

        let body = OllamaChatRequest(
            model: selectedModel,
            messages: [
                OllamaMessage(role: "system", content: finalSystem),
                OllamaMessage(role: "user", content: finalUser),
            ],
            stream: true,
            // Thinking ON for Qwen3: with think:false the hybrid models leak
            // chain-of-thought (and restated prompt text) into the content
            // field, which then surfaced verbatim in summaries. think:true keeps
            // the reasoning in the separate `thinking` field; we strip any stray
            // <think> block from the content below. Mirrors DailyBriefAIService,
            // which already learned this. Instruct models omit the field.
            think: selectedModel.contains("qwen3") ? true : nil,
            options: OllamaOptions(
                temperature: 0.3,
                num_predict: 8192,
                num_ctx: numCtx > 0 ? numCtx : nil
            )
        )
        request.httpBody = try JSONEncoder().encode(body)

        Logger.ai.info("Streaming request to Ollama (model: \(selectedModel), ctx: \(numCtx))")

        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw OllamaServiceError.httpError(statusCode: code)
        }

        // Read NDJSON chunks — each line is a JSON object with
        // {"message":{"content":"...", "thinking":"..."}, "done":bool}.
        // With think:true the reasoning arrives in the `thinking` field; we keep
        // `content` (the answer) and collect `thinking` only as a defensive
        // fallback for the rare case where a model puts everything in reasoning.
        var fullText = ""
        var fullThinking = ""
        for try await line in bytes.lines {
            guard !line.isEmpty else { continue }
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let message = json["message"] as? [String: Any] else {
                continue
            }
            if let content = message["content"] as? String {
                fullText += content
            }
            if let thinking = message["thinking"] as? String {
                fullThinking += thinking
            }

            if let done = json["done"] as? Bool, done {
                break
            }
        }

        // Prefer content; fall back to thinking only if the model put its
        // whole answer in the reasoning field (rare edge case).
        var trimmed = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty && !fullThinking.isEmpty {
            Logger.ai.warning("Ollama: content was empty but thinking had \(fullThinking.count) chars — using thinking as fallback")
            trimmed = fullThinking.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !trimmed.isEmpty else {
            throw OllamaServiceError.emptyResponse
        }

        // Strip any <think>…</think> block emitted inline (the non-streaming
        // generate() path does this too). Without it, Qwen3's reasoning — which
        // restates the prompt while it works — leaked verbatim into summaries.
        let cleaned = Self.stripThinkBlock(trimmed)
        guard !cleaned.isEmpty else { throw OllamaServiceError.emptyResponse }

        Logger.ai.info("Streaming response complete (\(cleaned.count) chars, model: \(selectedModel))")
        return cleaned
    }

    // MARK: - Status Check

    /// Ping Ollama and refresh the list of available models.
    /// Updates `isReachable` and `availableModels` on the main actor.
    func refreshStatus() async {
        isCheckingStatus = true
        defer { isCheckingStatus = false }

        let url = Self.baseURL.appendingPathComponent("api/tags")
        var request = URLRequest(url: url)
        request.timeoutInterval = 3

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                isReachable = false
                availableModels = []
                return
            }
            let decoded = try JSONDecoder().decode(OllamaTagsResponse.self, from: data)
            isReachable = true
            availableModels = decoded.models.map { $0.name }
            Logger.ai.info("Ollama reachable — \(self.availableModels.count) model(s) available")
        } catch {
            isReachable = false
            availableModels = []
            Logger.ai.info("Ollama not reachable: \(error.localizedDescription)")
        }
    }
}

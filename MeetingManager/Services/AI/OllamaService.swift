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
    let options: OllamaOptions?

    init(model: String, messages: [OllamaMessage], stream: Bool = false, options: OllamaOptions?) {
        self.model = model
        self.messages = messages
        self.stream = stream
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

private struct OllamaChatResponse: Decodable {
    let message: OllamaMessage
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

    var errorDescription: String? {
        switch self {
        case .notRunning:
            return "Ollama is not running. Start Ollama and try again."
        case .noModels:
            return "No models found in Ollama. Run: ollama pull llama3.2:3b"
        case .httpError(let statusCode):
            return "Ollama returned HTTP \(statusCode)."
        case .emptyResponse:
            return "Ollama returned an empty response."
        case .networkError(let error):
            return "Could not reach Ollama: \(error.localizedDescription)"
        case .decodingError(let error):
            return "Failed to parse Ollama response: \(error.localizedDescription)"
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
    static let defaultModel = "llama3.2:3b"

    /// Model tiers ranked by capability. The adaptive selector picks the best
    /// installed model that can handle the input size.
    static let modelTiers: [(name: String, maxInputTokens: Int, contextWindow: Int)] = [
        ("llama3.2:3b",  4000,   8192),   // Fast — short 1:1s
        ("llama3.2:3b",  8000,  16384),   // Medium — standard meetings
        ("llama3.1:8b", 20000,  32768),   // Large — long group meetings
        ("llama3.1:8b", 40000,  65536),   // XL — marathon sessions
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

        // No tier fits — use the largest available model with truncation
        let bestModel: String
        let bestCtx: Int
        if models.contains("llama3.1:8b") {
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
    func generate(systemPrompt: String, userPrompt: String, model: String) async throws -> String {
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
            let needed = estimatedTokens + 2048 // input + output reserve
            // Round up to nearest power-of-2 bucket: 8K, 16K, 32K, 64K
            if needed <= 8192       { numCtx = 8192 }
            else if needed <= 16384 { numCtx = 16384 }
            else if needed <= 32768 { numCtx = 32768 }
            else                    { numCtx = 65536 }
            finalSystem = systemPrompt
            finalUser = userPrompt
        }

        // Dynamic timeout: ~1 min per 2K input tokens, minimum 120s, max 900s
        let inputChars = finalSystem.count + finalUser.count
        let estimatedSeconds = max(120, min(900, Double(inputChars / 4) / 2000.0 * 60.0))

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
            options: OllamaOptions(
                temperature: 0.3,
                num_predict: 2048,
                num_ctx: numCtx > 0 ? numCtx : nil
            )
        )
        request.httpBody = try JSONEncoder().encode(body)

        Logger.ai.info("Sending request to Ollama (model: \(selectedModel), ctx: \(numCtx > 0 ? "\(numCtx)" : "default"))")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            Logger.ai.error("Ollama network error: \(error.localizedDescription)")
            throw OllamaServiceError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OllamaServiceError.networkError(URLError(.badServerResponse))
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw OllamaServiceError.httpError(statusCode: httpResponse.statusCode)
        }

        let decoded: OllamaChatResponse
        do {
            decoded = try JSONDecoder().decode(OllamaChatResponse.self, from: data)
        } catch {
            Logger.ai.error("Ollama decode error: \(error.localizedDescription)")
            throw OllamaServiceError.decodingError(error)
        }

        let text = decoded.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw OllamaServiceError.emptyResponse
        }

        Logger.ai.info("Ollama response received (\(text.count) chars, model: \(selectedModel))")
        return text
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
            options: OllamaOptions(
                temperature: 0.3,
                num_predict: 2048,
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

        // Read NDJSON chunks — each line is a JSON object with {"message":{"content":"..."}, "done":bool}
        var fullText = ""
        for try await line in bytes.lines {
            guard !line.isEmpty else { continue }
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let message = json["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                continue
            }
            fullText += content

            if let done = json["done"] as? Bool, done {
                break
            }
        }

        let trimmed = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw OllamaServiceError.emptyResponse
        }

        Logger.ai.info("Streaming response complete (\(trimmed.count) chars, model: \(selectedModel))")
        return trimmed
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

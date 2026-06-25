import Foundation
import os

// MARK: - Provider configuration

/// Configuration for an OpenAI-compatible chat-completions provider. OpenAI and
/// z.ai both speak the same `/chat/completions` wire format; they differ only in
/// base URL, key, the token-limit field name, and temperature handling. Adding
/// another compatible provider is a new static preset, not a new file.
struct OpenAICompatibleProvider: Sendable {
    enum TokenParam: String, Sendable {
        case maxTokens = "max_tokens"
        case maxCompletionTokens = "max_completion_tokens"
    }
    let displayName: String
    let baseURL: String          // no trailing slash; "/chat/completions" is appended
    let keychainKey: String
    let tokenParam: TokenParam
    let sendsTemperature: Bool
    let defaultTestModel: String

    static let openAI = OpenAICompatibleProvider(
        displayName: "OpenAI",
        baseURL: "https://api.openai.com/v1",
        keychainKey: KeychainHelper.Key.openAIAPIKey,
        tokenParam: .maxCompletionTokens,   // gpt-5.x reject max_tokens
        sendsTemperature: false,            // gpt-5.x reasoning models are picky about temperature
        defaultTestModel: "gpt-5.4-mini"
    )
    static let zai = OpenAICompatibleProvider(
        displayName: "z.ai",
        baseURL: "https://api.z.ai/api/paas/v4",
        keychainKey: KeychainHelper.Key.zaiAPIKey,
        tokenParam: .maxTokens,
        sendsTemperature: true,
        defaultTestModel: "glm-5.2"
    )
}

// MARK: - API response / error types

private struct OpenAIChatResponse: Decodable {
    let choices: [Choice]?
    let usage: Usage?
    struct Choice: Decodable {
        let message: Message?
        let finish_reason: String?
    }
    struct Message: Decodable { let content: String? }
    struct Usage: Decodable {
        let prompt_tokens: Int?
        let completion_tokens: Int?
    }
}

private struct OpenAIErrorResponse: Decodable {
    let error: ErrorDetail
    struct ErrorDetail: Decodable {
        let message: String
        let type: String?
        let code: String?
    }
}

enum OpenAICompatibleError: LocalizedError {
    case missingAPIKey(provider: String)
    case invalidURL
    case rateLimited(retryAfterSeconds: Int?)
    case httpError(statusCode: Int, message: String)
    case emptyResponse
    case networkError(Error)
    case decodingError(Error)
    case responseTooLarge(Int)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider):
            return "\(provider) API key is not configured. Add your key in Settings."
        case .invalidURL:
            return "Invalid API endpoint URL."
        case .rateLimited(let retryAfter):
            if let seconds = retryAfter {
                return "Rate limited. Try again in \(seconds) seconds."
            }
            return "Rate limited. Please wait a moment and try again."
        case .httpError(let statusCode, let message):
            return "API error (\(statusCode)): \(message)"
        case .emptyResponse:
            return "The API returned an empty response."
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .decodingError(let error):
            return "Failed to parse API response: \(error.localizedDescription)"
        case .responseTooLarge(let bytes):
            return "API response too large (\(bytes / 1024)KB). Maximum allowed is 1MB."
        }
    }
}

// MARK: - OpenAICompatibleService

/// Communicates with any OpenAI-compatible /chat/completions endpoint (OpenAI,
/// z.ai). Mirrors GeminiService: shared static rate-limiter, retry, redactor,
/// activity tracking, and app.log outcome logging.
@Observable
@MainActor
final class OpenAICompatibleService {

    private(set) var isProcessing = false
    private(set) var lastError: String?

    private let provider: OpenAICompatibleProvider
    private let session: URLSession

    /// Shared spacing across ALL instances of this service (every call site
    /// builds a fresh instance). @MainActor isolation makes the
    /// reserve-before-await read-modify-write atomic. Only one provider is
    /// active at a time, so a single shared gate is correct.
    private static let minimumRequestInterval: TimeInterval = 1.0
    private static var nextAllowedRequestTime: Date = .distantPast

    private static let maxResponseBytes = 1_048_576

    init(provider: OpenAICompatibleProvider, session: URLSession = .shared) {
        self.provider = provider
        self.session = session
    }

    private func waitForRateLimit() async {
        let now = Date()
        let scheduled = max(now, Self.nextAllowedRequestTime)
        Self.nextAllowedRequestTime = scheduled.addingTimeInterval(Self.minimumRequestInterval)
        let delay = scheduled.timeIntervalSince(now)
        if delay > 0 {
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    /// - Parameter thinking: accepted for call-site uniformity with the other
    ///   services; OpenAI-compatible chat completions has no thinking toggle, so
    ///   it is ignored.
    func sendMessage(
        systemPrompt: String,
        userPrompt: String,
        model: String,
        maxTokens: Int = 4096,
        thinking: Bool = true,
        redactor: PIIRedactor? = nil
    ) async throws -> String {
        let systemPrompt = redactor?.redact(systemPrompt) ?? systemPrompt
        let userPrompt = redactor?.redact(userPrompt) ?? userPrompt
        let activityToken = await AIActivityCenter.shared.begin("Asking \(provider.displayName) (\(model))")
        defer { Task { @MainActor in AIActivityCenter.shared.end(activityToken) } }
        isProcessing = true
        lastError = nil
        defer { isProcessing = false }

        await waitForRateLimit()

        guard let apiKey = try KeychainHelper.loadString(forKey: provider.keychainKey),
              !apiKey.isEmpty else {
            let error = OpenAICompatibleError.missingAPIKey(provider: provider.displayName)
            lastError = error.localizedDescription
            throw error
        }

        guard let url = URL(string: "\(provider.baseURL)/chat/completions") else {
            throw OpenAICompatibleError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var messages: [[String: String]] = []
        if !systemPrompt.isEmpty {
            messages.append(["role": "system", "content": systemPrompt])
        }
        messages.append(["role": "user", "content": userPrompt])

        var body: [String: Any] = [
            "model": model,
            "messages": messages,
            provider.tokenParam.rawValue: max(maxTokens, 4096),
        ]
        if provider.sendsTemperature {
            body["temperature"] = 0.3
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        Logger.ai.info("Sending request to \(self.provider.displayName) API (model: \(model))")

        let text: String
        do {
            text = try await withRetry { [session] in
                let data: Data
                let response: URLResponse
                do {
                    (data, response) = try await session.data(for: request)
                } catch {
                    throw OpenAICompatibleError.networkError(error)
                }

                if data.count > Self.maxResponseBytes {
                    throw OpenAICompatibleError.responseTooLarge(data.count)
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw OpenAICompatibleError.httpError(statusCode: 0, message: "Invalid response type")
                }

                guard (200...299).contains(httpResponse.statusCode) else {
                    let message: String
                    if let errorResponse = try? JSONDecoder().decode(OpenAIErrorResponse.self, from: data) {
                        message = errorResponse.error.message
                    } else {
                        message = String(data: data, encoding: .utf8) ?? "Unknown error"
                    }
                    if httpResponse.statusCode == 429 {
                        let retryAfter: Int? = {
                            guard let raw = httpResponse.value(forHTTPHeaderField: "Retry-After"),
                                  let seconds = Int(raw.trimmingCharacters(in: .whitespaces)) else { return nil }
                            return seconds
                        }()
                        throw OpenAICompatibleError.rateLimited(retryAfterSeconds: retryAfter)
                    }
                    throw OpenAICompatibleError.httpError(statusCode: httpResponse.statusCode, message: message)
                }

                let decoded: OpenAIChatResponse
                do {
                    decoded = try JSONDecoder().decode(OpenAIChatResponse.self, from: data)
                } catch {
                    throw OpenAICompatibleError.decodingError(error)
                }

                guard let content = decoded.choices?.first?.message?.content, !content.isEmpty else {
                    throw OpenAICompatibleError.emptyResponse
                }

                if let usage = decoded.usage {
                    AppFileLogger.shared.log("\(self.provider.displayName): ok (\(model), \(usage.completion_tokens ?? 0) out tokens)")
                }
                return content
            }
        } catch {
            lastError = error.localizedDescription
            Logger.ai.error("\(self.provider.displayName) API error: \(error.localizedDescription)")
            if case OpenAICompatibleError.rateLimited(let hint) = error {
                AppFileLogger.shared.log("\(provider.displayName): request failed — HTTP 429 rate limited\(hint.map { " (retry after \($0)s)" } ?? "")")
            } else if case OpenAICompatibleError.httpError(let status, let msg) = error {
                AppFileLogger.shared.log("\(provider.displayName): request failed — HTTP \(status): \(msg)")
            } else {
                AppFileLogger.shared.log("\(provider.displayName): request failed — \(error.localizedDescription)")
            }
            throw error
        }

        return redactor?.restore(text) ?? text
    }

    private func withRetry<T>(maxAttempts: Int = 3, operation: () async throws -> T) async throws -> T {
        var lastError: Error?
        for attempt in 0..<maxAttempts {
            do {
                return try await operation()
            } catch {
                lastError = error
                if case OpenAICompatibleError.httpError(let statusCode, _) = error,
                   [400, 401, 403].contains(statusCode) {
                    throw error
                }
                if attempt < maxAttempts - 1 {
                    let delay: Double
                    if case OpenAICompatibleError.rateLimited(let hint) = error, let seconds = hint {
                        delay = min(60.0, max(0.1, Double(seconds)))
                    } else {
                        delay = pow(2.0, Double(attempt)) + Double.random(in: 0...1)
                    }
                    try? await Task.sleep(for: .seconds(delay))
                }
            }
        }
        throw lastError ?? OpenAICompatibleError.networkError(URLError(.unknown))
    }

    /// Lightweight key/connectivity check for the settings Save/Test button.
    func testConnection(model: String? = nil) async -> Bool {
        do {
            let reply = try await sendMessage(
                systemPrompt: "You are a helpful assistant.",
                userPrompt: "Reply with exactly: OK",
                model: model ?? provider.defaultTestModel,
                maxTokens: 16
            )
            return !reply.isEmpty
        } catch {
            Logger.ai.warning("\(self.provider.displayName) connection test failed: \(error.localizedDescription)")
            return false
        }
    }
}

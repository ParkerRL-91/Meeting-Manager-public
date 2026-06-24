import Foundation
import os

// MARK: - API Types (Google Generative Language API — generateContent)

private struct GeminiRequest: Encodable {
    let systemInstruction: SystemInstruction?
    let contents: [Content]
    let generationConfig: GenerationConfig

    enum CodingKeys: String, CodingKey {
        case systemInstruction = "system_instruction"
        case contents
        case generationConfig
    }

    struct SystemInstruction: Encodable { let parts: [Part] }
    struct Content: Encodable { let role: String; let parts: [Part] }
    struct Part: Encodable { let text: String }
    struct GenerationConfig: Encodable {
        let maxOutputTokens: Int
        let temperature: Double
        let thinkingConfig: ThinkingConfig?   // nil → key omitted from JSON
    }
    struct ThinkingConfig: Encodable { let thinkingBudget: Int }
}

private struct GeminiResponse: Decodable {
    let candidates: [Candidate]?
    let promptFeedback: PromptFeedback?
    let usageMetadata: UsageMetadata?

    struct Candidate: Decodable {
        let content: Content?
        let finishReason: String?
    }
    struct Content: Decodable { let parts: [Part]? }
    struct Part: Decodable { let text: String? }
    struct PromptFeedback: Decodable { let blockReason: String? }
    struct UsageMetadata: Decodable {
        let promptTokenCount: Int?
        let candidatesTokenCount: Int?
    }
}

private struct GeminiErrorResponse: Decodable {
    let error: ErrorDetail
    struct ErrorDetail: Decodable {
        let code: Int?
        let message: String
        let status: String?
    }
}

// MARK: - GeminiServiceError

enum GeminiServiceError: LocalizedError {
    case missingAPIKey
    case invalidURL
    case rateLimited(retryAfterSeconds: Int?)
    case httpError(statusCode: Int, message: String)
    case emptyResponse
    case blockedBySafety(String)
    case networkError(Error)
    case decodingError(Error)
    case responseTooLarge(Int)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Gemini API key is not configured. Add your key in Settings."
        case .invalidURL:
            return "Invalid Gemini API endpoint URL."
        case .rateLimited(let retryAfter):
            if let seconds = retryAfter {
                return "Rate limited by Gemini API. Try again in \(seconds) seconds."
            }
            return "Rate limited by Gemini API. Please wait a moment and try again."
        case .httpError(let statusCode, let message):
            return "Gemini API error (\(statusCode)): \(message)"
        case .emptyResponse:
            return "Gemini returned an empty response."
        case .blockedBySafety(let reason):
            return "Gemini blocked the request (\(reason))."
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .decodingError(let error):
            return "Failed to parse Gemini response: \(error.localizedDescription)"
        case .responseTooLarge(let bytes):
            return "Gemini response too large (\(bytes / 1024)KB). Maximum allowed is 1MB."
        }
    }
}

// MARK: - GeminiService

/// Communicates with the Google Generative Language API using URLSession.
/// Mirrors ClaudeService: same public surface, retry, rate-limit, and redactor
/// handling. Used for every AI function when Gemini is the selected provider.
@Observable
@MainActor
final class GeminiService {

    private(set) var isProcessing = false
    private(set) var lastError: String?

    private static let apiBase = "https://generativelanguage.googleapis.com/v1beta/models"
    private let session: URLSession

    private var lastRequestTime: Date?
    private let minimumRequestInterval: TimeInterval = 1.0
    private static let maxResponseBytes = 1_048_576

    init(session: URLSession = .shared) {
        self.session = session
    }

    private func waitForRateLimit() async {
        if let last = lastRequestTime {
            let elapsed = Date().timeIntervalSince(last)
            if elapsed < minimumRequestInterval {
                try? await Task.sleep(for: .seconds(minimumRequestInterval - elapsed))
            }
        }
        lastRequestTime = Date()
    }

    /// Sends a single-turn message and returns the model's text reply.
    /// - Parameter thinking: when false, disables Gemini 2.5 "thinking"
    ///   (thinkingBudget 0) for short structured tasks (attribution, titles)
    ///   so reasoning can't consume the whole output budget.
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
        let activityToken = await AIActivityCenter.shared.begin("Asking Gemini (\(model))")
        defer { Task { @MainActor in AIActivityCenter.shared.end(activityToken) } }
        isProcessing = true
        lastError = nil
        defer { isProcessing = false }

        await waitForRateLimit()

        guard let apiKey = try KeychainHelper.loadString(forKey: KeychainHelper.Key.geminiAPIKey),
              !apiKey.isEmpty else {
            let error = GeminiServiceError.missingAPIKey
            lastError = error.localizedDescription
            throw error
        }

        guard let url = URL(string: "\(Self.apiBase)/\(model):generateContent") else {
            throw GeminiServiceError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = GeminiRequest(
            systemInstruction: systemPrompt.isEmpty
                ? nil
                : .init(parts: [.init(text: systemPrompt)]),
            contents: [.init(role: "user", parts: [.init(text: userPrompt)])],
            generationConfig: .init(
                maxOutputTokens: max(maxTokens, 4096),
                temperature: 0.3,
                thinkingConfig: thinking ? nil : .init(thinkingBudget: 0)
            )
        )
        request.httpBody = try JSONEncoder().encode(body)

        Logger.ai.info("Sending request to Gemini API (model: \(model))")

        let text: String
        do {
            text = try await withRetry { [session] in
                let data: Data
                let response: URLResponse
                do {
                    (data, response) = try await session.data(for: request)
                } catch {
                    throw GeminiServiceError.networkError(error)
                }

                if data.count > Self.maxResponseBytes {
                    throw GeminiServiceError.responseTooLarge(data.count)
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw GeminiServiceError.httpError(statusCode: 0, message: "Invalid response type")
                }

                guard (200...299).contains(httpResponse.statusCode) else {
                    let message: String
                    if let errorResponse = try? JSONDecoder().decode(GeminiErrorResponse.self, from: data) {
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
                        throw GeminiServiceError.rateLimited(retryAfterSeconds: retryAfter)
                    }
                    throw GeminiServiceError.httpError(
                        statusCode: httpResponse.statusCode,
                        message: message
                    )
                }

                let decoded: GeminiResponse
                do {
                    decoded = try JSONDecoder().decode(GeminiResponse.self, from: data)
                } catch {
                    throw GeminiServiceError.decodingError(error)
                }

                if let block = decoded.promptFeedback?.blockReason {
                    throw GeminiServiceError.blockedBySafety(block)
                }

                guard let candidate = decoded.candidates?.first else {
                    throw GeminiServiceError.emptyResponse
                }

                let textOut = (candidate.content?.parts ?? []).compactMap { $0.text }.joined()
                if textOut.isEmpty {
                    if let reason = candidate.finishReason,
                       ["SAFETY", "BLOCKLIST", "PROHIBITED_CONTENT", "RECITATION", "OTHER", "LANGUAGE"].contains(reason) {
                        throw GeminiServiceError.blockedBySafety(reason)
                    }
                    throw GeminiServiceError.emptyResponse
                }

                if let usage = decoded.usageMetadata {
                    Logger.ai.info("Gemini response: \(usage.promptTokenCount ?? 0) input tokens, \(usage.candidatesTokenCount ?? 0) output tokens")
                }

                return textOut
            }
        } catch {
            lastError = error.localizedDescription
            Logger.ai.error("Gemini API error: \(error.localizedDescription)")
            throw error
        }

        return redactor?.restore(text) ?? text
    }

    /// Retries with exponential backoff. Does NOT retry on 400/401/403.
    private func withRetry<T>(maxAttempts: Int = 3, operation: () async throws -> T) async throws -> T {
        var lastError: Error?
        for attempt in 0..<maxAttempts {
            do {
                return try await operation()
            } catch {
                lastError = error
                if case GeminiServiceError.httpError(let statusCode, _) = error,
                   [400, 401, 403].contains(statusCode) {
                    throw error
                }
                if attempt < maxAttempts - 1 {
                    let delay: Double
                    if case GeminiServiceError.rateLimited(let hint) = error, let seconds = hint {
                        delay = min(60.0, max(0.1, Double(seconds)))
                    } else {
                        delay = pow(2.0, Double(attempt)) + Double.random(in: 0...1)
                    }
                    try? await Task.sleep(for: .seconds(delay))
                }
            }
        }
        throw lastError ?? GeminiServiceError.networkError(URLError(.unknown))
    }

    /// Lightweight key/connectivity check used by the settings Test button.
    func testConnection() async -> Bool {
        do {
            let reply = try await sendMessage(
                systemPrompt: "You are a helpful assistant.",
                userPrompt: "Reply with exactly: OK",
                model: "gemini-2.5-flash",
                thinking: false
            )
            return !reply.isEmpty
        } catch {
            Logger.ai.warning("Gemini connection test failed: \(error.localizedDescription)")
            return false
        }
    }
}

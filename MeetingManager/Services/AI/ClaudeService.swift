import Foundation
import os

// MARK: - API Types

/// Request body for the Anthropic Messages API.
private struct ClaudeRequest: Encodable {
    let model: String
    let max_tokens: Int
    let system: String
    let messages: [ClaudeMessage]
}

private struct ClaudeMessage: Codable {
    let role: String
    let content: String
}

/// Top-level response from the Anthropic Messages API.
private struct ClaudeResponse: Decodable {
    let id: String
    let content: [ContentBlock]
    let model: String
    let stop_reason: String?
    let usage: Usage

    struct ContentBlock: Decodable {
        let type: String
        let text: String?
    }

    struct Usage: Decodable {
        let input_tokens: Int
        let output_tokens: Int
    }
}

/// Error response returned by the Anthropic API.
private struct ClaudeErrorResponse: Decodable {
    let type: String
    let error: ErrorDetail

    struct ErrorDetail: Decodable {
        let type: String
        let message: String
    }
}

// MARK: - ClaudeServiceError

enum ClaudeServiceError: LocalizedError {
    case missingAPIKey
    case invalidAPIKey
    case rateLimited(retryAfterSeconds: Int?)
    case invalidURL
    case httpError(statusCode: Int, message: String)
    case emptyResponse
    case networkError(Error)
    case decodingError(Error)
    case aiDisabled
    case responseTooLarge(Int)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Claude API key is not configured. Add your key in Settings."
        case .invalidAPIKey:
            return "Your Claude API key is invalid or expired. Please update it in Settings."
        case .rateLimited(let retryAfter):
            if let seconds = retryAfter {
                return "Rate limited by Claude API. Try again in \(seconds) seconds."
            }
            return "Rate limited by Claude API. Please wait a moment and try again."
        case .invalidURL:
            return "Invalid API endpoint URL."
        case .httpError(let statusCode, let message):
            return "API error (\(statusCode)): \(message)"
        case .emptyResponse:
            return "The API returned an empty response."
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .decodingError(let error):
            return "Failed to parse API response: \(error.localizedDescription)"
        case .aiDisabled:
            return "AI features are disabled. Enable them in Settings under Claude."
        case .responseTooLarge(let bytes):
            return "API response too large (\(bytes / 1024)KB). Maximum allowed is 1MB."
        }
    }
}

// MARK: - ClaudeService

/// Communicates with the Anthropic Messages API using URLSession.
@Observable
@MainActor
final class ClaudeService {

    // MARK: - Public State

    private(set) var isProcessing = false
    private(set) var lastError: String?

    // MARK: - Private

    private static let apiURL = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let apiVersion = "2023-06-01"
    private let session: URLSession

    /// Client-side rate limiting: minimum interval between consecutive API requests.
    private var lastRequestTime: Date?
    private let minimumRequestInterval: TimeInterval = 1.0

    /// Maximum response body size we'll accept before decoding (1 MB).
    private static let maxResponseBytes = 1_048_576

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Waits if necessary to enforce the minimum interval between requests,
    /// preventing the client from hammering the API during rapid-fire operations.
    private func waitForRateLimit() async {
        if let last = lastRequestTime {
            let elapsed = Date().timeIntervalSince(last)
            if elapsed < minimumRequestInterval {
                try? await Task.sleep(for: .seconds(minimumRequestInterval - elapsed))
            }
        }
        lastRequestTime = Date()
    }

    // MARK: - Public API

    /// Sends a message to the Claude API and returns the assistant's text reply.
    ///
    /// - Parameters:
    ///   - systemPrompt: The system-level instruction.
    ///   - userPrompt: The user message content.
    ///   - model: The model identifier (e.g. "claude-sonnet-4-20250514").
    /// - Returns: The text content of the first response block.
    func sendMessage(systemPrompt: String, userPrompt: String, model: String) async throws -> String {
        isProcessing = true
        lastError = nil
        defer { isProcessing = false }

        // 0. Rate limit — wait if we sent a request too recently
        await waitForRateLimit()

        // 1. Load API key
        guard let apiKey = try KeychainHelper.loadString(forKey: KeychainHelper.Key.claudeAPIKey),
              !apiKey.isEmpty else {
            let error = ClaudeServiceError.missingAPIKey
            lastError = error.localizedDescription
            throw error
        }

        // 2. Build request
        var request = URLRequest(url: Self.apiURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ClaudeRequest(
            model: model,
            max_tokens: 4096,
            system: systemPrompt,
            messages: [ClaudeMessage(role: "user", content: userPrompt)]
        )

        let encoder = JSONEncoder()
        request.httpBody = try encoder.encode(body)

        Logger.ai.info("Sending request to Claude API (model: \(model))")

        // 3. Execute request with retry (retries on network errors, 429, 5xx)
        let text: String
        do {
        text = try await withRetry { [session] in
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                throw ClaudeServiceError.networkError(error)
            }

            // 3b. Reject unexpectedly large responses before attempting to decode
            if data.count > Self.maxResponseBytes {
                throw ClaudeServiceError.responseTooLarge(data.count)
            }

            // 4. Check HTTP status
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ClaudeServiceError.httpError(statusCode: 0, message: "Invalid response type")
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                let message: String
                if let errorResponse = try? JSONDecoder().decode(ClaudeErrorResponse.self, from: data) {
                    message = errorResponse.error.message
                } else {
                    message = String(data: data, encoding: .utf8) ?? "Unknown error"
                }
                throw ClaudeServiceError.httpError(
                    statusCode: httpResponse.statusCode,
                    message: message
                )
            }

            // 5. Decode response
            let claudeResponse: ClaudeResponse
            do {
                claudeResponse = try JSONDecoder().decode(ClaudeResponse.self, from: data)
            } catch {
                throw ClaudeServiceError.decodingError(error)
            }

            // 6. Extract text
            guard let responseText = claudeResponse.content.first(where: { $0.type == "text" })?.text,
                  !responseText.isEmpty else {
                throw ClaudeServiceError.emptyResponse
            }

            Logger.ai.info("Received response: \(claudeResponse.usage.input_tokens) input tokens, \(claudeResponse.usage.output_tokens) output tokens")

            return responseText
        }
        } catch {
            lastError = error.localizedDescription
            Logger.ai.error("Claude API error: \(error.localizedDescription)")
            throw error
        }

        return text
    }

    // MARK: - Retry Helper

    /// Retries an operation with exponential backoff. Does NOT retry on 400/401/403 client errors.
    private func withRetry<T>(maxAttempts: Int = 3, operation: () async throws -> T) async throws -> T {
        var lastError: Error?
        for attempt in 0..<maxAttempts {
            do {
                return try await operation()
            } catch {
                lastError = error
                // Don't retry on client errors (400, 401, 403)
                if case ClaudeServiceError.httpError(let statusCode, _) = error,
                   [400, 401, 403].contains(statusCode) {
                    throw error
                }
                if attempt < maxAttempts - 1 {
                    let delay = pow(2.0, Double(attempt)) + Double.random(in: 0...1)
                    try? await Task.sleep(for: .seconds(delay))
                }
            }
        }
        // Fallback: withRetry is only ever entered with maxAttempts >= 1, so lastError
        // will be set if we reach here. Guard defensively anyway — we must never crash
        // the app from a network retry path.
        throw lastError ?? ClaudeServiceError.networkError(URLError(.unknown))
    }

    /// Performs a lightweight request to verify the API key and connectivity.
    func testConnection() async -> Bool {
        do {
            let reply = try await sendMessage(
                systemPrompt: "You are a helpful assistant.",
                userPrompt: "Reply with exactly: OK",
                model: Constants.Defaults.aiModel
            )
            return !reply.isEmpty
        } catch {
            Logger.ai.warning("Connection test failed: \(error.localizedDescription)")
            return false
        }
    }
}

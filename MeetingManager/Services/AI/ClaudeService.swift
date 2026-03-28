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
    case invalidURL
    case httpError(statusCode: Int, message: String)
    case emptyResponse
    case networkError(Error)
    case decodingError(Error)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Claude API key is not configured. Add your key in Settings."
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

    init(session: URLSession = .shared) {
        self.session = session
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

        // 3. Execute request
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            let serviceError = ClaudeServiceError.networkError(error)
            lastError = serviceError.localizedDescription
            Logger.ai.error("Network error: \(error.localizedDescription)")
            throw serviceError
        }

        // 4. Check HTTP status
        guard let httpResponse = response as? HTTPURLResponse else {
            let serviceError = ClaudeServiceError.httpError(statusCode: 0, message: "Invalid response type")
            lastError = serviceError.localizedDescription
            throw serviceError
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let message: String
            if let errorResponse = try? JSONDecoder().decode(ClaudeErrorResponse.self, from: data) {
                message = errorResponse.error.message
            } else {
                message = String(data: data, encoding: .utf8) ?? "Unknown error"
            }
            let serviceError = ClaudeServiceError.httpError(
                statusCode: httpResponse.statusCode,
                message: message
            )
            lastError = serviceError.localizedDescription
            Logger.ai.error("API error \(httpResponse.statusCode): \(message)")
            throw serviceError
        }

        // 5. Decode response
        let claudeResponse: ClaudeResponse
        do {
            claudeResponse = try JSONDecoder().decode(ClaudeResponse.self, from: data)
        } catch {
            let serviceError = ClaudeServiceError.decodingError(error)
            lastError = serviceError.localizedDescription
            Logger.ai.error("Decoding error: \(error.localizedDescription)")
            throw serviceError
        }

        // 6. Extract text
        guard let text = claudeResponse.content.first(where: { $0.type == "text" })?.text,
              !text.isEmpty else {
            let serviceError = ClaudeServiceError.emptyResponse
            lastError = serviceError.localizedDescription
            throw serviceError
        }

        Logger.ai.info("Received response: \(claudeResponse.usage.input_tokens) input tokens, \(claudeResponse.usage.output_tokens) output tokens")

        return text
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

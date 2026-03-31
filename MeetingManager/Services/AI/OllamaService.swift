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
    let stream: Bool = false
    let options: OllamaOptions?
}

private struct OllamaOptions: Encodable {
    let temperature: Double
    let num_predict: Int
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

    // MARK: - Status

    private(set) var isReachable = false
    private(set) var availableModels: [String] = []
    private(set) var isCheckingStatus = false

    // MARK: - Text Generation

    /// Generate a response given a system prompt and user message using the specified model.
    func generate(systemPrompt: String, userPrompt: String, model: String) async throws -> String {
        let url = Self.baseURL.appendingPathComponent("api/chat")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300  // LLM generation can be slow

        let body = OllamaChatRequest(
            model: model,
            messages: [
                OllamaMessage(role: "system", content: systemPrompt),
                OllamaMessage(role: "user", content: userPrompt),
            ],
            options: OllamaOptions(temperature: 0.3, num_predict: 1024)
        )
        request.httpBody = try JSONEncoder().encode(body)

        Logger.ai.info("Sending request to Ollama (model: \(model))")

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

        Logger.ai.info("Ollama response received (\(text.count) chars)")
        return text
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

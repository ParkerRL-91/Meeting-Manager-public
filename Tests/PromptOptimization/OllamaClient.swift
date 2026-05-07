import Foundation

/// Minimal Ollama HTTP client for the prompt-eval harness. Intentionally
/// independent of `MeetingManager.OllamaService` (that's @MainActor + bound
/// to AppDatabase) — the harness needs a plain async-callable surface.
struct OllamaClient {
    let baseURL: URL

    init(baseURL: URL = URL(string: "http://localhost:11434")!) {
        self.baseURL = baseURL
    }

    struct GenerateOptions {
        var temperature: Double = 0.3
        var numPredict: Int = 4096
        var numCtx: Int = 32768
    }

    struct GenerateResult {
        let text: String
        let elapsedSeconds: Double
        let evalCount: Int?
    }

    /// Calls /api/generate and returns the response body. Times the call so
    /// rubrics can flag slow candidates. Errors surface as throws for clean
    /// per-fixture handling.
    func generate(
        model: String,
        systemPrompt: String,
        userPrompt: String,
        options: GenerateOptions = GenerateOptions()
    ) async throws -> GenerateResult {
        let url = baseURL.appendingPathComponent("api/generate")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Generous timeout — Qwen3 8B on a long transcript can run several
        // minutes. The harness can re-run individual fixtures so we'd rather
        // wait it out than retry mid-eval.
        request.timeoutInterval = 1200

        let body: [String: Any] = [
            "model": model,
            "system": systemPrompt,
            "prompt": userPrompt,
            "stream": false,
            "options": [
                "temperature": options.temperature,
                "num_predict": options.numPredict,
                "num_ctx": options.numCtx,
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let start = Date()
        let (data, _) = try await URLSession.shared.data(for: request)
        let elapsed = Date().timeIntervalSince(start)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["response"] as? String else {
            throw NSError(domain: "OllamaClient", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Malformed response — no 'response' field"
            ])
        }
        let evalCount = json["eval_count"] as? Int
        return GenerateResult(text: text, elapsedSeconds: elapsed, evalCount: evalCount)
    }
}

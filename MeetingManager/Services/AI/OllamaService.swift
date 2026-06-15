import Foundation
import os

// MARK: - Ollama API Types

private struct OllamaMessage: Codable {
    let role: String
    let content: String
}

/// Minimal JSON tree so `format` can carry either the literal "json"
/// string or a full JSON-schema object (Ollama grammar-constrains output
/// to the schema — TASK-046). No external AnyCodable dependency.
enum OllamaJSONValue: Encodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([OllamaJSONValue])
    case object([String: OllamaJSONValue])

    init?(any value: Any) {
        switch value {
        case let s as String: self = .string(s)
        case let b as Bool: self = .bool(b)
        case let n as NSNumber: self = .number(n.doubleValue)
        case let a as [Any]:
            var items: [OllamaJSONValue] = []
            for v in a { guard let j = OllamaJSONValue(any: v) else { return nil }; items.append(j) }
            self = .array(items)
        case let d as [String: Any]:
            var obj: [String: OllamaJSONValue] = [:]
            for (k, v) in d { guard let j = OllamaJSONValue(any: v) else { return nil }; obj[k] = j }
            self = .object(obj)
        case is NSNull: self = .null
        default: return nil
        }
    }

    /// Parse a JSON-schema string into the encodable tree. Returns nil on
    /// malformed input so callers can degrade to plain "json" mode.
    static func schema(fromJSON json: String) -> OllamaJSONValue? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return OllamaJSONValue(any: obj)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

private struct OllamaChatRequest: Encodable {
    let model: String
    let messages: [OllamaMessage]
    let stream: Bool
    /// Thinking-model toggle (qwen3, deepseek-r1). nil = model default.
    /// Setting false skips the chain-of-thought phase — much faster for
    /// simple tasks (classification, bounded summarization) that don't need it.
    let think: Bool?
    /// Constrained output: .string("json") forces syntactically valid JSON;
    /// a schema object grammar-constrains the output to that exact shape
    /// (eliminates the parse-failure class on small models — TASK-046).
    let format: OllamaJSONValue?
    let options: OllamaOptions?
    init(model: String, messages: [OllamaMessage], stream: Bool = false,
         think: Bool? = nil, format: OllamaJSONValue? = nil, options: OllamaOptions?) {
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
    // Sent only for qwen3 thinking-mode calls (official card: 0.95 / 20);
    // nil leaves Ollama's defaults in place for every other model.
    let top_p: Double?
    let top_k: Int?

    init(temperature: Double, num_predict: Int, num_ctx: Int? = nil,
         top_p: Double? = nil, top_k: Int? = nil) {
        self.temperature = temperature
        self.num_predict = num_predict
        self.num_ctx = num_ctx
        self.top_p = top_p
        self.top_k = top_k
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
    /// installed model that can handle the input size. Window values must
    /// stay within `modelContextLimit` for the tier's model — the top rung is
    /// 40 960 because that is qwen3's TRAINED window (the "128K" headline
    /// number is YaRN-extended, which Ollama's default tags don't enable;
    /// requesting num_ctx past the trained window silently degrades
    /// attention rather than erroring). At runtime every tier is further
    /// clamped to `ramContextCap` — the table expresses model capability,
    /// the cap expresses what this machine can hold (ADR-015).
    static let modelTiers: [(name: String, maxInputTokens: Int, contextWindow: Int)] = [
        // NOTE: explicit "qwen3:4b"/"qwen3:8b" rather than Self.smallTier — Swift
        // won't let a static stored property reference Self in its initializer.
        // Keep these identifiers in sync with smallTier / defaultTier above.
        ("qwen3:4b",  4000,   8192),   // Fast — short 1:1s
        ("qwen3:4b",  8000,  16384),   // Medium — standard meetings
        ("qwen3:4b", 14000,  32768),   // Large — extended meetings
        ("qwen3:8b", 22000,  32768),   // XL — long meetings, better reasoning
        ("qwen3:8b", 32000,  40960),   // XXL — marathon sessions, full trained window
    ]

    /// Trained context window per model family. Ollama accepts any num_ctx
    /// without complaint, but positions beyond the trained window get
    /// effectively random attention — a silent quality collapse, not an
    /// error. Qwen3 tags ship with max_position_embeddings 40960 (the 2507
    /// 4b refresh goes higher, but the tag name can't tell us which build a
    /// user pulled, so the safe floor applies to the whole family).
    /// Llama 3.1/3.2 trained at 128K but degrade well before it at Q4 —
    /// 65 536 matches the "effective 65K" treatment in the tier fallback.
    static func modelContextLimit(for model: String) -> Int {
        if model.contains("llama3.1") || model.contains("llama3.2") { return 65_536 }
        if model.contains("qwen2.5") { return 32_768 }
        if model.contains("qwen3") { return 40_960 }
        return 32_768  // unknown models: conservative middle ground
    }

    // MARK: - RAM-Aware Context Sizing (ADR-015)

    /// Extra `num_predict` headroom when `think` is sent: Ollama counts
    /// thinking tokens against `num_predict`, so without a reserve, Qwen3 can
    /// exhaust the whole budget mid-reasoning — the visible answer comes back
    /// empty and the thinking-fallback path returns raw chain-of-thought.
    static let thinkingAllowance = 4096

    /// num_ctx ceiling for this machine's unified memory. Qwen3's KV cache
    /// (4b and 8b share the geometry: 36 layers × 8 KV heads × 128 dims, f16)
    /// costs ~144 KiB per context token: 16K ctx ≈ 2.3 GB, 64K ≈ 9.2 GB,
    /// 128K ≈ 18.4 GB — on top of ~5.2 GB of qwen3:8b weights. Exceeding the
    /// Metal working-set budget (~⅔ of RAM) doesn't fail cleanly: Ollama
    /// spills to CPU/swap and a 2-minute summary takes an hour while the app,
    /// WhisperKit, and macOS fight for the same unified memory. Bands keep
    /// weights + KV under ~60% of physical RAM on the 16 GB M4 baseline.
    static let ramContextCap = contextCap(forPhysicalMemoryBytes: ProcessInfo.processInfo.physicalMemory)

    /// Pure banding so the policy is unit-testable: <24 GiB → 16K,
    /// <32 GiB → 32K, <48 GiB → 64K, otherwise the qwen3 native 128K max.
    static func contextCap(forPhysicalMemoryBytes bytes: UInt64) -> Int {
        let gib = Double(bytes) / 1_073_741_824
        if gib >= 48 { return 131_072 }
        if gib >= 32 { return 65_536 }
        if gib >= 24 { return 32_768 }
        return 16_384
    }

    /// Size the context window for a request and decide whether the input
    /// must be truncated client-side. Buckets `input + output` up to the next
    /// power-of-two rung (Ollama reallocates the KV cache per `num_ctx`, so
    /// tight windows avoid multi-minute stalls), then clamps to the RAM cap.
    /// When the capped window can't fit everything, output keeps at most half
    /// the window and the returned `inputTokenBudget` is what remains for the
    /// prompt — the caller truncates rather than letting Ollama silently drop
    /// the start of the conversation server-side.
    static func resolveSizing(
        inputTokens: Int,
        requestedPredict: Int,
        cap: Int
    ) -> (numCtx: Int, inputTokenBudget: Int?) {
        let needed = inputTokens + requestedPredict
        let bucket: Int
        if needed <= 8192        { bucket = 8192 }
        else if needed <= 16384  { bucket = 16384 }
        else if needed <= 32768  { bucket = 32768 }
        else if needed <= 65536  { bucket = 65536 }
        else                     { bucket = 131_072 }
        let numCtx = min(bucket, cap)
        if needed <= numCtx { return (numCtx, nil) }
        let predict = min(requestedPredict, numCtx / 2)
        return (numCtx, numCtx - predict)
    }

    /// Head/tail truncation for prompts that exceed the context budget: keep
    /// the first 10% (intro/agenda) and the last 90% of the allowance
    /// (decisions and action items cluster late in a meeting), joined by an
    /// explicit notice so the model knows material was cut. Returns the
    /// prompt unchanged when it fits or when the budget is degenerate.
    static func truncatedUserPrompt(_ userPrompt: String, maxUserChars: Int) -> String {
        guard userPrompt.count > maxUserChars, maxUserChars > 0 else { return userPrompt }
        let keepStart = maxUserChars / 10
        let keepEnd = maxUserChars - keepStart - 100 // 100 chars for the truncation notice
        guard keepEnd > 0 else { return userPrompt }
        let start = String(userPrompt.prefix(keepStart))
        let end = String(userPrompt.suffix(keepEnd))
        return start + "\n\n[... transcript truncated for length ...]\n\n" + end
    }

    // MARK: - Status

    /// In-flight local generations across ALL callers — queue handlers,
    /// prep enrichment, chat, catch-me-up, embeddings (review B2: busy
    /// detection lives at this chokepoint, never by enumerating task
    /// types). Label = what the user-facing "busy with…" should say.
    private(set) var inFlightCount = 0
    private(set) var inFlightLabel: String?

    private var activityTokens: [UUID] = []

    func beginWork(label: String) {
        inFlightCount += 1
        inFlightLabel = label
        activityTokens.append(AIActivityCenter.shared.begin(label))
    }

    /// Fired each time inFlightCount returns to zero — the broker's drain
    /// signal (TASK-071).
    var onAllWorkFinished: (() -> Void)?

    func endWork() {
        inFlightCount = max(0, inFlightCount - 1)
        if let token = activityTokens.popLast() {
            AIActivityCenter.shared.end(token)
        }
        if inFlightCount == 0 {
            inFlightLabel = nil
            onAllWorkFinished?()
        }
    }

    private(set) var isReachable = false
    private(set) var availableModels: [String] = []
    private(set) var isCheckingStatus = false

    // MARK: - Adaptive Model Selection

    /// Selects the best model and context window for the given input.
    /// Returns (model, contextWindow, truncatedPrompt) — the prompt is
    /// truncated only if no installed model can fit the full input within
    /// this machine's RAM-capped window. `outputReserve` is the caller's
    /// real `num_predict` budget (including any thinking allowance) so the
    /// fit check reserves what generation will actually consume.
    func adaptiveSelect(
        systemPrompt: String,
        userPrompt: String,
        outputReserve: Int = 2048
    ) -> (model: String, numCtx: Int, systemPrompt: String, userPrompt: String) {
        let totalChars = systemPrompt.count + userPrompt.count
        // Rough token estimate: ~4 chars per token for English
        let estimatedTokens = totalChars / 4
        let cap = Self.ramContextCap

        let models = self.availableModels
        Logger.ai.info("Adaptive select: ~\(estimatedTokens) input tokens, \(models.count) models available, ctx cap \(cap)")

        // Walk tiers from smallest to largest, pick the first that fits AND is installed
        for tier in Self.modelTiers {
            guard models.contains(where: { $0.hasPrefix(tier.name.components(separatedBy: ":").first ?? tier.name) && $0.contains(tier.name.components(separatedBy: ":").last ?? "") }) || models.contains(tier.name) else {
                continue
            }
            let tierCtx = min(tier.contextWindow, cap)
            if estimatedTokens + outputReserve <= tierCtx {
                Logger.ai.info("Adaptive: selected \(tier.name) ctx=\(tierCtx) for ~\(estimatedTokens) tokens")
                return (tier.name, tierCtx, systemPrompt, userPrompt)
            }
        }

        // No tier fits — use the largest available model with truncation.
        // Prefer the new Qwen3 tier when present; fall back to the legacy
        // Llama 3.1 8B for users who only ever pulled the old default and
        // haven't yet picked up the Qwen upgrade.
        let bestModel: String
        if models.contains(Self.defaultTier) {
            bestModel = Self.defaultTier
        } else if models.contains("llama3.1:8b") {
            bestModel = "llama3.1:8b"
        } else {
            bestModel = models.first ?? Self.defaultModel
        }
        let bestCtx = min(Self.modelContextLimit(for: bestModel), cap)

        // Truncate: keep system prompt + first 10% of user prompt (intro/agenda)
        // + last 90% (decisions/actions). Output keeps at most half the window
        // so a large reserve can never squeeze the input budget to nothing.
        let effectiveReserve = min(outputReserve, bestCtx / 2)
        let maxUserChars = (bestCtx - effectiveReserve) * 4 - systemPrompt.count
        let truncatedUser = Self.truncatedUserPrompt(userPrompt, maxUserChars: maxUserChars)
        if truncatedUser.count < userPrompt.count {
            Logger.ai.info("Adaptive: truncated \(userPrompt.count) → \(truncatedUser.count) chars for \(bestModel) ctx=\(bestCtx)")
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
        jsonMode: Bool = false,
        // JSON-schema string for grammar-constrained output (TASK-046).
        // Takes precedence over jsonMode; degrades to plain "json" when the
        // schema doesn't parse or the server rejects it (older Ollama).
        schemaJSON: String? = nil,
        // Human-readable activity label (TASK-073) — what the Activities
        // list shows while this runs.
        activityLabel: String? = nil
    ) async throws -> String {
        let selectedModel: String
        let numCtx: Int
        let finalSystem: String
        let finalUser: String

        // num_predict counts thinking tokens too, so reserve headroom for the
        // reasoning phase whenever `think` will be sent — otherwise Qwen3 can
        // burn the whole budget mid-reasoning and return an empty answer.
        // "auto" only ever resolves to qwen3 tiers, so `think` alone decides.
        let thinkCapable = model == "auto" || model.contains("qwen3")
        let requestedPredict = maxOutputTokens + ((think && thinkCapable) ? Self.thinkingAllowance : 0)

        if model == "auto" {
            let selection = adaptiveSelect(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                outputReserve: requestedPredict
            )
            selectedModel = selection.model
            numCtx = selection.numCtx
            finalSystem = selection.systemPrompt
            finalUser = selection.userPrompt
        } else {
            selectedModel = model
            // Tight, RAM-capped window even for explicit models — Ollama's
            // own default would allocate a KV cache this machine can't hold
            // (ADR-015), and an oversized window stalls for minutes. Inputs
            // the capped window can't fit are truncated client-side; relying
            // on Ollama's silent server-side truncation drops the start of
            // the prompt, system instructions included.
            let estimatedTokens = (systemPrompt.count + userPrompt.count) / 4
            let sizing = Self.resolveSizing(
                inputTokens: estimatedTokens,
                requestedPredict: requestedPredict,
                cap: min(Self.ramContextCap, Self.modelContextLimit(for: model))
            )
            numCtx = sizing.numCtx
            finalSystem = systemPrompt
            if let inputBudget = sizing.inputTokenBudget {
                finalUser = Self.truncatedUserPrompt(
                    userPrompt,
                    maxUserChars: inputBudget * 4 - systemPrompt.count
                )
                Logger.ai.info("Ollama: ~\(estimatedTokens) input tokens exceed capped ctx \(numCtx) — truncated to ~\(finalUser.count / 4)")
            } else {
                finalUser = userPrompt
            }
        }

        // Final fit clamp: whichever path sized the window, generation must
        // leave room for the (possibly truncated) input inside num_ctx.
        let numPredict = min(requestedPredict, max(1024, numCtx - (finalSystem.count + finalUser.count) / 4))

        // Dynamic timeout: account for both input processing and output
        // generation. Qwen3's thinking mode can spend minutes reasoning
        // before emitting any output tokens, so the timeout must cover
        // thinking time (proportional to input) + generation time
        // (proportional to num_predict). Formula: ~1 min per 2K input
        // tokens + ~1 min per 4K output tokens, minimum 120s, max 1800s.
        let inputChars = finalSystem.count + finalUser.count
        let inputTime = Double(inputChars / 4) / 2000.0 * 60.0
        let outputTime = Double(numPredict) / 4000.0 * 60.0
        let estimatedSeconds = max(120, min(1800, inputTime + outputTime))

        let url = Self.baseURL.appendingPathComponent("api/chat")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = estimatedSeconds

        // Qwen3 thinking-mode sampling per the official model card:
        // temperature 0.6, top_p 0.95, top_k 20. Near-greedy temperatures
        // degrade hybrid-thinking models and can trigger endless repetition
        // loops mid-reasoning. 0.3 (with Ollama's default top_p/top_k) stays
        // for non-thinking models, where low-variance summarization is right.
        let isQwen3 = selectedModel.contains("qwen3")
        let schemaFormat = schemaJSON.flatMap { OllamaJSONValue.schema(fromJSON: $0) }
        let format: OllamaJSONValue? = schemaFormat ?? (jsonMode || schemaJSON != nil ? .string("json") : nil)

        // One send+decode for a given think flag. Retries up to 3× on
        // transient failures — network errors and 5xx. /api/chat is
        // idempotent (the model is the only mutable resource and we pass no
        // state-changing options), so re-sending is safe; 4xx/decode errors
        // are terminal. Match the ClaudeService backoff: 2^attempt + rand.
        func performChat(useThink: Bool) async throws -> OllamaChatResponse {
            let sendsThink = isQwen3 && useThink
            let body = OllamaChatRequest(
                model: selectedModel,
                messages: [
                    OllamaMessage(role: "system", content: finalSystem),
                    OllamaMessage(role: "user", content: finalUser),
                ],
                // Only send `think` to thinking-capable models (qwen3,
                // deepseek-r1). Instruct models don't support it and can
                // error/stall — omit so they just generate directly.
                think: isQwen3 ? useThink : nil,
                format: format,
                options: OllamaOptions(
                    temperature: sendsThink ? 0.6 : 0.3,
                    num_predict: numPredict,
                    num_ctx: numCtx > 0 ? numCtx : nil,
                    top_p: sendsThink ? 0.95 : nil,
                    top_k: sendsThink ? 20 : nil
                )
            )
            request.httpBody = try JSONEncoder().encode(body)
            return try await Self.withRetry(maxAttempts: 3) {
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
        }

        Logger.ai.info("Sending request to Ollama (model: \(selectedModel), ctx: \(numCtx > 0 ? "\(numCtx)" : "default"), maxOut: \(numPredict))")
        beginWork(label: activityLabel ?? "Generating (\(selectedModel))")
        defer { endWork() }

        var decoded = try await performChat(useThink: think)
        var text = Self.stripThinkBlock(decoded.message.content.trimmingCharacters(in: .whitespacesAndNewlines))

        // Empty content under think:true means Qwen3 spent its whole budget
        // reasoning and never emitted the answer — the reasoning sits in the
        // separate `thinking` field with NO </think> tag to strip. The old
        // code surfaced that raw reasoning as the answer, which is what put
        // chain-of-thought in the daily brief. Instead retry once with
        // think:false so the answer lands directly in `content` (any inline
        // tag is stripped); never present the reasoning field as output.
        if text.isEmpty && think && isQwen3 {
            Logger.ai.warning("Ollama: empty content under think:true — retrying think:false to avoid reasoning leak")
            decoded = try await performChat(useThink: false)
            text = Self.stripThinkBlock(decoded.message.content.trimmingCharacters(in: .whitespacesAndNewlines))
        }

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
        // Closed block (possibly inline): keep everything after the LAST
        // </think> — that's the real answer.
        if let closeRange = s.range(of: "</think>", options: .backwards) {
            return String(s[closeRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Opening <think> with no close: the model was cut off mid-reasoning
        // and never reached the answer. Drop from the tag onward (what
        // precedes it, usually nothing, is the only non-reasoning text) so
        // truncated chain-of-thought can't leak into the output.
        if let openRange = s.range(of: "<think>") {
            return String(s[..<openRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s
    }

    // MARK: - Streaming Generation (for task queue / long meetings)

    /// Generate a response using streaming — reads chunks incrementally so there's no
    /// single timeout. Ideal for long meetings processed in the background via the task queue.
    /// Never times out as long as Ollama keeps sending chunks.
    func generateStreaming(systemPrompt: String, userPrompt: String, model: String,
                           activityLabel: String? = nil) async throws -> String {
        let selectedModel: String
        let numCtx: Int
        let finalSystem: String
        let finalUser: String

        // 8192 covers thinking (1–3K on a long transcript) plus the longest
        // summary the app renders. num_predict counts thinking tokens, so
        // this is a combined budget, and the ctx sizing must reserve all of
        // it — the old +2048 reserve under-sized the window for long outputs.
        let requestedPredict = 8192

        if model == "auto" {
            let selection = adaptiveSelect(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                outputReserve: requestedPredict
            )
            selectedModel = selection.model
            numCtx = selection.numCtx
            finalSystem = selection.systemPrompt
            finalUser = selection.userPrompt
        } else {
            selectedModel = model
            // Same RAM-capped sizing + client-side truncation as generate()
            // (ADR-015) — see the comment there for why.
            let estimatedTokens = (systemPrompt.count + userPrompt.count) / 4
            let sizing = Self.resolveSizing(
                inputTokens: estimatedTokens,
                requestedPredict: requestedPredict,
                cap: min(Self.ramContextCap, Self.modelContextLimit(for: model))
            )
            numCtx = sizing.numCtx
            finalSystem = systemPrompt
            if let inputBudget = sizing.inputTokenBudget {
                finalUser = Self.truncatedUserPrompt(
                    userPrompt,
                    maxUserChars: inputBudget * 4 - systemPrompt.count
                )
                Logger.ai.info("Ollama stream: ~\(estimatedTokens) input tokens exceed capped ctx \(numCtx) — truncated to ~\(finalUser.count / 4)")
            } else {
                finalUser = userPrompt
            }
        }

        let numPredict = min(requestedPredict, max(1024, numCtx - (finalSystem.count + finalUser.count) / 4))

        let url = Self.baseURL.appendingPathComponent("api/chat")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // `timeoutInterval` is an IDLE timeout — it resets on every received
        // byte, so a healthy stream is never killed regardless of total
        // duration (thinking tokens stream too). 5 minutes with NOTHING on
        // the wire means a wedged server; the old 3600 s idle window could
        // hold the serial task queue hostage for an hour.
        request.timeoutInterval = 300

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
                // Streaming always sends think:true to qwen3 — use the
                // official thinking-mode sampling (see generate()).
                temperature: selectedModel.contains("qwen3") ? 0.6 : 0.3,
                num_predict: numPredict,
                num_ctx: numCtx > 0 ? numCtx : nil,
                top_p: selectedModel.contains("qwen3") ? 0.95 : nil,
                top_k: selectedModel.contains("qwen3") ? 20 : nil
            )
        )
        request.httpBody = try JSONEncoder().encode(body)

        Logger.ai.info("Streaming request to Ollama (model: \(selectedModel), ctx: \(numCtx))")

        beginWork(label: activityLabel ?? "Generating (\(selectedModel))")
        defer { endWork() }
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: request)
        } catch {
            if (error as? URLError)?.code == .timedOut { throw OllamaServiceError.timedOut }
            throw OllamaServiceError.networkError(error)
        }

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
        do {
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
        } catch {
            // Mid-stream idle timeout (5 min without a byte) — wedged server,
            // terminal like the non-streaming path.
            if (error as? URLError)?.code == .timedOut { throw OllamaServiceError.timedOut }
            throw error
        }

        // Strip any inline <think>…</think> from content. Do NOT fall back to
        // the separate `thinking` field when content is empty: that field is
        // pure reasoning with no </think> tag, so surfacing it leaked raw
        // chain-of-thought into summaries/briefs. Empty content here means the
        // generation truncated before the answer — fail cleanly so the task
        // queue retries, rather than emit reasoning as the result.
        let cleaned = Self.stripThinkBlock(fullText.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !cleaned.isEmpty else {
            if !fullThinking.isEmpty {
                Logger.ai.warning("Ollama stream: content empty, only reasoning present (\(fullThinking.count) chars) — failing rather than leaking it")
            }
            throw OllamaServiceError.emptyResponse
        }

        Logger.ai.info("Streaming response complete (\(cleaned.count) chars, model: \(selectedModel))")
        return cleaned
    }

    /// Free a model's memory now instead of waiting out keep_alive
    /// (TASK-055 §4). Guarded by /api/ps — a keep_alive:0 generate against
    /// a NON-resident model would load it first (review M3). Callers must
    /// ensure no work is in flight (inFlightCount == 0).
    func unloadIfResident(_ model: String) async {
        struct PS: Decodable { struct M: Decodable { let name: String }; let models: [M] }
        var psReq = URLRequest(url: Self.baseURL.appendingPathComponent("api/ps"))
        psReq.timeoutInterval = 5
        guard let (data, resp) = try? await URLSession.shared.data(for: psReq),
              let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let ps = try? JSONDecoder().decode(PS.self, from: data),
              ps.models.contains(where: { $0.name == model || $0.name.hasPrefix(model) }) else { return }
        var req = URLRequest(url: Self.baseURL.appendingPathComponent("api/generate"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model, "keep_alive": 0])
        _ = try? await URLSession.shared.data(for: req)
        Logger.ai.info("Ollama: requested unload of \(model)")
    }

    /// The qwen3 model currently RESIDENT in Ollama's memory (/api/ps), or
    /// any installed qwen3 as fallback. Catch-me-up (TASK-053) must reuse
    /// what's already loaded — force-loading a second model alongside a
    /// resident 8b+KV blows the 16 GB Metal budget mid-recording (review B2).
    func residentQwen3() async -> String? {
        struct PS: Decodable { struct M: Decodable { let name: String }; let models: [M] }
        var request = URLRequest(url: Self.baseURL.appendingPathComponent("api/ps"))
        request.timeoutInterval = 5
        if let (data, response) = try? await URLSession.shared.data(for: request),
           let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
           let ps = try? JSONDecoder().decode(PS.self, from: data),
           let resident = ps.models.first(where: { $0.name.contains("qwen3") }) {
            return resident.name
        }
        return availableModels.first(where: { $0.contains("qwen3") })
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

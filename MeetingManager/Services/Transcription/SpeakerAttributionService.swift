import Foundation
import os

/// Maps anonymous diarization clusters ("Speaker 1", "Speaker 2", ...) to
/// real participant names via an LLM call against the calendar attendee list
/// plus the first turns of each cluster. Returns the cluster->name dictionary
/// for persistence on the meeting.
///
/// Failure is always silent — any error path (no participants, Ollama down,
/// invalid JSON, hallucinated names) returns an empty dictionary so the
/// caller can simply leave Speaker N labels intact. Layer 3 will let the
/// user rename clusters manually.
@MainActor
final class SpeakerAttributionService {
    static let shared = SpeakerAttributionService()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.meetingmanager",
                                category: "SpeakerAttribution")
    private init() {}

    /// Performs cluster -> name attribution. Returns an empty dictionary on any
    /// failure so the caller can simply leave Speaker N labels intact.
    ///
    /// - Parameters:
    ///   - transcripts: The full transcript turns for one meeting.
    ///   - participantNames: Calendar attendees minus the user themselves.
    ///   - userFirstName: First name of the authenticated user. Used to
    ///     filter the user out of the candidate list (mic-labelled turns are
    ///     already excluded — they're tagged "mic", not "Speaker N").
    ///   - ollama: Ollama service — the cheap-pass fallback when no Claude
    ///     key is configured.
    ///   - claude: Optional Claude service. When present it is PREFERRED:
    ///     haiku runs the cheap pass and Sonnet handles escalation.
    func attribute(
        transcripts: [Transcript],
        participantNames: [String],
        userFirstName: String?,
        priorAliases: [String: String] = [:],
        ollama: OllamaService,
        claude: ClaudeService?,
        gemini: GeminiService? = nil,
        geminiCheapModel: String = "gemini-2.5-flash",
        geminiEscalateModel: String = "gemini-2.5-pro"
    ) async -> AttributionOutcome {
        // Filter transcripts: only the system-stream turns matter (user turns
        // are tagged "mic" — we already know who they are).
        let systemTurns = transcripts.filter { ($0.speakerLabel ?? "").lowercased() != "mic" }
        guard !systemTurns.isEmpty else {
            return AttributionOutcome(mapping: [:], reason: .noNonMicTurns)
        }

        // Group by cluster id (Speaker 1, Speaker 2, ...). Treat "system" as a
        // single attributable cluster when no Speaker N labels exist (i.e.
        // diarization didn't split or wasn't run). With ≥1 candidate the LLM
        // can still pick the most likely speaker.
        //
        // ONLY anonymous "Speaker N" labels are attributable. A label that is
        // already a resolved name (prior attribution pass or a manual rename)
        // must never be re-presented to the LLM as a cluster — on a re-run the
        // model would happily "re-attribute" Alice to Bob, and the candidate
        // list doesn't even contain drop-in guests the user named manually.
        let grouped = Dictionary(grouping: systemTurns) { $0.speakerLabel ?? "Unknown" }
        var clusters = grouped.keys.filter { id in
            id.lowercased().hasPrefix("speaker ")
        }
        // System-cluster fallback: if there are no Speaker N clusters but a
        // system bucket exists, attribute the system cluster as a single
        // unknown. The same cluster id is used for the final mapping key.
        let systemKey = "system"
        let systemHasTurns = (grouped[systemKey]?.isEmpty == false)
            || grouped.keys.contains(where: { $0.lowercased() == systemKey })
        if clusters.isEmpty, systemHasTurns {
            clusters.append(systemKey)
            logger.info("No Speaker N clusters — treating 'system' bucket as a single attributable cluster")
        }
        guard !clusters.isEmpty else {
            return AttributionOutcome(mapping: [:], reason: .noClusters)
        }

        // For each cluster, take up to ~20 turns or 1500 characters of context.
        // System cluster reads from the case-insensitive "system" key.
        var clusterPreviews: [String: String] = [:]
        for clusterId in clusters {
            let key = clusterId.lowercased() == systemKey
                ? grouped.keys.first(where: { $0.lowercased() == systemKey }) ?? clusterId
                : clusterId
            let turns = grouped[key, default: []]
                .sorted { $0.startTime < $1.startTime }
                .prefix(20)
                .map { "  [\(formatTime($0.startTime))] \($0.text)" }
                .joined(separator: "\n")
            clusterPreviews[clusterId] = String(turns.prefix(1500))
        }

        // Strip the user from candidates if present. First-token equality, NOT
        // substring — substring removes legitimate attendees ("Samantha Jones"
        // disappears when the user is "Sam"), the exact failure mode ADR-004
        // documents for the RSVP gate.
        let candidates: [String] = {
            guard let first = userFirstName, !first.isEmpty else { return participantNames }
            let needle = first.lowercased()
            return participantNames.filter { name in
                let firstToken = name.lowercased()
                    .components(separatedBy: .whitespacesAndNewlines).first ?? ""
                return firstToken != needle
            }
        }()

        guard !candidates.isEmpty else {
            logger.info("No non-user participants to attribute against — skipping")
            return AttributionOutcome(mapping: [:], reason: .noCandidates)
        }

        let prompt = buildPrompt(candidates: candidates,
                                 clusterPreviews: clusterPreviews,
                                 priorAliases: priorAliases)
        logger.info("Attributing \(clusters.count) clusters against \(candidates.count) candidates")

        // Two-tier model strategy. Cheap pass first (Claude haiku or Gemini
        // Flash if a cloud key is selected, else Ollama). If the cheap pass
        // returns empty/all-Unknown AND a cloud provider (Claude or Gemini)
        // is active, escalate to a more capable model (Claude Sonnet or
        // Gemini Pro).
        let validClusters = Set(clusters)
        let validNames = Set(candidates)

        let cheapResponse: String?
        let cheapReason: AttributionReason
        if let gemini {
            let result = await callGemini(prompt: prompt, gemini: gemini, model: geminiCheapModel)
            cheapResponse = result
            cheapReason = (result == nil) ? .llmCallFailed("Gemini flash call failed") : .ok
        } else if let claude {
            let result = await callClaude(prompt: prompt, claude: claude, model: "claude-haiku-4-5")
            cheapResponse = result
            cheapReason = (result == nil) ? .llmCallFailed("Claude haiku call failed") : .ok
        } else if ollama.isReachable {
            let result = await callOllama(prompt: prompt, ollama: ollama)
            cheapResponse = result
            cheapReason = (result == nil) ? .llmCallFailed("Ollama call failed") : .ok
        } else {
            logger.info("No LLM available — leaving Speaker N labels intact")
            return AttributionOutcome(mapping: [:], reason: .noLLMAvailable)
        }

        var mapping = parseIfNonEmpty(
            response: cheapResponse,
            validClusters: validClusters,
            validNames: validNames
        )

        // Escalation: if the cheap pass yielded nothing useful AND a cloud
        // provider (Claude or Gemini) is active, retry once with a more
        // capable model. Worth the cost — attribution is a one-shot
        // per-meeting expense and getting names right is high-leverage.
        if mapping.isEmpty, let gemini {
            logger.info("Cheap pass returned 0 mappings; escalating to \(geminiEscalateModel)")
            let escalated = await callGemini(
                prompt: prompt,
                gemini: gemini,
                model: geminiEscalateModel
            )
            mapping = parseIfNonEmpty(
                response: escalated,
                validClusters: validClusters,
                validNames: validNames
            )
            if mapping.isEmpty {
                return AttributionOutcome(
                    mapping: [:],
                    reason: .llmReturnedAllUnknown
                )
            }
            // Escalated LLM is more capable → solidly above review threshold
            let conf = Dictionary(uniqueKeysWithValues: mapping.keys.map { ($0, Float(0.78)) })
            return AttributionOutcome(mapping: mapping, reason: .okEscalated, confidenceMap: conf)
        } else if mapping.isEmpty, let claude {
            logger.info("Cheap pass returned 0 mappings; escalating to claude-sonnet-4-6")
            let escalated = await callClaude(
                prompt: prompt,
                claude: claude,
                model: "claude-sonnet-4-6"
            )
            mapping = parseIfNonEmpty(
                response: escalated,
                validClusters: validClusters,
                validNames: validNames
            )
            if mapping.isEmpty {
                return AttributionOutcome(
                    mapping: [:],
                    reason: .llmReturnedAllUnknown
                )
            }
            // Escalated LLM is more capable → solidly above review threshold
            let conf = Dictionary(uniqueKeysWithValues: mapping.keys.map { ($0, Float(0.78)) })
            return AttributionOutcome(mapping: mapping, reason: .okEscalated, confidenceMap: conf)
        }

        if mapping.isEmpty {
            // Cheap pass returned nothing useful, no escalation available.
            // Reason depends on whether the response itself was empty.
            let r: AttributionReason = (cheapResponse?.isEmpty ?? true)
                ? cheapReason
                : .llmReturnedAllUnknown
            return AttributionOutcome(mapping: [:], reason: r)
        }

        // Cheap pass succeeded — confidence reflects model capability.
        // QA finding #12: tuned so cheap-LLM attributions don't all show an
        // amber "needs review" dot. Claude haiku and Gemini Flash both clear
        // the 0.70 threshold at 0.72; local Ollama stays below at 0.62 as a
        // deliberate signal that those attributions warrant a glance.
        let cheapConfidence: Float = (claude != nil || gemini != nil) ? 0.72 : 0.62
        let conf = Dictionary(uniqueKeysWithValues: mapping.keys.map { ($0, cheapConfidence) })
        return AttributionOutcome(mapping: mapping, reason: .ok, confidenceMap: conf)
    }

    /// Helper: parse a (possibly nil) raw LLM response and return the
    /// validated cluster→name mapping. Returns an empty dictionary when the
    /// response is nil/empty or when no entry passed validation.
    private func parseIfNonEmpty(
        response: String?,
        validClusters: Set<String>,
        validNames: Set<String>
    ) -> [String: String] {
        guard let raw = response, !raw.isEmpty else { return [:] }
        return parse(
            rawResponse: raw,
            validClusters: validClusters,
            validNames: validNames
        )
    }

    // MARK: - Prompt

    private func buildPrompt(candidates: [String],
                             clusterPreviews: [String: String],
                             priorAliases: [String: String]) -> String {
        let clustersBody = clusterPreviews
            .sorted(by: { $0.key < $1.key })
            .map { "## \($0.key)\n\($0.value)" }
            .joined(separator: "\n\n")

        let candidateLine = candidates.map { "\"\($0)\"" }.joined(separator: ", ")

        // v3.1 Layer 3: when the user has previously confirmed renames in this
        // recurring series, surface them so the model can prefer the same
        // mapping. Empty dict skips the section entirely.
        let priorBlock: String = {
            guard !priorAliases.isEmpty else { return "" }
            let lines = priorAliases
                .sorted(by: { $0.key < $1.key })
                .map { "  \($0.key) → \($0.value)" }
                .joined(separator: "\n")
            return """

            Prior renames you've already confirmed for this recurring meeting series:
            \(lines)

            If a current cluster's pattern of speech matches one of these prior speakers, prefer the same name.

            """
        }()

        return """
        You are matching anonymous speaker clusters to real meeting attendees. Below are the meeting attendees and the first turns from each unidentified speaker cluster (the user themselves is NOT in this list — they were filtered out).

        Meeting attendees: [\(candidateLine)]
        \(priorBlock)
        For each speaker cluster, return the SINGLE most likely attendee from the list above, or the literal string "Unknown" if you genuinely cannot tell. Do not invent names not in the list.

        Speaker clusters:

        \(clustersBody)

        Respond as a strict JSON object on a single line, with cluster ids as keys. Example:
        {"Speaker 1": "Alex Chen", "Speaker 2": "Unknown"}

        Now respond with ONLY the JSON object, nothing else.
        """
    }

    // MARK: - LLM calls

    private func callOllama(prompt: String, ollama: OllamaService) async -> String? {
        do {
            let result = try await ollama.generate(
                systemPrompt: "You match anonymous speaker clusters to real attendee names. Reply with JSON only.",
                userPrompt: prompt,
                model: "auto"
            )
            return result
        } catch {
            logger.error("Ollama attribution call failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func callClaude(prompt: String, claude: ClaudeService, model: String) async -> String? {
        do {
            let result = try await claude.sendMessage(
                systemPrompt: "You match anonymous speaker clusters to real attendee names. Reply with JSON only.",
                userPrompt: prompt,
                model: model
            )
            return result
        } catch {
            logger.error("Claude attribution call failed (\(model, privacy: .public)): \(error.localizedDescription)")
            return nil
        }
    }

    private func callGemini(prompt: String, gemini: GeminiService, model: String) async -> String? {
        do {
            let result = try await gemini.sendMessage(
                systemPrompt: "You match anonymous speaker clusters to real attendee names. Reply with JSON only.",
                userPrompt: prompt,
                model: model,
                maxTokens: 1024,
                thinking: false
            )
            return result
        } catch {
            logger.error("Gemini attribution call failed (\(model, privacy: .public)): \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Parsing

    private func parse(rawResponse: String,
                       validClusters: Set<String>,
                       validNames: Set<String>) -> [String: String] {
        // Find the first balanced JSON object substring — LLMs sometimes wrap
        // their reply in prose despite the prompt's instructions.
        guard let jsonStart = rawResponse.firstIndex(of: "{"),
              let jsonEnd = rawResponse.lastIndex(of: "}"),
              jsonStart < jsonEnd else {
            logger.error("No JSON object found in LLM speaker attribution response")
            return [:]
        }
        let jsonSlice = String(rawResponse[jsonStart...jsonEnd])
        guard let data = jsonSlice.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            logger.error("Failed to parse LLM speaker attribution response")
            return [:]
        }

        // Sanitize: only keep entries where the cluster is real and the name
        // resolves to a known attendee. We accept four match grades, in order
        // of trust:
        //   1. Exact match
        //   2. Case-insensitive exact
        //   3. Substring match in either direction (covers "Sarah Chen" ↔
        //      "Sarah Chen <sarah.chen@…>" and similar)
        //   4. First-token match (LLM returned just "Sarah" but only one
        //      attendee starts with "Sarah" — accept it)
        // Anything else is logged and rejected. "Unknown" is intentionally not
        // written to the map — those clusters stay as "Speaker N".
        var result: [String: String] = [:]
        for (cluster, name) in decoded {
            guard validClusters.contains(cluster) else { continue }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.lowercased() == "unknown" { continue }

            if let resolved = Self.resolveAttendee(name: trimmed, candidates: validNames) {
                result[cluster] = resolved
            } else {
                logger.info("LLM returned non-attendee name \"\(trimmed, privacy: .public)\" for \(cluster, privacy: .public) — rejected")
            }
        }
        return result
    }

    /// A single best-guess attribution for one cluster, for the manual Speaker
    /// tab. `name` is always one of the supplied candidates (closed set).
    struct NameSuggestion: Equatable, Codable {
        let name: String
        let reason: String
    }

    /// Ask the LLM for the single most likely attendee for one anonymous
    /// cluster, given a sample of its utterances and the closed candidate list.
    /// Hallucination-safe: the returned name is validated against `candidates`
    /// via `resolveAttendee`, so the model can only pick a real attendee or be
    /// rejected — it can never invent a name. Returns nil on "Unknown",
    /// invalid output, or any error (the UI just shows the plain chip list).
    ///
    /// Uses the app's configured text generator (Qwen via Ollama, or Claude)
    /// so callers don't need to know which backend is active.
    static func suggestBestMatch(
        clusterText: String,
        candidates: [String],
        textGen: (String, String) async throws -> String
    ) async -> NameSuggestion? {
        let cands = candidates
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !cands.isEmpty else { return nil }
        let sample = String(clusterText.prefix(3000))
        guard sample.count >= 20 else { return nil }

        let candidateLine = cands.map { "\"\($0)\"" }.joined(separator: ", ")
        let system = "You match an anonymous meeting speaker to the single most likely attendee from a fixed list. Reply with JSON only. Never use a name that is not in the list."
        let user = """
            Attendees: [\(candidateLine)]

            A sample of what one anonymous speaker said:
            \"\"\"
            \(sample)
            \"\"\"

            Pick the SINGLE most likely attendee from the list above — reason from their role, the topics they own, and how others might address them. If you genuinely cannot tell, use "Unknown".

            Respond with ONLY this JSON on one line:
            {"name": "<an attendee name exactly as listed, or Unknown>", "reason": "<why, max 12 words>"}
            """
        guard let raw = try? await textGen(system, user),
              let json = extractJSONObject(from: raw),
              let data = json.data(using: .utf8),
              let dict = try? JSONDecoder().decode([String: String].self, from: data),
              let rawName = dict["name"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawName.isEmpty, rawName.lowercased() != "unknown",
              let resolved = resolveAttendee(name: rawName, candidates: Set(cands))
        else { return nil }
        let reason = (dict["reason"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return NameSuggestion(name: resolved, reason: reason)
    }

    /// Extract the first balanced `{…}` JSON object from a string. LLMs (esp.
    /// Qwen3 in thinking mode) sometimes wrap JSON in prose or `<think>` blocks.
    static func extractJSONObject(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var idx = start
        while idx < text.endIndex {
            let ch = text[idx]
            if ch == "{" { depth += 1 }
            else if ch == "}" {
                depth -= 1
                if depth == 0 { return String(text[start...idx]) }
            }
            idx = text.index(after: idx)
        }
        return nil
    }

    /// Map an LLM-returned name onto one of the meeting's actual attendees.
    /// Returns nil when no candidate matches with high enough confidence.
    /// Public so the UI's manual-assign affordance can reuse the same logic.
    static func resolveAttendee(name: String, candidates: Set<String>) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Grade 1 — exact
        if candidates.contains(trimmed) { return trimmed }

        let lowered = trimmed.lowercased()
        // Grade 2 — case-insensitive exact
        if let hit = candidates.first(where: { $0.lowercased() == lowered }) {
            return hit
        }
        // Grade 3 — first-token uniqueness (e.g. LLM said "Sarah" → unique
        // attendee starting with "Sarah" wins; ambiguous "Sarah" → reject).
        // Runs BEFORE the substring grade: with attendees {"Samantha Jones",
        // "Sam Smith"} and name "Sam", substring would return an arbitrary
        // Set element (Set order is nondeterministic), while token matching
        // resolves it correctly or rejects.
        let firstToken = lowered
            .split(separator: " ")
            .first
            .map(String.init) ?? lowered
        let firstTokenMatches = candidates.filter { cand in
            let candFirst = cand.lowercased().split(separator: " ").first.map(String.init) ?? ""
            return candFirst == firstToken
        }
        if firstTokenMatches.count == 1, let only = firstTokenMatches.first {
            return only
        }
        // Grade 4 — substring in either direction (handles email-suffixed
        // names). Only when exactly ONE candidate matches — multiple matches
        // would pick a nondeterministic Set element.
        let substringMatches = candidates.filter {
            let cand = $0.lowercased()
            return cand.contains(lowered) || lowered.contains(cand)
        }
        if substringMatches.count == 1, let only = substringMatches.first {
            return only
        }
        return nil
    }

    private func formatTime(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

// MARK: - Outcome types

/// Structured result of a single attribution attempt. The reason field lets
/// the UI surface a specific cause when no mappings landed (e.g. "no LLM
/// available", "all clusters returned Unknown") instead of a generic banner.
struct AttributionOutcome: Sendable {
    let mapping: [String: String]
    /// v3.10 confidence per attributed cluster, in [0, 1]. Higher is better.
    /// Sources: voice match → cosine similarity; vocative → vote-based
    /// heuristic; LLM cheap pass → 0.62 (Ollama) / 0.72 (Claude haiku);
    /// escalated Claude pass → 0.78; manual rename (set by AppState) → 1.0.
    let confidenceMap: [String: Float]
    let reason: AttributionReason

    init(
        mapping: [String: String],
        reason: AttributionReason,
        confidenceMap: [String: Float] = [:]
    ) {
        self.mapping = mapping
        self.reason = reason
        self.confidenceMap = confidenceMap
    }
}

enum AttributionReason: Sendable, Equatable {
    /// Cheap-pass succeeded with at least one mapping.
    case ok
    /// Cheap pass returned 0 mappings; escalated to a more capable model and
    /// that produced at least one mapping.
    case okEscalated
    /// No LLM backend could be reached (Ollama unreachable + no Claude key).
    case noLLMAvailable
    /// The meeting had no diarization clusters at all (no Speaker N rows and
    /// no system bucket either).
    case noClusters
    /// Every transcript turn was tagged "mic" — nothing to attribute.
    case noNonMicTurns
    /// The user is the only attendee on the calendar invite — no candidates.
    case noCandidates
    /// LLM call itself failed (network / API error). Detail in associated value.
    case llmCallFailed(String)
    /// LLM returned a response but every cluster came back "Unknown" or
    /// rejected by the candidate validator.
    case llmReturnedAllUnknown

    /// Human-readable summary suitable for a banner. Returns nil when the
    /// outcome is a success and no diagnostic is needed.
    var userFacingMessage: String? {
        switch self {
        case .ok, .okEscalated:
            return nil
        case .noLLMAvailable:
            return "No AI configured — sign in to Claude or run Ollama to enable automatic name matching."
        case .noClusters:
            return "Diarization didn't split this meeting into separate speakers — try re-running attribution after the audio finishes processing."
        case .noNonMicTurns:
            return "Only your microphone was captured — no other speakers to attribute."
        case .noCandidates:
            return "No calendar attendees besides you — add attendees to the calendar invite to enable attribution."
        case .llmCallFailed(let detail):
            return "AI call failed (\(detail)) — check Ollama is running or Claude is reachable, then click Re-run AI."
        case .llmReturnedAllUnknown:
            return "AI couldn't confidently match any speaker to a calendar attendee. Click a Speaker N label below to assign one manually."
        }
    }
}

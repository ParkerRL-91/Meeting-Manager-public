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
    ///   - ollama: Live Ollama service (preferred for privacy + cost).
    ///   - claude: Optional Claude service (currently unused fallback —
    ///     Ollama is the primary path; pass nil from call sites).
    func attribute(
        transcripts: [Transcript],
        participantNames: [String],
        userFirstName: String?,
        priorAliases: [String: String] = [:],
        ollama: OllamaService,
        claude: ClaudeService?
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
        let grouped = Dictionary(grouping: systemTurns) { $0.speakerLabel ?? "Unknown" }
        var clusters = grouped.keys.filter { id in
            let lower = id.lowercased()
            return lower != "system" && lower != "mic" && lower != "unknown"
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

        // Strip the user from candidates if present (case-insensitive substring).
        let candidates: [String] = {
            guard let first = userFirstName, !first.isEmpty else { return participantNames }
            let needle = first.lowercased()
            return participantNames.filter { !$0.lowercased().contains(needle) }
        }()

        guard !candidates.isEmpty else {
            logger.info("No non-user participants to attribute against — skipping")
            return AttributionOutcome(mapping: [:], reason: .noCandidates)
        }

        let prompt = buildPrompt(candidates: candidates,
                                 clusterPreviews: clusterPreviews,
                                 priorAliases: priorAliases)
        logger.info("Attributing \(clusters.count) clusters against \(candidates.count) candidates")

        // Two-tier model strategy. Cheap pass first (Claude haiku if available,
        // else Ollama). If the cheap pass returns empty/all-Unknown AND we
        // have a Claude key, escalate to a more capable Claude model.
        let validClusters = Set(clusters)
        let validNames = Set(candidates)

        let cheapResponse: String?
        let cheapReason: AttributionReason
        if let claude {
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

        // Escalation: if the cheap pass yielded nothing useful AND we have a
        // Claude key, retry once with a more capable model. Worth the cost —
        // attribution is a one-shot per-meeting expense and getting names
        // right is high-leverage.
        if mapping.isEmpty, let claude {
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
            return AttributionOutcome(mapping: mapping, reason: .okEscalated)
        }

        if mapping.isEmpty {
            // Cheap pass returned nothing useful, no escalation available.
            // Reason depends on whether the response itself was empty.
            let r: AttributionReason = (cheapResponse?.isEmpty ?? true)
                ? cheapReason
                : .llmReturnedAllUnknown
            return AttributionOutcome(mapping: [:], reason: r)
        }

        return AttributionOutcome(mapping: mapping, reason: .ok)
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
        // Grade 3 — substring in either direction (handles email-suffixed names)
        if let hit = candidates.first(where: {
            let cand = $0.lowercased()
            return cand.contains(lowered) || lowered.contains(cand)
        }) {
            return hit
        }
        // Grade 4 — first-token uniqueness (e.g. LLM said "Sarah" → unique
        // attendee starting with "Sarah" wins; ambiguous "Sarah" → reject)
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
    let reason: AttributionReason
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

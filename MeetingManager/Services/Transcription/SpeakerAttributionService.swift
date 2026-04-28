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
    ) async -> [String: String] {
        // Filter transcripts: only the system-stream turns matter (user turns
        // are tagged "mic" — we already know who they are).
        let systemTurns = transcripts.filter { ($0.speakerLabel ?? "").lowercased() != "mic" }
        guard !systemTurns.isEmpty else { return [:] }

        // Group by cluster id (Speaker 1, Speaker 2, ...). Skip "system" and
        // "mic" labels — those aren't diarization clusters.
        let grouped = Dictionary(grouping: systemTurns) { $0.speakerLabel ?? "Unknown" }
        let clusters = grouped.keys.filter { id in
            let lower = id.lowercased()
            return lower != "system" && lower != "mic" && lower != "unknown"
        }
        guard !clusters.isEmpty else { return [:] }

        // For each cluster, take up to ~20 turns or 1500 characters of context.
        var clusterPreviews: [String: String] = [:]
        for clusterId in clusters {
            let turns = grouped[clusterId, default: []]
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
            return [:]
        }

        let prompt = buildPrompt(candidates: candidates,
                                 clusterPreviews: clusterPreviews,
                                 priorAliases: priorAliases)
        logger.info("Attributing \(clusters.count) clusters against \(candidates.count) candidates")

        // Try Ollama first; fall back to Claude if available (currently unused).
        let response: String?
        if ollama.isReachable {
            response = await callOllama(prompt: prompt, ollama: ollama)
        } else if let claude {
            response = await callClaude(prompt: prompt, claude: claude)
        } else {
            logger.info("No LLM available — leaving Speaker N labels intact")
            return [:]
        }

        guard let raw = response, !raw.isEmpty else { return [:] }
        return parse(rawResponse: raw,
                     validClusters: Set(clusters),
                     validNames: Set(candidates))
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

    private func callClaude(prompt: String, claude: ClaudeService) async -> String? {
        // Claude fallback intentionally unimplemented — Ollama is the primary
        // path and a silent no-op is acceptable per the v3.1 plan. If a future
        // Layer expands this, wire ClaudeService here.
        _ = (prompt, claude)
        return nil
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
        // is a known attendee. Reject hallucinated names; fall back to a
        // case-insensitive lookup before giving up. "Unknown" is not written
        // to the map — those clusters stay as "Speaker N".
        var result: [String: String] = [:]
        for (cluster, name) in decoded {
            guard validClusters.contains(cluster) else { continue }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.lowercased() == "unknown" { continue }

            if validNames.contains(trimmed) {
                result[cluster] = trimmed
            } else if let real = validNames.first(where: {
                $0.caseInsensitiveCompare(trimmed) == .orderedSame
            }) {
                result[cluster] = real
            } else {
                logger.info("LLM returned non-attendee name \"\(trimmed, privacy: .public)\" for \(cluster, privacy: .public) — rejected")
            }
        }
        return result
    }

    private func formatTime(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

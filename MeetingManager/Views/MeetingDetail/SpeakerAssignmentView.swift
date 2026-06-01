import SwiftUI
import os

/// Per-speaker labelling tab. Instead of clicking through hundreds of
/// transcript fragments to identify a voice, this view groups every cluster
/// (Speaker 1, Speaker 2, …) into one card showing what they said + a
/// single name picker that bulk-renames all of their utterances at once.
///
/// The "what they said" part is the magic: a 30-second sample of their
/// longest / earliest utterances reads enough like a person to make
/// matching them to a calendar invitee fast and intuitive.
///
/// Suggestions are pulled from:
///   1. The current meeting's `participantList` (calendar invitees)
///   2. Any free-form name the user types
///
/// On Apply: bulk renames every transcript row whose `speakerLabel` matches
/// the cluster, persists the meeting's speakerMap, and writes a SpeakerAlias
/// for the meeting series so future meetings in the same series benefit from
/// the resolution without re-asking.
struct SpeakerAssignmentView: View {
    let meetingId: String

    @Environment(AppState.self) private var appState
    @State private var meeting: Meeting?
    @State private var transcripts: [Transcript] = []
    @State private var clusters: [SpeakerCluster] = []
    @State private var voiceProfiles: [VoiceProfile] = []
    @State private var isLoading = true
    @State private var savingClusterId: String?
    @State private var lastError: String?
    @State private var isReanalyzing = false

    /// LLM-generated 1-2 sentence summary per cluster. Lazy: generated when
    /// the tab is opened, cached in memory, and re-used until the user
    /// renames the cluster (at which point it drops out of the list).
    /// Long meetings with hundreds of utterances become identifiable in a
    /// single readable sentence instead of a wall of fragments.
    @State private var summaries: [String: String] = [:]
    @State private var summarizingClusters: Set<String> = []

    /// AI best-guess name per unresolved cluster (closed-set, hallucination-safe).
    /// Surfaced as a highlighted "Likely …" chip so the user can confirm with
    /// one click instead of scanning the full attendee list. Cached to disk.
    @State private var bestGuesses: [String: SpeakerAttributionService.NameSuggestion] = [:]
    @State private var guessingClusters: Set<String> = []

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.meetingmanager.app", category: "ui")

    var body: some View {
        VStack(spacing: 0) {
            // Action bar — always visible (not gated on clusters)
            VStack(alignment: .leading, spacing: 6) {
                Text("Speakers are grouped by voice. Rename to correct mis-assignments.")
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)
                HStack(spacing: 12) {
                    Button {
                        Task {
                            isReanalyzing = true
                            await appState.rerunDiarization(meetingId: meetingId)
                            // Reload clusters after re-diarization
                            summaries.removeAll()
                            SpeakerSummaryCache.clear(meetingId: meetingId)
                            await load()
                            isReanalyzing = false
                        }
                    } label: {
                        HStack(spacing: 4) {
                            if isReanalyzing {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "waveform.badge.magnifyingglass")
                                    .font(.caption)
                            }
                            Text("Re-analyze speakers")
                                .font(.caption.weight(.medium))
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.appAccent)
                    .disabled(isLoading || isReanalyzing)
                    .help("Re-run voice diarization on the system audio and reassign speaker labels")

                    Button {
                        Task { await reload() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "sparkles")
                                .font(.caption)
                            Text("Regenerate summaries")
                                .font(.caption.weight(.medium))
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.appAccent)
                    .disabled(isLoading || isReanalyzing)
                    .help("Clear cached summaries and regenerate with AI")

                    Spacer()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            if isLoading {
                Spacer()
                ProgressView()
                Spacer()
            } else if clusters.isEmpty {
                Spacer()
                EmptyStateView(
                    icon: "person.wave.2",
                    title: "No speakers detected",
                    subtitle: "The transcript hasn't finished processing yet, or no audio was captured."
                )
                Spacer()
            } else {
                if let lastError {
                    Text(lastError)
                        .font(.caption)
                        .foregroundStyle(Color.appWarning)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let flags = meeting?.attributionFlagList, !flags.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Label("Review these speaker matches", systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Color.appWarning)
                                ForEach(Array(flags.enumerated()), id: \.offset) { _, flag in
                                    Text("• \(flag.reason)")
                                        .font(.caption)
                                        .foregroundStyle(Color.appTextSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.appWarning.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .padding(.horizontal, 16)
                        }
                        ForEach(clusters) { cluster in
                            SpeakerClusterCard(
                                cluster: cluster,
                                totalMeetingSeconds: totalClusterSeconds,
                                meeting: meeting,
                                suggestions: orderedSuggestions(for: cluster),
                                bestGuess: bestGuesses[cluster.id],
                                isGuessing: guessingClusters.contains(cluster.id),
                                summary: summaries[cluster.id],
                                isSummarizing: summarizingClusters.contains(cluster.id),
                                isSaving: savingClusterId == cluster.id,
                                onApply: { name in
                                    Task { await apply(name: name, to: cluster) }
                                }
                            )
                            .padding(.horizontal, 16)
                        }
                    }
                    .padding(.bottom, 24)
                }
            }
        }
        .task { await load() }
        .refreshOnTaskCompletion(
            meetingId: meetingId,
            types: [.diarization, .retryAttribution, .transcriptCleanup],
            tasks: appState.taskQueueManager.allTasks
        ) {
            Task { await reload() }
        }
    }

    /// Total spoken seconds across every displayed cluster — the denominator for
    /// each card's share-of-meeting %. Computed once from the loaded clusters.
    private var totalClusterSeconds: Int {
        clusters.reduce(0) { $0 + $1.totalSeconds }
    }

    // MARK: - Loading

    /// Full reload: clears cached summaries and re-fetches everything
    /// from the database, then re-generates speaker summaries.
    private func reload() async {
        summaries.removeAll()
        summarizingClusters.removeAll()
        bestGuesses.removeAll()
        guessingClusters.removeAll()
        SpeakerSummaryCache.clear(meetingId: meetingId)
        SpeakerGuessCache.clear(meetingId: meetingId)
        await load()
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        meeting = try? await appState.meetingRepository.find(id: meetingId)
        transcripts = (try? await appState.transcriptRepository.transcriptsForMeeting(meetingId, limit: 100_000)) ?? []
        voiceProfiles = (try? await VoiceProfileRepository(database: AppDatabase.shared).allProfiles()) ?? []
        clusters = Self.buildClusters(from: transcripts)
        Self.logger.info("[SpeakerAssignment] loaded \(clusters.count) cluster(s) for meeting \(meetingId, privacy: .public)")

        // Load persisted summaries first — avoids re-generating on every tab open.
        let cached = SpeakerSummaryCache.load(meetingId: meetingId)
        for (key, value) in cached {
            summaries[key] = value
        }

        // Load persisted best-guess names.
        for (key, value) in SpeakerGuessCache.load(meetingId: meetingId) {
            bestGuesses[key] = value
        }

        // Only generate summaries for clusters that aren't already cached.
        let uncached = clusters.filter { summaries[$0.id] == nil && $0.segments.count >= 3 }
        if !uncached.isEmpty {
            await summarizeClusters(only: uncached)
        }

        // Generate AI name guesses for unresolved clusters we don't have one for.
        let needGuess = clusters.filter {
            $0.needsAssignment && bestGuesses[$0.id] == nil && $0.segments.count >= 3
        }
        if !needGuess.isEmpty {
            await guessClusters(only: needGuess)
        }
    }

    /// Generate best-match name guesses for the given unresolved clusters using
    /// the closed candidate list (calendar attendees). Persists to disk.
    private func guessClusters(only targets: [SpeakerCluster]) async {
        guard !targets.isEmpty else { return }
        // think:false + jsonMode: this is a closed-set classification. With
        // thinking ON, Qwen3 burns the token budget reasoning and returns empty
        // content; with thinking OFF but free-form output it rambles its
        // reasoning into the content and never reaches the JSON. Forcing JSON
        // output (Ollama format:"json") makes it emit just the object, which is
        // both reliable to parse and far fewer tokens to generate. Validated
        // against real clusters + qwen3:4b before shipping.
        let textGen = await appState.makeTextGenerator(maxOutputTokens: 1024, think: false, jsonMode: true)
        guard let textGen else { return }
        for cluster in targets {
            let candidates = suggestions(for: cluster)
            guard !candidates.isEmpty else { continue }
            guessingClusters.insert(cluster.id)
            let body = cluster.segments.map { $0.text }.joined(separator: " ")
            Task {
                let guess = await SpeakerAttributionService.suggestBestMatch(
                    clusterText: body, candidates: candidates, textGen: textGen
                )
                await MainActor.run {
                    if let guess { bestGuesses[cluster.id] = guess }
                    guessingClusters.remove(cluster.id)
                    SpeakerGuessCache.save(bestGuesses, meetingId: meetingId)
                }
            }
        }
    }

    /// Generate summaries for the given clusters (or all if nil).
    /// Persists results to disk so they survive tab switches and app restarts.
    private func summarizeClusters(only targets: [SpeakerCluster]? = nil) async {
        let toSummarize = targets ?? clusters.filter { summaries[$0.id] == nil && $0.segments.count >= 3 }
        guard !toSummarize.isEmpty else { return }

        // think:false + jsonMode: mirrors the name-suggestion call. On qwen3:4b
        // think:false is unreliable (Ollama #12917) — the model either burns the
        // budget reasoning and returns EMPTY content, or dumps reasoning into the
        // content. Forcing JSON structured output (Ollama format:"json") makes it
        // emit just {"profile": "..."}, which is both reliable to parse and the
        // robust local fix for the empty-profile bug. 2048 is ample for a
        // <=160-word profile object.
        let textGen = await appState.makeTextGenerator(maxOutputTokens: 2048, think: false, jsonMode: true)
        guard let textGen else {
            Self.logger.info("[SpeakerAssignment] no AI configured — skipping summaries")
            return
        }
        for cluster in toSummarize {
            summarizingClusters.insert(cluster.id)
            Task {
                let summary = await Self.summarize(cluster: cluster, textGen: textGen)
                await MainActor.run {
                    summaries[cluster.id] = summary
                    summarizingClusters.remove(cluster.id)
                    // Persist after each summary completes
                    SpeakerSummaryCache.save(summaries, meetingId: meetingId)
                }
            }
        }
    }

    /// LLM call that summarises one cluster's utterances. Sees only that
    /// cluster's text — no names, no other speakers, no meeting metadata.
    /// This isolation is what prevents the model from inventing speaker
    /// names from nearby context (the bug behind the cleanup hallucination).
    ///
    /// Summary length scales with the cluster's content — a speaker who
    /// talked for 15 minutes gets a 2-paragraph summary, not a sentence.
    static func summarize(
        cluster: SpeakerCluster,
        textGen: (String, String) async throws -> String
    ) async -> String {
        let body = cluster.segments.map { $0.text }.joined(separator: " ")
        // Scale input cap with cluster size — short clusters get 2K,
        // major speakers get up to 8K so the summary captures their
        // full range of topics.
        let inputCap = min(8000, max(2000, body.count))
        let truncated = String(body.prefix(inputCap))

        // Scale target length: short clusters (< 1 min) get a sentence,
        // substantial speakers (5+ min) get a fuller profile.
        let totalDuration = cluster.totalSeconds
        let lengthGuidance: String
        if totalDuration < 60 {
            lengthGuidance = "Write 1 sentence (under 30 words) capturing their apparent role and topic."
        } else if totalDuration < 300 {
            lengthGuidance = "Write 2-4 sentences (50-90 words): role first, then the topics they own and how they engage."
        } else {
            lengthGuidance = "Write a short paragraph (90-160 words): lead with their apparent role and what they're responsible for, then the specific topics they drive and any decisions or commitments they make."
        }

        // The goal of this summary is recognition — helping the reader figure
        // out WHO this anonymous speaker is so they can label the cluster. So
        // we ask for identity cues (role, ownership, participation style),
        // not just a topic recap. Names are still forbidden: the model only
        // ever sees this one cluster's text (no attendee list, no other
        // speakers), so it cannot attribute a name without inventing one
        // (ADR-005). Name guessing happens separately against a closed
        // candidate set.
        let system = """
            You are profiling ONE anonymous speaker in a meeting to help a reader recognize who they are. You see only this speaker's own utterances — no names, no other speakers. Reply with JSON only.

            Describe, drawing only on the text:
            - Their apparent ROLE or function (e.g. leads/facilitates the meeting, presents an update, makes decisions, asks questions, takes notes, mostly listens and reacts).
            - The specific TOPICS or areas they own or speak to (products, teams, customers, metrics, dates).
            - HOW they participate (drives the agenda, gives status, pushes back, defers to others, assigns or accepts action items).

            Rules:
            - Do NOT state or guess any person's name. Refer to them as "this speaker."
            - Do NOT invent anything not supported by the text. If they say little of substance, say so plainly.
            - \(lengthGuidance)

            Respond with ONLY this JSON object:
            {"profile": "<the recognition profile text>"}
            """
        let user = "This speaker's utterances:\n\n\(truncated)\n\nProfile this speaker for recognition."
        do {
            let raw = try await textGen(system, user)
            // Structured output: parse {"profile": "..."}. Fall back to the raw
            // text if the model returned bare prose (defensive — some backends
            // ignore the format hint).
            if let json = SpeakerAttributionService.extractJSONObject(from: raw),
               let data = json.data(using: .utf8),
               let dict = try? JSONDecoder().decode([String: String].self, from: data),
               let profile = dict["profile"]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !profile.isEmpty {
                return profile
            }
            return raw.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            logger.warning("[SpeakerAssignment] summarize failed for \(cluster.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return ""
        }
    }

    /// Group transcript rows by cluster id (Speaker 1, Speaker 2, …).
    /// Skips already-resolved labels (real names) and the user's own mic
    /// channel — those don't need attribution.
    static func buildClusters(from transcripts: [Transcript]) -> [SpeakerCluster] {
        var bucket: [String: [Transcript]] = [:]
        for t in transcripts {
            guard let label = t.speakerLabel?.trimmingCharacters(in: .whitespaces),
                  !label.isEmpty else { continue }
            // Skip raw "system" (unprocessed) and "mic" (the user's own voice).
            let lower = label.lowercased()
            guard lower != "system" && lower != "mic" else { continue }
            bucket[label, default: []].append(t)
        }
        // Sort: unassigned "Speaker N" clusters first (need attention),
        // then already-named speakers alphabetically.
        return bucket
            .map { id, segments in SpeakerCluster(id: id, segments: segments) }
            .sorted { a, b in
                let aIsGeneric = a.id.lowercased().hasPrefix("speaker ")
                let bIsGeneric = b.id.lowercased().hasPrefix("speaker ")
                if aIsGeneric != bIsGeneric { return aIsGeneric }
                return a.id.localizedCaseInsensitiveCompare(b.id) == .orderedAscending
            }
    }

    // MARK: - Suggestions

    /// Suggestions for the plain chip list, excluding the AI best guess (which
    /// is rendered separately as a highlighted chip) so it isn't shown twice.
    private func orderedSuggestions(for cluster: SpeakerCluster) -> [String] {
        let base = suggestions(for: cluster)
        guard let guess = bestGuesses[cluster.id]?.name else { return base }
        return base.filter { $0.caseInsensitiveCompare(guess) != .orderedSame }
    }

    private func suggestions(for cluster: SpeakerCluster) -> [String] {
        var out: [String] = []
        // Calendar participants (most likely match for live meetings)
        if let m = meeting {
            out.append(contentsOf: m.participantList)
        }
        // Voice profiles — only include those whose person is already a
        // participant. Showing every profile from unrelated meetings
        // clutters the list with irrelevant names (e.g. "Dana" from
        // last week's call appearing in today's 1:1).
        let participantSet = Set(out.map { $0.lowercased() })
        for p in voiceProfiles where !out.contains(p.personName) {
            if participantSet.contains(p.personName.lowercased()) {
                out.append(p.personName)
            }
        }
        // Drop the user's own name from suggestions — they're on the mic.
        let userFirst = NSFullUserName()
            .components(separatedBy: .whitespacesAndNewlines).first?.lowercased() ?? ""
        return out.filter { name in
            userFirst.isEmpty || !name.lowercased().contains(userFirst)
        }
    }

    // MARK: - Apply

    private func apply(name: String, to cluster: SpeakerCluster) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != cluster.id else { return }
        savingClusterId = cluster.id
        defer { savingClusterId = nil }

        do {
            // 1. Bulk rename every transcript segment with this cluster id.
            try await appState.transcriptRepository.updateSpeakerLabel(
                meetingId: meetingId,
                from: cluster.id,
                to: trimmed
            )
            // 2. Persist on the meeting's speakerMap (+ confidence = 1.0 since
            //    this is a manual confirmation).
            if var updated = meeting {
                var map = updated.speakerMapDictionary
                map[cluster.id] = trimmed
                updated.setSpeakerMap(map)
                var confMap = updated.speakerConfidenceMapDictionary
                confMap[cluster.id] = 1.0
                updated.setSpeakerConfidenceMap(confMap)
                try await appState.meetingRepository.update(updated)
                meeting = updated
            }
            // 3. Patch the cleaned transcript blob in place so the readable
            //    view picks up the new name immediately (same as the
            //    transcript-level rename in FullTranscriptView).
            let cleanedRepo = CleanedTranscriptRepository(database: AppDatabase.shared)
            if var cleaned = try? await cleanedRepo.cleanedTranscript(meetingId: meetingId) {
                let oldToken = "**\(cluster.id)**"
                let newToken = "**\(trimmed)**"
                if cleaned.text.contains(oldToken) {
                    cleaned.text = cleaned.text.replacingOccurrences(of: oldToken, with: newToken)
                    try? await cleanedRepo.save(cleaned)
                }
            }
            // 4. Save the alias for future meetings in the same series.
            if let m = meeting {
                let seriesKey = MeetingSeriesService.shared.seriesKey(for: m)
                try? await SpeakerAliasRepository(database: AppDatabase.shared)
                    .upsert(seriesKey: seriesKey, clusterId: cluster.id, resolvedName: trimmed)
            }
            // 5. Reload — the renamed cluster drops out of the list naturally
            //    (its rows no longer match "Speaker N").
            await load()
            // 6. Cross-meeting voice learning so this name's voice fingerprint
            //    pays off in future meetings even when the user labels here.
            await appState.learnVoiceProfiles(meetingId: meetingId)
            Self.logger.info("[SpeakerAssignment] applied \(trimmed, privacy: .public) to \(cluster.id, privacy: .public) (\(cluster.segments.count) segments)")
        } catch {
            lastError = "Couldn't apply name: \(error.localizedDescription)"
            Self.logger.error("[SpeakerAssignment] apply failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - Cluster model

struct SpeakerCluster: Identifiable {
    /// Cluster id — either a generic "Speaker 1" label or an assigned name.
    let id: String
    let segments: [Transcript]

    /// True when this cluster still has a generic diarization label
    /// and needs the user to assign a real name.
    var needsAssignment: Bool {
        id.lowercased().hasPrefix("speaker ")
    }

    var totalSeconds: Int {
        Int(segments.reduce(0) { $0 + ($1.endTime - $1.startTime) })
    }

    /// Top topic keywords this speaker uses, computed locally with no LLM:
    /// term frequency over the cluster's text, minus a stopword list, ranked.
    /// Distinguishes speakers at a glance even when the AI profile is absent.
    var topKeywords: [String] {
        var counts: [String: Int] = [:]
        for segment in segments {
            for token in segment.text.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "-" }) {
                let word = String(token)
                guard word.count >= 4, !Self.stopwords.contains(word) else { continue }
                counts[word, default: 0] += 1
            }
        }
        return counts
            .filter { $0.value >= 2 }
            .sorted { a, b in a.value != b.value ? a.value > b.value : a.key < b.key }
            .prefix(5)
            .map { $0.key }
    }

    /// Common English filler removed before ranking keywords. Kept deliberately
    /// short — anything ≥4 letters that recurs is usually topical.
    private static let stopwords: Set<String> = [
        "that", "this", "with", "have", "they", "from", "what", "your", "would",
        "there", "their", "about", "which", "when", "will", "been", "were", "them",
        "then", "than", "into", "just", "like", "know", "think", "going", "really",
        "yeah", "okay", "right", "well", "kind", "sort", "thing", "things", "want",
        "need", "make", "good", "some", "more", "much", "very", "also", "could",
        "should", "because", "actually", "basically", "maybe", "stuff", "gonna",
        "wanna", "sure", "mean", "guess", "those", "these", "here", "kinda"
    ]

    /// A representative sample of what this speaker said. Picks the longest
    /// utterances first because long ones are more identifying than "yeah" /
    /// "right". Caps at ~5 lines / 600 chars total — enough to recognise the
    /// person, short enough to scan in a card.
    var sampleUtterances: [Transcript] {
        let sorted = segments.sorted(by: { $0.text.count > $1.text.count })
        var picked: [Transcript] = []
        var totalChars = 0
        for s in sorted {
            if picked.count >= 5 || totalChars >= 600 { break }
            let trimmed = s.text.trimmingCharacters(in: .whitespaces)
            guard trimmed.count >= 8 else { continue } // skip "yeah" / "ok"
            picked.append(s)
            totalChars += trimmed.count
        }
        // Re-order chronologically so the sample reads naturally.
        return picked.sorted(by: { $0.startTime < $1.startTime })
    }
}

// MARK: - Cluster card

private struct SpeakerClusterCard: View {
    let cluster: SpeakerCluster
    /// Sum of spoken seconds across all clusters — denominator for share %.
    let totalMeetingSeconds: Int
    let meeting: Meeting?
    let suggestions: [String]
    /// AI best-match guess (closed-set, hallucination-safe) + a short reason.
    /// Shown as a highlighted "Likely …" chip when present.
    let bestGuess: SpeakerAttributionService.NameSuggestion?
    let isGuessing: Bool
    /// 1-2 sentence summary of what this speaker said. Nil while the
    /// LLM call is in flight or when AI isn't configured — falls back to
    /// a short utterance excerpt in either case.
    let summary: String?
    let isSummarizing: Bool
    let isSaving: Bool
    let onApply: (String) -> Void

    @State private var typedName: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(cluster.needsAssignment ? Color.appWarning.opacity(0.18) : Color.appAccent.opacity(0.18))
                        .frame(width: 32, height: 32)
                    Text(initial)
                        .font(.headline)
                        .foregroundStyle(cluster.needsAssignment ? Color.appWarning : Color.appAccentLight)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(cluster.id)
                            .font(.headline)
                            .foregroundStyle(Color.appTextPrimary)
                        if !cluster.needsAssignment {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(Color.appSuccess)
                        }
                    }
                    Text("\(cluster.segments.count) utterance\(cluster.segments.count == 1 ? "" : "s") · \(durationLabel)")
                        .font(.caption)
                        .foregroundStyle(Color.appTextSecondary)
                }
                Spacer()
            }

            // Always-on, LLM-free signals: talk time, share of meeting, and the
            // speaker's top topic keywords. Distinguishes clusters at a glance
            // even when the AI profile is missing or still generating.
            signalsRow

            // What they discussed — a 1-2 sentence summary when AI is
            // available, otherwise a short utterance excerpt fallback.
            // Long meetings can have hundreds of fragments per speaker;
            // a single sentence is enough to identify the person.
            speakerContextBlock

            // AI best match — a one-click highlighted chip when the model is
            // confident enough to name a candidate, with its reasoning.
            if cluster.needsAssignment {
                if let guess = bestGuess {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Best match")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.appTextTertiary)
                            .textCase(.uppercase).tracking(0.5)
                        Button {
                            onApply(guess.name)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "sparkles").font(.caption2)
                                Text(guess.name).font(.system(size: 13, weight: .semibold))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.appAccent)
                            .foregroundStyle(.white)
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(isSaving)
                        if !guess.reason.isEmpty {
                            Text(guess.reason)
                                .font(.caption)
                                .foregroundStyle(Color.appTextSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } else if isGuessing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Finding the best match…")
                            .font(.caption).foregroundStyle(Color.appTextSecondary)
                    }
                }
            }

            // Name picker — calendar suggestions as buttons + a free-form field
            // for anyone who isn't on the invite.
            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(bestGuess == nil ? "Suggested" : "Other attendees")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.appTextTertiary)
                        .textCase(.uppercase)
                        .tracking(0.5)
                    SpeakerSuggestionFlow(spacing: 6) {
                        ForEach(suggestions, id: \.self) { name in
                            Button {
                                onApply(name)
                            } label: {
                                Text(name)
                                    .font(.system(size: 13))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Color.appAccent.opacity(0.15))
                                    .foregroundStyle(Color.appAccentLight)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .disabled(isSaving)
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                TextField("Or type a name…", text: $typedName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        let name = typedName.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !name.isEmpty {
                            onApply(name)
                            typedName = ""
                        }
                    }
                Button {
                    let name = typedName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty {
                        onApply(name)
                        typedName = ""
                    }
                } label: {
                    if isSaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Apply")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.appAccent)
                .disabled(isSaving || typedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .background(Color.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.appSeparator, lineWidth: 0.5)
        )
    }

    /// Summary block. Three states:
    ///   - Summary text available → render it as the headline
    ///   - Summarizing in progress → spinner + "Summarising..."
    ///   - No summary (AI unavailable, or cluster too short) → fall back
    ///     to two short utterance excerpts so the card still has something
    ///     to identify the speaker by.
    @ViewBuilder
    private var speakerContextBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let summary, !summary.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.caption)
                        .foregroundStyle(Color.appAccentLight)
                        .padding(.top, 2)
                    Text(summary)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.appTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if isSummarizing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Summarising what this speaker said…")
                        .font(.caption)
                        .foregroundStyle(Color.appTextSecondary)
                }
            } else {
                // Fallback excerpt — first two sample utterances. Used when
                // AI isn't configured or the cluster is too short to bother
                // summarising. Keeps the card useful even with no LLM.
                ForEach(cluster.sampleUtterances.prefix(2), id: \.id) { t in
                    HStack(alignment: .top, spacing: 8) {
                        Text(t.formattedTimestamp)
                            .font(.caption2.monospaced())
                            .foregroundStyle(Color.appTextTertiary)
                            .frame(width: 44, alignment: .leading)
                        Text("\u{201C}\(t.text.trimmingCharacters(in: .whitespaces))\u{201D}")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.appTextPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if cluster.sampleUtterances.isEmpty {
                    Text("Only short utterances — listen to the recording to identify the voice.")
                        .font(.caption)
                        .foregroundStyle(Color.appTextTertiary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.appSurfaceSecondary.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// LLM-free distinguishing signals. Talk time + share % are metric pills;
    /// the top keywords render as small topic chips. All computed locally.
    @ViewBuilder
    private var signalsRow: some View {
        let keywords = cluster.topKeywords
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                metricPill(icon: "clock", text: durationLabel)
                if let share = shareLabel {
                    metricPill(icon: "chart.pie", text: share)
                }
            }
            if !keywords.isEmpty {
                SpeakerSuggestionFlow(spacing: 6) {
                    ForEach(keywords, id: \.self) { word in
                        Text(word)
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.appSurfaceSecondary.opacity(0.6))
                            .foregroundStyle(Color.appTextSecondary)
                            .clipShape(Capsule())
                    }
                }
            }
        }
    }

    private func metricPill(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.caption2)
            Text(text).font(.caption.weight(.medium))
        }
        .foregroundStyle(Color.appTextSecondary)
    }

    /// Share of total spoken time across all clusters, e.g. "42% of talk time".
    private var shareLabel: String? {
        guard totalMeetingSeconds > 0 else { return nil }
        let pct = Int((Double(cluster.totalSeconds) / Double(totalMeetingSeconds) * 100).rounded())
        return "\(pct)% of talk time"
    }

    private var initial: String {
        let trailing = cluster.id.split(separator: " ").last.map(String.init) ?? "?"
        return trailing
    }

    private var durationLabel: String {
        let s = cluster.totalSeconds
        let m = s / 60
        let r = s % 60
        if m > 0 { return "\(m)m \(r)s" }
        return "\(r)s"
    }
}

// MARK: - Flow layout (wraps suggestion chips)

/// Simple wrapping HStack — places children left-to-right and wraps to the
/// next row when width is exceeded. Used for the suggestion-chip row so a
/// long participant list doesn't overflow horizontally.
private struct SpeakerSuggestionFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = computeRows(maxWidth: maxWidth, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + CGFloat(max(0, rows.count - 1)) * spacing
        return CGSize(width: maxWidth.isFinite ? maxWidth : 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(maxWidth: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for entry in row.entries {
                let pos = CGPoint(x: x, y: y)
                entry.view.place(at: pos, proposal: ProposedViewSize(width: entry.size.width, height: entry.size.height))
                x += entry.size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var entries: [(view: LayoutSubview, size: CGSize)]; var height: CGFloat }

    private func computeRows(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row(entries: [], height: 0)
        var x: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if !current.entries.isEmpty, x + size.width > maxWidth {
                rows.append(current)
                current = Row(entries: [], height: 0)
                x = 0
            }
            current.entries.append((sub, size))
            current.height = max(current.height, size.height)
            x += size.width + spacing
        }
        if !current.entries.isEmpty { rows.append(current) }
        return rows
    }
}

// MARK: - Speaker Summary Cache

/// Simple file-backed cache for speaker summaries so they don't regenerate
/// on every tab open. Stored as JSON in the app support directory, one file
/// per meeting. Cleared on explicit Reload.
enum SpeakerSummaryCache {
    private static let fm = FileManager.default

    private static func cacheURL(meetingId: String) -> URL {
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MeetingManager", isDirectory: true)
            .appendingPathComponent("speaker-summaries", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(meetingId).json")
    }

    static func load(meetingId: String) -> [String: String] {
        let url = cacheURL(meetingId: meetingId)
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return dict
    }

    static func save(_ summaries: [String: String], meetingId: String) {
        let url = cacheURL(meetingId: meetingId)
        guard let data = try? JSONEncoder().encode(summaries) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func clear(meetingId: String) {
        let url = cacheURL(meetingId: meetingId)
        try? fm.removeItem(at: url)
    }
}

// MARK: - Speaker Guess Cache

/// File-backed cache for AI best-match name guesses, one file per meeting, so
/// they don't regenerate on every tab open. Cleared on explicit Reload /
/// Re-analyze (the same points that clear summaries).
enum SpeakerGuessCache {
    private static let fm = FileManager.default

    private static func cacheURL(meetingId: String) -> URL {
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MeetingManager", isDirectory: true)
            .appendingPathComponent("speaker-guesses", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(meetingId).json")
    }

    static func load(meetingId: String) -> [String: SpeakerAttributionService.NameSuggestion] {
        let url = cacheURL(meetingId: meetingId)
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: SpeakerAttributionService.NameSuggestion].self, from: data) else {
            return [:]
        }
        return dict
    }

    static func save(_ guesses: [String: SpeakerAttributionService.NameSuggestion], meetingId: String) {
        let url = cacheURL(meetingId: meetingId)
        guard let data = try? JSONEncoder().encode(guesses) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func clear(meetingId: String) {
        let url = cacheURL(meetingId: meetingId)
        try? fm.removeItem(at: url)
    }
}

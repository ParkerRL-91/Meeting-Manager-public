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

    /// LLM-generated 1-2 sentence summary per cluster. Lazy: generated when
    /// the tab is opened, cached in memory, and re-used until the user
    /// renames the cluster (at which point it drops out of the list).
    /// Long meetings with hundreds of utterances become identifiable in a
    /// single readable sentence instead of a wall of fragments.
    @State private var summaries: [String: String] = [:]
    @State private var summarizingClusters: Set<String> = []

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.meetingmanager.app", category: "ui")

    var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                Spacer()
                ProgressView()
                Spacer()
            } else if clusters.isEmpty {
                Spacer()
                EmptyStateView(
                    icon: "person.wave.2",
                    title: "No speakers to assign",
                    subtitle: "All transcript segments are already labelled, or the transcript hasn't finished processing yet."
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
                        Text("Label each speaker once — every fragment they said gets renamed. Suggestions come from this meeting's participants.")
                            .font(.caption)
                            .foregroundStyle(Color.appTextSecondary)
                            .padding(.horizontal, 16)
                            .padding(.top, 12)

                        ForEach(clusters) { cluster in
                            SpeakerClusterCard(
                                cluster: cluster,
                                meeting: meeting,
                                suggestions: suggestions(for: cluster),
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
    }

    // MARK: - Loading

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        meeting = try? await appState.meetingRepository.find(id: meetingId)
        transcripts = (try? await appState.transcriptRepository.transcriptsForMeeting(meetingId, limit: 100_000)) ?? []
        voiceProfiles = (try? await VoiceProfileRepository(database: AppDatabase.shared).allProfiles()) ?? []
        clusters = Self.buildClusters(from: transcripts)
        Self.logger.info("[SpeakerAssignment] loaded \(clusters.count) cluster(s) for meeting \(meetingId, privacy: .public)")

        // Kick per-cluster summarization in parallel. Each call summarizes
        // only what THAT cluster said — never sees other speakers, never
        // sees the meeting title or participant list, so it can't borrow
        // names from elsewhere. Capped to clusters with ≥3 utterances —
        // shorter clusters are fine to identify from the raw fragments.
        await summarizeClusters()
    }

    /// Generate a 1-2 sentence summary per cluster using the configured LLM.
    /// Idempotent: skips clusters that already have a summary cached.
    private func summarizeClusters() async {
        // 4096 output budget: longer summaries for major speakers (up to
        // 200 words) plus Qwen3's thinking tokens need more than the 2K default.
        let textGen = await appState.makeTextGenerator(maxOutputTokens: 4096)
        guard let textGen else {
            Self.logger.info("[SpeakerAssignment] no AI configured — skipping summaries")
            return
        }
        for cluster in clusters {
            guard summaries[cluster.id] == nil else { continue }
            guard cluster.segments.count >= 3 else { continue }
            summarizingClusters.insert(cluster.id)
            Task {
                let summary = await Self.summarize(cluster: cluster, textGen: textGen)
                await MainActor.run {
                    summaries[cluster.id] = summary
                    summarizingClusters.remove(cluster.id)
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
        // substantial speakers (5+ min) get two paragraphs.
        let totalDuration = cluster.totalSeconds
        let lengthGuidance: String
        if totalDuration < 60 {
            lengthGuidance = "Write 1-2 sentences (under 40 words)."
        } else if totalDuration < 300 {
            lengthGuidance = "Write a short paragraph of 3-5 sentences (60-100 words) covering the main points this speaker raised."
        } else {
            lengthGuidance = "Write two paragraphs (100-200 words). The first paragraph should cover the speaker's main topics and positions. The second should cover specific details, decisions, or action items they raised."
        }

        let system = """
            You are summarizing what one speaker said in a meeting. Read the utterances below and produce a summary of what they discussed, argued for, and contributed.

            Rules:
            - Do NOT mention any names. Refer to the speaker as "this speaker" or just describe the activity.
            - Do NOT invent details that aren't in the input.
            - Do NOT add a preamble like "Here is a summary…". Output only the summary itself.
            - \(lengthGuidance)
            """
        let user = "Utterances:\n\n\(truncated)\n\nSummarize what this speaker discussed."
        do {
            let result = try await textGen(system, user)
            return result.trimmingCharacters(in: .whitespacesAndNewlines)
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
            // Only show un-assigned cluster ids — "Speaker 1" / "Speaker N".
            // Anything else is either resolved (real name) or system audio.
            guard label.lowercased().hasPrefix("speaker ") else { continue }
            bucket[label, default: []].append(t)
        }
        return bucket
            .map { id, segments in SpeakerCluster(id: id, segments: segments) }
            .sorted(by: { $0.id < $1.id })
    }

    // MARK: - Suggestions

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
    /// Cluster id ("Speaker 1", "Speaker 2", …)
    let id: String
    let segments: [Transcript]

    var totalSeconds: Int {
        Int(segments.reduce(0) { $0 + ($1.endTime - $1.startTime) })
    }

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
    let meeting: Meeting?
    let suggestions: [String]
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
                        .fill(Color.appAccent.opacity(0.18))
                        .frame(width: 32, height: 32)
                    Text(initial)
                        .font(.headline)
                        .foregroundStyle(Color.appAccentLight)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(cluster.id)
                        .font(.headline)
                        .foregroundStyle(Color.appTextPrimary)
                    Text("\(cluster.segments.count) utterance\(cluster.segments.count == 1 ? "" : "s") · \(durationLabel)")
                        .font(.caption)
                        .foregroundStyle(Color.appTextSecondary)
                }
                Spacer()
            }

            // What they discussed — a 1-2 sentence summary when AI is
            // available, otherwise a short utterance excerpt fallback.
            // Long meetings can have hundreds of fragments per speaker;
            // a single sentence is enough to identify the person.
            speakerContextBlock

            // Name picker — calendar suggestions as buttons + a free-form field
            // for anyone who isn't on the invite.
            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Suggested")
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

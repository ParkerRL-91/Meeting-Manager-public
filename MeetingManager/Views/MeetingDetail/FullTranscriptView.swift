import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

struct FullTranscriptView: View {
    let meetingId: String

    @Environment(AppState.self) private var appState
    @State private var transcripts: [Transcript] = []
    @State private var meeting: Meeting?
    @State private var searchQuery: String = ""
    @State private var isLoading = true
    @State private var filteredTranscripts: [Transcript] = []
    @State private var speakerToCustomRename: Transcript?
    @State private var renameError: String?

    /// Transient confirmation shown after a manual rename so the user sees the
    /// "correct once, recognized forever" value loop actually happen. Cleared
    /// automatically after a few seconds.
    @State private var learnedToast: String?

    /// #8 — after a rename in a recurring meeting, offer to re-check the other
    /// meetings in the same series (they now benefit from the new alias and
    /// voiceprint). Holds the confirmed name + the other series meeting ids.
    @State private var seriesPropagation: SeriesPropagation?

    struct SeriesPropagation: Identifiable {
        let id = UUID()
        let name: String
        let meetingIds: [String]
    }

    /// Cleaned-up version of the transcript (stitched + AI-cleaned). Loaded
    /// from the cleanedTranscript table after segments load. May be nil if
    /// cleanup hasn't run yet (e.g. mid-recording, or AI failed).
    @State private var cleanedTranscript: CleanedTranscript?

    /// Raw (per-segment) vs cleaned (paragraph) view. Defaults to cleaned —
    /// the fragmented raw output is a poor reading experience. Persisted so
    /// users who prefer raw don't get bounced back each navigation.
    @AppStorage("transcript.showRaw") private var showRaw: Bool = false

    private let exportService = ExportService()

    var body: some View {
        VStack(spacing: 0) {
            // Search bar and export button
            HStack(spacing: 12) {
                SearchBar(query: $searchQuery, placeholder: "Search transcript...")

                // Cleaned vs raw toggle. Cleaned (paragraph view) is the
                // default; raw shows the fragmented per-segment view that
                // matches the live recording layout. Hidden when no cleaned
                // version exists (e.g. mid-recording or model unavailable).
                if cleanedTranscript != nil {
                    Picker("View", selection: $showRaw) {
                        Text("Cleaned").tag(false)
                        Text("Raw").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                    .help("Toggle between the AI-cleaned paragraph view and the raw per-segment transcript")
                }

                CopyButton(
                    text: { copyText() },
                    label: "Copy Transcript"
                )
                .disabled(transcripts.isEmpty)

                CopyButton(
                    text: { copyMarkdown() },
                    label: "Copy as Markdown"
                )
                .disabled(transcripts.isEmpty)

                Button {
                    Task { await exportTranscript() }
                } label: {
                    Label("Export Transcript", systemImage: "square.and.arrow.up")
                        .font(.caption)
                        .fontWeight(.medium)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(transcripts.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()
                .foregroundStyle(Color.appSeparator)

            if isLoading {
                Spacer()
                ProgressView()
                Spacer()
            } else if transcripts.isEmpty {
                Spacer()
                // Live queue truth instead of a generic placeholder: failed →
                // error + Retry; running → stage; queued → position. When
                // audio exists but nothing was ever queued (the silent-loss
                // cohort TASK-031 surfaced), offer Transcribe Now directly.
                MeetingPipelineStatusView(
                    meetingId: meetingId,
                    taskTypes: [.transcription, .diarization],
                    fallbackIcon: "text.quote",
                    fallbackTitle: "No Transcript",
                    fallbackSubtitle: meeting?.audioFilePaths.isEmpty == false
                        ? "This meeting has audio that hasn't been transcribed."
                        : "The transcript will appear here once the meeting recording is processed.",
                    fallbackActionLabel: meeting?.audioFilePaths.isEmpty == false ? "Transcribe Now" : nil,
                    fallbackAction: meeting?.audioFilePaths.isEmpty == false ? {
                        _ = await appState.taskQueueManager.enqueue(
                            type: .transcription, meetingId: meetingId, priority: 0
                        )
                        await appState.taskQueueManager.refreshTaskList()
                    } : nil
                )
                Spacer()
            } else if !showRaw, let cleaned = cleanedTranscript, searchQuery.isEmpty {
                // Cleaned view — paragraph-rendered Markdown. We bypass the
                // search-empty branch when in cleaned mode without a search
                // query because cleaned text isn't indexed as segments.
                // The diagnostic banner is shown here too (it used to appear
                // only in the raw segment list), so the default view explains
                // why speaker names are missing and offers the next step.
                attributionDiagnosticBanner
                cleanedView(cleaned)
            } else if filteredTranscripts.isEmpty {
                Spacer()
                EmptyStateView(
                    icon: "magnifyingglass",
                    title: "No Results",
                    subtitle: "No transcript segments match \"\(searchQuery)\". Try different search terms."
                )
                Spacer()
            } else {
                attributionDiagnosticBanner
                transcriptList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            meeting = try? await appState.meetingRepository.find(id: meetingId)
            await loadTranscripts()
            updateFilteredTranscripts()
        }
        .onChange(of: searchQuery) { _, _ in updateFilteredTranscripts() }
        .onChange(of: transcripts) { _, _ in updateFilteredTranscripts() }
        .refreshOnTaskCompletion(
            meetingId: meetingId,
            types: [.transcription, .transcriptCleanup, .diarization, .retryAttribution],
            tasks: appState.taskQueueManager.allTasks
        ) {
            Task {
                meeting = try? await appState.meetingRepository.find(id: meetingId)
                await loadTranscripts()
                updateFilteredTranscripts()
            }
        }
        .sheet(item: $speakerToCustomRename) { transcript in
            CustomSpeakerNameSheet(
                currentName: transcript.displayedSpeakerName(
                    meeting: meeting,
                    userDisplayName: NSFullUserName()
                )
            ) { newName in
                renameSpeaker(transcript: transcript, newName: newName)
            }
        }
        .alert("Rename Failed", isPresented: Binding(
            get: { renameError != nil },
            set: { if !$0 { renameError = nil } }
        )) {
            Button("OK", role: .cancel) { renameError = nil }
        } message: {
            Text(renameError ?? "")
        }
        .confirmationDialog(
            "Apply across this series?",
            isPresented: Binding(
                get: { seriesPropagation != nil },
                set: { if !$0 { seriesPropagation = nil } }
            ),
            presenting: seriesPropagation
        ) { prop in
            Button("Re-check \(prop.meetingIds.count) earlier meeting\(prop.meetingIds.count == 1 ? "" : "s")") {
                propagateAcrossSeries(prop.meetingIds)
                seriesPropagation = nil
            }
            Button("Not now", role: .cancel) { seriesPropagation = nil }
        } message: { prop in
            Text("\(prop.name) was just confirmed. Re-check earlier meetings in this series so the same voice is recognized there too. Names you already confirmed are left unchanged.")
        }
        .overlay(alignment: .bottom) {
            if let toast = learnedToast {
                HStack(spacing: 8) {
                    Image(systemName: "waveform.badge.checkmark")
                        .foregroundStyle(Color.appAccent)
                    Text(toast)
                        .font(.callout)
                        .foregroundStyle(Color.appTextPrimary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.appSeparator))
                .padding(.bottom, 20)
                .shadow(radius: 8, y: 2)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: learnedToast)
    }

    // MARK: - Attribution Diagnostic Banner

    /// Returns a thin in-list banner when the transcript still contains
    /// unattributed Speaker N rows AND the meeting actually has calendar
    /// attendees we could've matched against. The banner text reflects the
    /// specific failure reason from the most recent attribution attempt
    /// (cached on AppState.lastAttributionReason) so the user knows *why*
    /// — Ollama down vs all-Unknown vs no LLM configured — instead of a
    /// generic "couldn't attribute".
    @ViewBuilder
    private var attributionDiagnosticBanner: some View {
        let unconfirmedCount = transcripts.filter {
            ($0.speakerLabel ?? "").lowercased().hasPrefix("speaker")
        }.count
        let attendees = meeting?.participantList.count ?? 0

        if unconfirmedCount > 0 && attendees > 0 {
            let reason = AppState.lastAttributionReason[meetingId]
            let message = reason?.userFacingMessage
                ?? "\(unconfirmedCount) unmatched speaker turn\(unconfirmedCount == 1 ? "" : "s") — tap a `Speaker N` label below to assign one of the \(attendees) attendee\(attendees == 1 ? "" : "s")."
            // For the .noLLMAvailable + .noCandidates reasons, "Re-run AI" is
            // pointless — the underlying issue isn't the AI run.
            let retryActionable = reason != .noLLMAvailable && reason != .noCandidates

            HStack(spacing: 8) {
                Image(systemName: bannerIcon(for: reason))
                    .font(.caption)
                    .foregroundStyle(Color.appAccentLight)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if retryActionable {
                    Button("Re-run AI") {
                        Task { await rerunAttribution() }
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.appAccent.opacity(0.08))
        }
    }

    private func bannerIcon(for reason: AttributionReason?) -> String {
        switch reason {
        case .noLLMAvailable, .llmCallFailed: return "exclamationmark.triangle"
        case .noClusters, .noNonMicTurns, .noCandidates: return "info.circle"
        case .llmReturnedAllUnknown, .none: return "questionmark.circle"
        case .ok, .okEscalated: return "checkmark.circle"
        }
    }

    /// Manual re-run of LLM attribution from the diagnostic banner. Reloads
    /// transcripts after the run so any newly-mapped clusters reflect in the
    /// UI without requiring a navigation round-trip.
    private func rerunAttribution() async {
        guard let meetingId = meeting?.id else { return }
        await appState.rerunSpeakerAttribution(for: meetingId)
        await loadTranscripts()
        meeting = try? await appState.meetingRepository.find(id: meetingId)
    }

    // MARK: - Transcript List

    private var transcriptList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(filteredTranscripts) { transcript in
                    TranscriptBubble(
                        transcript: transcript,
                        meeting: meeting,
                        onRename: { action in
                            handleRenameAction(action, for: transcript)
                        },
                        isAIAttributed: isAIAttributed(transcript),
                        attributionConfidence: confidenceFor(transcript)
                    )

                    if transcript.id != filteredTranscripts.last?.id {
                        Divider()
                            .foregroundStyle(Color.appSeparator.opacity(0.5))
                            .padding(.leading, 66)
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }

    // MARK: - Rename

    /// True when the transcript's `speakerLabel` was assigned by the LLM
    /// (i.e. the meeting's `speakerMap` contains the cluster id as a key OR
    /// the resolved name as a value). Per the v3.1 plan we keep this purely
    /// in-memory for ship — once the user clicks rename the local
    /// `meeting.speakerMap` no longer reflects an unconfirmed mapping after
    /// the upsert path completes the next reload.
    private func isAIAttributed(_ transcript: Transcript) -> Bool {
        guard let label = transcript.speakerLabel,
              let map = meeting?.speakerMapDictionary,
              !map.isEmpty else { return false }
        // The label may be the cluster id (pre-Layer-2 rewrite) OR the mapped
        // name (post-rewrite). Match either side.
        if map.keys.contains(label) { return true }
        if map.values.contains(label) { return true }
        return false
    }

    /// v3.10 #2: look up the attribution confidence for a transcript row.
    /// The confidence map is keyed by cluster id (Speaker N), so when the
    /// transcript's speakerLabel has already been rewritten to the resolved
    /// name we reverse-look-up via speakerMap.
    ///
    /// When the same name maps to multiple clusters (legitimate diarization
    /// over-split), we surface the *minimum* confidence — the worst-case is
    /// what the user wants to see when triaging "which labels need review".
    /// Returns nil for legacy meetings without a confidence map.
    private func confidenceFor(_ transcript: Transcript) -> Float? {
        guard let label = transcript.speakerLabel,
              let confMap = meeting?.speakerConfidenceMapDictionary,
              !confMap.isEmpty else { return nil }
        // Direct hit (cluster id key) — most specific signal wins.
        if let c = confMap[label] { return c }
        // Reverse lookup: collect every cluster whose mapping resolves to
        // this name, return the minimum confidence among them.
        guard let map = meeting?.speakerMapDictionary else { return nil }
        let candidates = map
            .filter { $0.value == label }
            .compactMap { confMap[$0.key] }
        return candidates.min()
    }

    private func handleRenameAction(_ action: TranscriptBubbleRenameAction,
                                    for transcript: Transcript) {
        switch action {
        case .assign(let name):
            renameSpeaker(transcript: transcript, newName: name)
        case .custom:
            speakerToCustomRename = transcript
        }
    }

    private func renameSpeaker(transcript: Transcript, newName: String) {
        Task { @MainActor in
            guard let meeting else { return }
            let clusterId = transcript.speakerLabel ?? ""
            guard !clusterId.isEmpty else { return }
            let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != clusterId else { return }

            // 1. Bulk-rename every transcript in this meeting where speakerLabel == clusterId.
            do {
                try await appState.transcriptRepository.updateSpeakerLabel(
                    meetingId: meeting.id,
                    from: clusterId,
                    to: trimmed
                )
            } catch {
                renameError = error.localizedDescription
                return
            }

            // 2. Persist the new mapping on the meeting.
            var updated = meeting
            var map = updated.speakerMapDictionary
            map[clusterId] = trimmed
            updated.setSpeakerMap(map)
            // v3.10 #2: manual rename is ground truth — record full confidence
            // so the amber "needs review" dot disappears for this cluster.
            var confMap = updated.speakerConfidenceMapDictionary
            confMap[clusterId] = 1.0
            updated.setSpeakerConfidenceMap(confMap)
            do {
                try await appState.meetingRepository.update(updated)
                self.meeting = updated
            } catch {
                // Non-fatal — the transcripts are already renamed; the alias
                // upsert below still records the user's intent for future
                // meetings in the series.
                renameError = error.localizedDescription
            }

            // 3. Patch the cleaned transcript blob in place so the readable
            //    view picks up the new name immediately. The cleaned text is
            //    deterministic Markdown — speaker names appear only as
            //    `**Name**` headers per turn, so a token replace is safe.
            //    Falls back silently when no cleaned blob exists yet.
            let cleanedRepo = CleanedTranscriptRepository(database: AppDatabase.shared)
            if var cleaned = try? await cleanedRepo.cleanedTranscript(meetingId: meeting.id) {
                let oldToken = "**\(clusterId)**"
                let newToken = "**\(trimmed)**"
                if cleaned.text.contains(oldToken) {
                    cleaned.text = cleaned.text.replacingOccurrences(of: oldToken, with: newToken)
                    try? await cleanedRepo.save(cleaned)
                }
            }

            // 4. Remember for future meetings in the same series.
            let seriesKey = MeetingSeriesService.shared.seriesKey(for: meeting)
            try? await SpeakerAliasRepository(database: AppDatabase.shared)
                .upsert(seriesKey: seriesKey, clusterId: clusterId, resolvedName: trimmed)

            // 5. Cross-meeting learning: extract this voice's fingerprint and
            // merge into the profile DB. The next meeting that captures this
            // person's voice will auto-attribute without an LLM call. This is
            // the highest-confidence signal we get — manual user rename — so
            // it's worth feeding the profile system aggressively.
            await appState.learnVoiceProfiles(meetingId: meeting.id)

            // 6. Reload to reflect the rewritten labels.
            await loadTranscripts()
            updateFilteredTranscripts()

            // #2 — make the learning loop visible. The rename just taught the
            // voice DB; tell the user so the "correct once, recognized forever"
            // value is felt rather than silent.
            let firstName = trimmed.components(separatedBy: " ").first ?? trimmed
            showLearnedToast("\(firstName)'s voice will be recognized in future meetings.")

            // #8 — offer to apply across the series. Other meetings in the same
            // series can now be re-checked: they pick up the new alias and the
            // freshly-learned voiceprint. Re-attribution only fills unresolved
            // "Speaker N" clusters and preserves names already confirmed, so it
            // can't clobber prior manual work. (seriesKey computed in step 4.)
            let others = appState.meetings.filter {
                $0.id != meeting.id
                && MeetingSeriesService.shared.seriesKey(for: $0) == seriesKey
            }
            if !others.isEmpty {
                seriesPropagation = SeriesPropagation(
                    name: trimmed,
                    meetingIds: Array(others.prefix(25)).map { $0.id }
                )
            }
        }
    }

    /// Re-run speaker attribution on the given past meetings so a name just
    /// confirmed here propagates across the series. Each re-run is safe: it
    /// fills only unresolved clusters and leaves resolved names intact.
    private func propagateAcrossSeries(_ ids: [String]) {
        Task { @MainActor in
            for id in ids {
                await appState.rerunSpeakerAttribution(for: id)
            }
            showLearnedToast("Re-checked \(ids.count) earlier meeting\(ids.count == 1 ? "" : "s") in this series.")
        }
    }

    /// Show a transient confirmation toast, auto-dismissing after 4s. A nonce
    /// guards against an earlier toast's timer clearing a newer message.
    @State private var toastNonce = 0
    private func showLearnedToast(_ message: String) {
        toastNonce += 1
        let nonce = toastNonce
        learnedToast = message
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            if toastNonce == nonce { learnedToast = nil }
        }
    }

    // MARK: - Filtering

    private func updateFilteredTranscripts() {
        if searchQuery.isEmpty {
            filteredTranscripts = transcripts
        } else {
            let userName = NSFullUserName()
            let m = meeting
            filteredTranscripts = transcripts.filter {
                $0.text.localizedCaseInsensitiveContains(searchQuery)
                || $0.displayedSpeakerName(meeting: m, userDisplayName: userName)
                    .localizedCaseInsensitiveContains(searchQuery)
            }
        }
    }

    // MARK: - Copy

    private func formatTranscriptText() -> String {
        let userName = NSFullUserName()
        let m = meeting
        return transcripts.map { transcript in
            let speaker = transcript.displayedSpeakerName(meeting: m, userDisplayName: userName)
            return "[\(transcript.formattedTimestamp)] \(speaker): \(transcript.text)"
        }.joined(separator: "\n\n")
    }

    private func formatTranscriptMarkdown() -> String {
        guard let meeting else { return formatTranscriptText() }
        return exportService.exportTranscriptText(meeting: meeting, transcripts: transcripts)
    }

    // MARK: - Export

    private func exportTranscript() async {
        guard let meeting else { return }
        let content = exportService.exportTranscriptText(meeting: meeting, transcripts: transcripts)
        let filename = ExportService.sanitizedFilename(from: meeting.title) + "-transcript.txt"
        _ = await exportService.saveToFile(content: content, suggestedName: filename, fileType: "txt")
    }

    // MARK: - Data Loading

    private func loadTranscripts() async {
        isLoading = true
        defer { isLoading = false }
        transcripts = (try? await appState.transcriptRepository.transcriptsForMeeting(meetingId)) ?? []
        // Pull the cleaned blob (may be nil if cleanup hasn't run yet).
        cleanedTranscript = try? await CleanedTranscriptRepository().cleanedTranscript(meetingId: meetingId)
    }

    // MARK: - Cleaned view

    @ViewBuilder
    private func cleanedView(_ cleaned: CleanedTranscript) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Method footer — small affordance so users see whether the
                // AI pass ran or only the deterministic stitch.
                methodFooter(cleaned.method)

                MarkdownRenderer(text: cleaned.text, baseFontSize: 14, headingStyle: .neutral)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
    }

    private func methodFooter(_ method: String) -> some View {
        let (label, icon): (String, String) = {
            switch method {
            case "stitch+ai":  return ("AI-cleaned", "sparkles")
            case "ai-failed":  return ("Stitched (AI cleanup unavailable)", "exclamationmark.triangle")
            default:           return ("Stitched", "text.alignleft")
            }
        }()
        return HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(method == "ai-failed" ? Color.appWarning : Color.appAccent)
            Text(label)
                .font(.caption)
                .foregroundStyle(Color.appTextTertiary)

            if method == "ai-failed" || method == "stitch" {
                Button {
                    Task {
                        // Run cleanup directly and refresh the view on completion.
                        await appState.runTranscriptCleanup(meetingId: meetingId)
                        cleanedTranscript = try? await CleanedTranscriptRepository().cleanedTranscript(meetingId: meetingId)
                    }
                } label: {
                    Text(method == "ai-failed" ? "Retry AI cleanup" : "Run AI cleanup")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.appAccent)
                }
                .buttonStyle(.plain)
                .help("Run AI transcript cleanup with the current model")
            }

            Spacer()
        }
    }

    // MARK: - Copy helpers

    /// Plain-text copy. When cleaned is showing, copy the cleaned text;
    /// otherwise the per-segment text. Keeps copy behavior aligned with
    /// what the user is looking at.
    private func copyText() -> String {
        if !showRaw, let cleaned = cleanedTranscript {
            // Strip markdown for plain-text use.
            return cleaned.text
                .replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "_", with: "")
        }
        return formatTranscriptText()
    }

    private func copyMarkdown() -> String {
        if !showRaw, let cleaned = cleanedTranscript {
            return cleaned.text
        }
        return formatTranscriptMarkdown()
    }
}

// MARK: - Previews

// #Preview("With Transcripts") {
//     FullTranscriptView(meetingId: "preview-1")
//         .environment(AppState())
//         .frame(width: 600, height: 500)
//         .background(Color.appBackground)
// }

// #Preview("Empty") {
//     FullTranscriptView(meetingId: "no-transcript")
//         .environment(AppState())
//         .frame(width: 600, height: 500)
//         .background(Color.appBackground)
// }

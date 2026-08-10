import SwiftUI
import os
#if canImport(AppKit)
import AppKit
#endif

struct SummaryView: View {
    let meetingId: String

    @Environment(AppState.self) private var appState
    @State private var summary: MeetingSummary?
    @State private var meeting: Meeting?
    @State private var isLoading = true
    @State private var copiedToClipboard = false
    @State private var copiedMarkdownToClipboard = false

    // Inline auto-save editor state (P1-T04).
    // editableContent is the always-mounted TextEditor's binding. originalContent
    // is the AI-generated text used to drive the "Edited" badge. saveTask debounces
    // persistence with the same 1-second pattern as NotepadPaneView.
    @State private var editableContent: String = ""
    @State private var originalContent: String = ""
    @State private var saveTask: Task<Void, Never>?
    @State private var showSavedFlash = false
    @State private var hasLoadedEditor = false
    @State private var errorMessage: String?

    /// Free-form edit toggle for the rawEditorBlock fallback path.
    /// When false, the body renders as Markdown with hidden syntax characters.
    /// When true, swaps in a source-mode editor with the syntax visible (dimmed).
    @State private var isFreeformEditing: Bool = false

    // Regeneration state — derived from the persistent task queue, not local @State.
    // This means regeneration survives view disappearance and navigation.
    private var isRegenerating: Bool {
        appState.taskQueueManager.allTasks.contains {
            $0.type == .regeneration &&
            $0.meetingId == meetingId &&
            ($0.status == .pending || $0.status == .running)
        }
    }

    private var regenerateError: String? {
        appState.taskQueueManager.allTasks
            .filter { $0.type == .regeneration && $0.meetingId == meetingId && $0.status == .failed }
            .sorted { ($0.createdAt) > ($1.createdAt) }
            .first?.error
    }

    // History
    @State private var showHistory = false

    // Empty state
    @State private var transcriptCount = 0
    @State private var intentRecord: MeetingIntent?
    @State private var sentiment: [MeetingSentiment] = []
    @State private var recipes: [Recipe] = []
    @State private var selectedRecipe: Recipe? = nil
    @State private var previousSessions: [Meeting] = []

    private let exportService = ExportService()
    private let richShareService = RichShareService()

    // Email draft sheet state (P3-T03).
    @State private var emailDraftText: String?
    @State private var isDraftingEmail = false
    @State private var emailRecipeEngine = RecipeEngine()

    /// True when the pipeline is actively preparing the summary for the first
    /// time (no summary persisted yet). We hide stage names and percentages
    /// behind a single skeleton view (P1-T05).
    private var isPreparingFirstSummary: Bool {
        guard summary == nil, let status = meeting?.status else { return false }
        return status == .transcribing || status == .summarizing
    }

    var body: some View {
        Group {
            if isLoading {
                Spacer()
                ProgressView()
                Spacer()
            } else if isPreparingFirstSummary {
                SummarySkeletonView()
            } else if let summary {
                summaryContent(summary)
            } else {
                noSummaryEmptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .errorAlert($errorMessage)
        .onDisappear {
            // Cancel pending debounce, flush any unsaved edit synchronously.
            saveTask?.cancel()
            flushPendingSaveIfNeeded()
        }
        // Auto-refresh in place when the post-meeting pipeline finishes — the
        // initial `.summary` task (auto-run after a meeting ends), a manual
        // `.regeneration`, or the `.transcription` that gates the empty state.
        // Previously only `.regeneration` was handled, so the first summary
        // didn't appear until the user navigated away and back.
        .refreshOnTaskCompletion(
            meetingId: meetingId,
            types: [.summary, .regeneration, .transcription],
            tasks: appState.taskQueueManager.allTasks
        ) {
            Task {
                meeting = try? await appState.meetingRepository.find(id: meetingId)
                await loadSummary()
                await loadEmptyStateMeta()
            }
        }
        .task {
            meeting = try? await appState.meetingRepository.find(id: meetingId)
            intentRecord = try? await MeetingIntentRepository(database: appState.database).find(meetingId: meetingId)
            sentiment = (try? await SentimentRepository(database: appState.database).sentiment(meetingId: meetingId)) ?? []
            async let summaryLoad: () = loadSummary()
            async let metaLoad: () = loadEmptyStateMeta()
            await summaryLoad
            await metaLoad
            if let m = meeting {
                previousSessions = MeetingSeriesService.shared.detectSeries(for: m, in: appState.meetings)
            }
        }
        .sheet(isPresented: $showHistory) {
            SummaryHistoryView(meetingId: meetingId)
                .environment(appState)
        }
        .sheet(item: Binding(
            get: { emailDraftText.map { EmailDraftPayload(text: $0) } },
            set: { emailDraftText = $0?.text }
        )) { payload in
            EmailDraftResultView(
                rawText: payload.text,
                meetingTitle: meeting?.title ?? "Meeting"
            )
        }
    }

    private struct EmailDraftPayload: Identifiable {
        let id = UUID()
        let text: String
    }

    // MARK: - No Summary Empty State

    /// A summary/regeneration task currently queued, running, or failed for
    /// this meeting — when present, the empty state shows the live queue
    /// truth (stage / position / error + Retry) instead of the Generate
    /// button (TASK-041).
    private var activeSummaryTask: TaskQueueItem? {
        appState.taskQueueManager.allTasks.last {
            $0.meetingId == meetingId
            && ($0.type == .summary || $0.type == .regeneration)
            && $0.status != .completed
        }
    }

    private var summaryQueueStatusView: some View {
        MeetingPipelineStatusView(
            meetingId: meetingId,
            taskTypes: [.summary, .regeneration],
            fallbackIcon: "doc.text",
            fallbackTitle: "No Summary",
            fallbackSubtitle: "Generate a summary from the transcript."
        )
    }

    @ViewBuilder
    private var noSummaryEmptyState: some View {
        VStack(spacing: 0) {
            Spacer()
            if activeSummaryTask != nil {
                summaryQueueStatusView
            } else if transcriptCount == 0 {
                if meeting?.noSpeechDetectedAt != nil {
                    // TASK-123: the meeting WAS recorded but the audio was
                    // silent. The old copy ("Record this meeting to capture
                    // audio") told the user to do something they already did —
                    // this is the default tab, so it must tell the truth.
                    VStack(spacing: 12) {
                        Image(systemName: "waveform.slash")
                            .font(.system(size: 44))
                            .foregroundStyle(.tertiary)
                        Text("No Speech Was Captured")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text("This meeting was recorded, but the microphone and\nsystem audio were silent, so there is nothing to summarize.\nYou can retry transcription from the Transcript tab.")
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                            .lineSpacing(3)
                    }
                    .padding(.horizontal, 40)
                } else {
                    // No transcript — explain why generation isn't possible
                    VStack(spacing: 12) {
                        Image(systemName: "waveform.slash")
                            .font(.system(size: 44))
                            .foregroundStyle(.tertiary)
                        Text("No Transcript Available")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text("A summary can only be generated from a transcript.\nRecord this meeting to capture audio, then Meeting Manager\nwill transcribe it automatically.")
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                            .lineSpacing(3)
                    }
                    .padding(.horizontal, 40)
                }
            } else {
                // Has transcript — show generate button with recipe picker
                VStack(spacing: 20) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 44))
                        .foregroundStyle(.secondary)

                    VStack(spacing: 6) {
                        Text("Ready to Summarize")
                            .font(.title3.weight(.semibold))
                        Text("This meeting has a transcript. Choose a template and generate your summary.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    if isRegenerating {
                        VStack(spacing: 8) {
                            ProgressView()
                            Text("Generating summary…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        // Generate button + recipe dropdown
                        HStack(spacing: 0) {
                            Button {
                                regenerateSummary(recipe: selectedRecipe)
                            } label: {
                                Label(
                                    selectedRecipe == nil ? "Generate Summary" : "Generate: \(selectedRecipe!.name)",
                                    systemImage: "sparkles"
                                )
                                .padding(.horizontal, 4)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.appAccent)
                            .controlSize(.large)

                            Divider()
                                .frame(height: 20)
                                .padding(.horizontal, 2)

                            Menu {
                                Button {
                                    selectedRecipe = nil
                                } label: {
                                    HStack {
                                        Label("Standard Summary", systemImage: "doc.text")
                                        if selectedRecipe == nil {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }

                                if !recipes.isEmpty {
                                    Divider()
                                    ForEach(recipes) { recipe in
                                        Button {
                                            selectedRecipe = recipe
                                        } label: {
                                            HStack {
                                                Label(recipe.name, systemImage: recipe.category.icon)
                                                if selectedRecipe?.id == recipe.id {
                                                    Image(systemName: "checkmark")
                                                }
                                            }
                                        }
                                    }
                                }
                            } label: {
                                Image(systemName: "chevron.down")
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                            }
                            .menuStyle(.borderlessButton)
                            .buttonStyle(.borderedProminent)
                            .tint(Color.appAccent)
                            .controlSize(.large)
                        }

                        if let recipe = selectedRecipe {
                            Text(recipe.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }

                    if let error = regenerateError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }
                }
                .padding(.horizontal, 60)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Summary Content

    /// TASK-079: coarse, neutral tone read — meeting-level chip + per-speaker
    /// chips. An observation, not a judgment.
    @ViewBuilder
    private var toneStrip: some View {
        let meetingTone = sentiment.first { $0.scope == "meeting" }
        let speakerTones = sentiment.filter { $0.scope == "speaker" && $0.label != "neutral" }
        if let meetingTone {
            HStack(spacing: 8) {
                Image(systemName: meetingTone.icon)
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)
                Text("Tone: \(meetingTone.displayLabel)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.appTextSecondary)
                ForEach(speakerTones.prefix(4)) { t in
                    if let key = t.speakerKey {
                        Text("\(key.capitalized): \(t.displayLabel.replacingOccurrences(of: "Leaned ", with: ""))")
                            .font(.caption2)
                            .foregroundStyle(Color.appTextTertiary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.appSurfaceSecondary.opacity(0.6))
                            .clipShape(Capsule())
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .help("A coarse, on-device read of the conversation's tone. An observation, not a judgment.")
        }
    }

    @ViewBuilder
    private func summaryContent(_ summary: MeetingSummary) -> some View {
        VStack(spacing: 0) {
            toneStrip
            // TASK-065: what you needed from this meeting, and whether the
            // record shows you got it.
            if let intent = intentRecord, let score = intent.outcomeScore {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "target")
                        .font(.caption)
                        .foregroundStyle(Color.appAccent)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(intent.intent)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(Color.appTextSecondary)
                                .lineLimit(1)
                            Text(IntentScoring.label(for: score))
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(score == "met" ? Color.appSuccess : Color.appTextSecondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background((score == "met" ? Color.appSuccess : Color.appTextTertiary).opacity(0.15))
                                .clipShape(Capsule())
                        }
                        if let note = intent.outcomeNote, !note.isEmpty {
                            Text(note)
                                .font(.caption)
                                .foregroundStyle(Color.appTextTertiary)
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.appSurfaceSecondary.opacity(0.35))
            }
            // Toolbar
            HStack(spacing: 12) {
                if isEdited {
                    Text("Edited")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.appWarning)
                        .clipShape(Capsule())
                }

                if summary.notesInformedSummary {
                    Label("Shaped by your notes", systemImage: "note.text")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Color.appAccent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.appAccent.opacity(0.14))
                        .clipShape(Capsule())
                        .help("This summary was anchored to the notes you captured.")
                }

                if showSavedFlash {
                    Label("Saved", systemImage: "checkmark")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                        .foregroundStyle(Color.appSuccess)
                        .transition(.opacity)
                }

                if isRegenerating {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Regenerating…")
                            .font(.caption)
                            .foregroundStyle(Color.appTextTertiary)
                    }
                }

                Spacer()

                standardToolbar(summary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Rectangle()
                .fill(Color.appSeparator)
                .frame(height: 1)

            if let error = regenerateError {
                regenerateErrorBanner(error)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    let parsed = SummaryParser.parse(editableContent)

                    // TL;DR card
                    if !parsed.tldr.isEmpty {
                        TLDRCard(lines: parsed.tldr)
                            .padding(.bottom, 22)
                    }

                    // Two-column section grid (only when sections are populated;
                    // an all-empty grid happens when the AI emits headings with
                    // prose underneath that didn't pack into recognisable items).
                    let hasUsefulSections = parsed.sections.contains { !$0.items.isEmpty }
                    if hasUsefulSections {
                        SkimFirstSectionGrid(sections: parsed.sections)
                            .padding(.bottom, 28)
                    } else {
                        // No structured content fit the grid — render the full
                        // summary as Markdown (headings styled, syntax hidden).
                        rawEditorBlock
                            .padding(.bottom, 16)
                    }

                    // Action items
                    SkimSectionLabel(kind: .decisions, title: "Action items")
                        .padding(.bottom, 8)
                    InlineActionItemsSection(meetingId: meetingId)
                        .padding(.bottom, 28)

                    // Decisions (PRJ-017 F1) — self-hides when none were extracted.
                    DecisionsSection(meetingId: meetingId)
                        .padding(.bottom, 28)

                    // Previous sessions strip — populated from meeting series
                    if !previousSessions.isEmpty {
                        PreviousSessionsStrip(
                            sessions: previousSessions,
                            onSelect: { id in
                                appState.selectedMeetingId = id
                            }
                        )
                        .padding(.bottom, 16)
                    }

                    // Transcript link
                    Button {
                        NotificationCenter.default.post(name: .switchTab, object: "transcript")
                    } label: {
                        Label("View raw transcript", systemImage: "text.quote")
                            .font(.caption)
                            .foregroundStyle(Color.appTextTertiary)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 8)

                    // PRJ-014: KB documents fed to the model as background for this
                    // summary. Renders only when non-empty.
                    if !summary.kbSources.isEmpty {
                        KBReferencesView(kbSources: summary.kbSources)
                            .padding(.top, 8)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .padding(.bottom, 12)
            }
        }
        .onAppear { loadEditorIfNeeded(from: summary) }
        .onChange(of: summary.id) { _, _ in
            hasLoadedEditor = false
            loadEditorIfNeeded(from: summary)
        }
        .onChange(of: editableContent) { _, _ in
            guard hasLoadedEditor else { return }
            scheduleSave()
        }
    }

    @ViewBuilder
    private var rawEditorBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Spacer()
                Button(isFreeformEditing ? "Done" : "Edit") {
                    isFreeformEditing.toggle()
                }
                .font(.caption)
                .foregroundStyle(Color.appAccent)
                .buttonStyle(.plain)
            }

            if isFreeformEditing {
                // Source-mode editor — Markdown syntax stays visible (dimmed)
                // so the user can edit raw text. Auto-saves via the existing
                // editableContent binding + onChange watcher.
                MarkdownTextEditor(
                    text: $editableContent,
                    baseFontSize: 14,
                    textColor: NSColor.labelColor,
                    insets: NSSize(width: 4, height: 4)
                )
                .frame(minHeight: 240)
                .background(Color.appBackground)
            } else {
                // Render-mode display — Markdown syntax characters hidden;
                // headings appear as headings, **bold** appears bolded, etc.
                MarkdownRenderer(text: editableContent, baseFontSize: 14)
                    .foregroundStyle(Color.appTextPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func regenerateErrorBanner(_ error: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.appWarning)
            Text(error)
                .font(.caption)
                .foregroundStyle(Color.appTextPrimary)
                .lineLimit(2)
            Spacer()
            Button("Retry") { regenerateSummary() }
                .buttonStyle(.bordered)
                .controlSize(.small)
            Button("Dismiss") {
                Task {
                    if let failedTask = appState.taskQueueManager.allTasks.first(where: {
                        $0.type == .regeneration && $0.meetingId == meetingId && $0.status == .failed
                    }) {
                        await appState.taskQueueManager.cancel(taskId: failedTask.id)
                    }
                }
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(Color.appTextTertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.appWarning.opacity(0.12))
    }

    // MARK: - Toolbar

    @ViewBuilder
    private func standardToolbar(_ summary: MeetingSummary) -> some View {
        // Split share button: primary tap copies as rich text; chevron menu
        // exposes Markdown copy, system share, and HTML export. (P3-T01 / P3-T04)
        HStack(spacing: 0) {
            Button {
                copyAsRichText(summary)
            } label: {
                Label(
                    copiedToClipboard ? "Copied" : "Copy",
                    systemImage: copiedToClipboard ? "checkmark" : "doc.on.doc"
                )
                .font(.caption)
                .fontWeight(.medium)
                .padding(.horizontal, 2)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Menu {
                Button {
                    copyAsMarkdown(summary)
                } label: {
                    Label(
                        copiedMarkdownToClipboard ? "Copied as Markdown" : "Copy as Markdown",
                        systemImage: copiedMarkdownToClipboard ? "checkmark" : "text.document"
                    )
                }

                Button {
                    Task { await openInBrowser(summary) }
                } label: {
                    Label("Export HTML / Open in Browser", systemImage: "safari")
                }

                Divider()

                Button {
                    systemShare(summary)
                } label: {
                    Label("AirDrop / System Share…", systemImage: "square.and.arrow.up")
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 22)
            .controlSize(.small)
        }

        Button {
            draftFollowUpEmail()
        } label: {
            Label(
                isDraftingEmail ? "Drafting…" : "Draft Email",
                systemImage: "envelope"
            )
            .font(.caption)
            .fontWeight(.medium)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(isDraftingEmail)

        Button {
            regenerateSummary(recipe: selectedRecipe)
        } label: {
            Label("Regenerate", systemImage: "arrow.clockwise")
                .font(.caption)
                .fontWeight(.medium)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)

        Button {
            showHistory = true
        } label: {
            Label("History", systemImage: "clock.arrow.circlepath")
                .font(.caption)
                .fontWeight(.medium)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    // MARK: - Share / Export Actions (P3-T01 / P3-T04)

    private func copyAsRichText(_ summary: MeetingSummary) {
        guard let meeting else { return }
        Task {
            let actionRepo = TaskRepository(database: appState.database)
            let items = (try? await actionRepo.itemsForMeeting(meetingId)) ?? []

            // Build a transient summary with the live edited text so what the
            // user sees is what they paste.
            var live = summary
            live.summaryText = editableContent

            await MainActor.run {
                _ = richShareService.copyAsRichText(meeting: meeting, summary: live, actionItems: items)
                withAnimation { copiedToClipboard = true }
            }
            try? await Task.sleep(for: .seconds(2))
            await MainActor.run { withAnimation { copiedToClipboard = false } }
        }
    }

    private func systemShare(_ summary: MeetingSummary) {
        guard let meeting else { return }
        let formatted = exportService.exportSummaryMarkdown(meeting: meeting, summary: summary)
        ShareService.share(formatted)
    }

    @MainActor
    private func openInBrowser(_ summary: MeetingSummary) async {
        guard let meeting else { return }
        let transcripts = (try? await appState.transcriptRepository.transcriptsForMeeting(meetingId)) ?? []
        let notes = (try? await appState.noteRepository.notesForMeeting(meetingId)) ?? []
        let actionRepo = TaskRepository(database: appState.database)
        let items = (try? await actionRepo.itemsForMeeting(meetingId)) ?? []
        do {
            // Use the live edited summary so what the browser shows matches.
            var live = summary
            live.summaryText = editableContent
            _ = try exportService.writeHTMLAndOpen(
                meeting: meeting,
                summary: live,
                transcripts: transcripts,
                notes: notes,
                actionItems: items
            )
        } catch {
            errorMessage = "Failed to open HTML preview: \(error.localizedDescription)"
        }
    }

    // MARK: - Draft Email (P3-T03)

    private func draftFollowUpEmail() {
        guard let meeting, !isDraftingEmail else { return }
        isDraftingEmail = true
        Task {
            defer { Task { @MainActor in isDraftingEmail = false } }

            // Locate the built-in follow-up email recipe (seeded in Migrations.swift).
            let recipeRepo = RecipeRepository(database: appState.database)
            let allRecipes = (try? await recipeRepo.allRecipes()) ?? []
            guard let recipe = allRecipes.first(where: { $0.id == "builtin-follow-up-email" })
                ?? allRecipes.first(where: { $0.category == .email && $0.isBuiltIn }) else {
                await MainActor.run {
                    errorMessage = "Follow-up Email recipe not found. Reinstall the app or check your database migrations."
                }
                return
            }

            // Route through the central factory so the active provider
            // (Local / Claude / Gemini) and cloud-PII redaction are applied
            // consistently.
            guard let textGenerator = await appState.makeTextGenerator() else {
                await MainActor.run {
                    errorMessage = "No AI configured. Choose a provider in Settings → AI."
                }
                return
            }

            do {
                let appState = self.appState
                let result = try await emailRecipeEngine.execute(
                    recipe: recipe,
                    meeting: meeting,
                    transcriptRepo: appState.transcriptRepository,
                    noteRepo: appState.noteRepository,
                    resultRepo: RecipeResultRepository(database: appState.database),
                    receiptsProvider: {
                        await ReceiptsBuilder.build(for: meeting, allMeetings: appState.meetings, database: appState.database)
                    },
                    textGenerator: textGenerator
                )
                await MainActor.run { emailDraftText = result }
            } catch {
                await MainActor.run {
                    errorMessage = "Failed to draft email: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Inline auto-save (P1-T04)

    private var isEdited: Bool {
        hasLoadedEditor && editableContent != originalContent
    }

    private func loadEditorIfNeeded(from summary: MeetingSummary) {
        guard !hasLoadedEditor else { return }
        editableContent = summary.summaryText
        originalContent = summary.summaryText
        hasLoadedEditor = true
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await persistSummary()
        }
    }

    /// Synchronously kicks off a save if there's an unsaved divergence.
    /// Used on view disappearance — fire-and-forget; cannot block onDisappear,
    /// but the Task is detached and will run to completion.
    private func flushPendingSaveIfNeeded() {
        guard hasLoadedEditor,
              let s = summary,
              editableContent != s.summaryText else { return }
        Task.detached { [editableContent] in
            await persistImmediately(text: editableContent)
        }
    }

    @MainActor
    private func persistSummary() async {
        guard hasLoadedEditor, var updated = summary else { return }
        // No-op if user reverted to the persisted text.
        guard editableContent != updated.summaryText else { return }
        // First edit captures the AI original (TASK-070 style examples).
        if updated.originalText == nil, !updated.isEdited {
            updated.originalText = updated.summaryText
        }
        updated.summaryText = editableContent
        updated.isEdited = (editableContent != originalContent)
        do {
            try await appState.summaryRepository.update(updated)
            summary = updated
            withAnimation(.easeInOut(duration: 0.2)) { showSavedFlash = true }
            try? await Task.sleep(for: .milliseconds(800))
            withAnimation(.easeInOut(duration: 0.3)) { showSavedFlash = false }
        } catch {
            errorMessage = "Failed to save edited summary: \(error.localizedDescription)"
        }
    }

    private func persistImmediately(text: String) async {
        // Used by flushPendingSaveIfNeeded — re-fetch latest persisted summary
        // off the main actor and write the diverged text back.
        guard let latest = try? await appState.summaryRepository.latestSummary(meetingId: meetingId) else { return }
        guard text != latest.summaryText else { return }
        var updated = latest
        if updated.originalText == nil, !updated.isEdited {
            updated.originalText = updated.summaryText
        }
        updated.summaryText = text
        updated.isEdited = true
        do {
            try await appState.summaryRepository.update(updated)
        } catch {
            Logger.general.error("Summary auto-save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Actions

    private func loadEmptyStateMeta() async {
        let segments = (try? await appState.transcriptRepository.transcriptsForMeeting(meetingId)) ?? []
        transcriptCount = segments.count
        let repo = RecipeRepository(database: appState.database)
        recipes = (try? await repo.allRecipes()) ?? []
    }

    private func loadSummary() async {
        isLoading = true
        defer { isLoading = false }
        summary = try? await appState.summaryRepository.latestSummary(meetingId: meetingId)
    }

    private func regenerateSummary(recipe: Recipe? = nil) {
        // Enqueue through the persistent task queue instead of running inline.
        // This ensures regeneration survives navigation, appears in the Tasks sidebar,
        // and can be cancelled from the task list. isRegenerating and regenerateError
        // are computed from the queue — no local state to manage here.
        Task {
            // Build metadata JSON with optional recipeId
            var metadataDict: [String: String] = [:]
            if let recipe { metadataDict["recipeId"] = recipe.id }
            let metadata: String? = metadataDict.isEmpty ? nil : {
                let data = try? JSONSerialization.data(withJSONObject: metadataDict)
                return data.flatMap { String(data: $0, encoding: .utf8) }
            }()

            await appState.taskQueueManager.enqueue(
                type: .regeneration,
                meetingId: meetingId,
                priority: 3, // Higher priority than summary (5) — user explicitly requested
                metadata: metadata
            )
        }
    }

    private func copyAsMarkdown(_ summary: MeetingSummary) {
        guard let meeting else { return }
        let markdown = exportService.exportSummaryMarkdown(meeting: meeting, summary: summary)
        ShareService.copyToClipboard(markdown)

        withAnimation {
            copiedMarkdownToClipboard = true
        }

        Task {
            try? await Task.sleep(for: .seconds(2))
            await MainActor.run {
                withAnimation {
                    copiedMarkdownToClipboard = false
                }
            }
        }
    }

}

// MARK: - TL;DR Card

private struct TLDRCard: View {
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.appAccentLight)
                Text("TL;DR")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(Color.appAccentLight)
                    .textCase(.uppercase)
                    .tracking(0.6)
            }
            .padding(.bottom, 8)

            ForEach(Array(lines.enumerated()), id: \.offset) { idx, line in
                Text(Self.inlineMarkdown(line))
                    .font(.system(size: 13.5))
                    .foregroundStyle(Color.appTextPrimary)
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, idx < lines.count - 1 ? 6 : 0)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            LinearGradient(
                colors: [Color.appAccentSubtle, Color.clear],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.appAccentSubtleStrong, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// Parse inline Markdown (bold, italic, code, link) so `**bold**` and
    /// similar render visually instead of showing literal asterisks.
    fileprivate static func inlineMarkdown(_ s: String) -> AttributedString {
        if let parsed = try? AttributedString(
            markdown: s,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        ) {
            return parsed
        }
        return AttributedString(s)
    }
}

// MARK: - Skim-First Section Grid

struct SkimFirstSectionGrid: View {
    let sections: [SummaryParser.Section]

    var body: some View {
        let left = sections.indices.filter { $0 % 2 == 0 }.map { sections[$0] }
        let right = sections.indices.filter { $0 % 2 == 1 }.map { sections[$0] }

        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 24) {
                ForEach(left) { SectionCard(section: $0) }
            }
            VStack(alignment: .leading, spacing: 24) {
                ForEach(right) { SectionCard(section: $0) }
            }
        }
    }
}

struct SectionCard: View {
    let section: SummaryParser.Section

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SkimSectionLabel(kind: section.kind, title: section.title, count: section.items.count)
                .padding(.bottom, 12)

            ForEach(Array(section.items.enumerated()), id: \.offset) { idx, item in
                Group {
                    if let entity = item.entity {
                        Text(entity).fontWeight(.semibold).foregroundStyle(Color.appTextPrimary)
                        + Text(" \u{2014} ").foregroundStyle(Color.appTextTertiary)
                        + Text(item.body).foregroundStyle(Color.appTextTertiary)
                    } else {
                        Text(item.body).foregroundStyle(Color.appTextTertiary)
                    }
                }
                .font(.system(size: 12.5))
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
                .overlay(alignment: .bottom) {
                    if idx < section.items.count - 1 {
                        Rectangle()
                            .fill(Color.appSeparator)
                            .frame(height: 1)
                    }
                }
            }
        }
    }
}

// MARK: - Section Label

enum SectionKind { case decisions, followups, notes, outcomes }

struct SkimSectionLabel: View {
    let kind: SectionKind
    var title: String
    var count: Int? = nil

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.appTextTertiary)
                .tracking(0.6)
            if let count {
                Text("\(count)")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.appTextMuted)
                    .monospacedDigit()
            }
        }
    }

    private var dotColor: Color {
        switch kind {
        case .decisions: return Color.appAccentMid
        case .followups: return Color.appWarning
        case .notes:     return Color.appTextMuted
        case .outcomes:  return Color.appViolet
        }
    }
}

// MARK: - Previous Sessions Strip

private struct PreviousSessionsStrip: View {
    let sessions: [Meeting]
    let onSelect: (String) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 14))
                .foregroundStyle(Color.appTextMuted)
            Text("Previous sessions")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.appTextTertiary)
                .textCase(.uppercase)
                .tracking(0.4)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(sessions.prefix(5)) { prev in
                        Button {
                            onSelect(prev.id)
                        } label: {
                            HStack(spacing: 4) {
                                Text(
                                    prev.scheduledStartDate ?? prev.startDate ?? prev.createdAt,
                                    format: .dateTime.month(.abbreviated).day()
                                )
                                Text("·")
                                Text(prev.title)
                                Text("→")
                            }
                            .font(.system(size: 12.5))
                            .foregroundStyle(Color.appAccentLight)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.appSurface)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.appSeparator, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Summary Parser

enum SummaryParser {
    struct Item {
        var entity: String?
        var body: String
    }

    struct Section: Identifiable {
        let id = UUID()
        var kind: SectionKind
        var title: String
        var items: [Item]
    }

    struct ParsedSummary {
        var tldr: [String]
        var sections: [Section]
    }

    static func parse(_ text: String) -> ParsedSummary {
        let lines = text.components(separatedBy: "\n")
        var tldr: [String] = []
        var sections: [Section] = []
        var currentSection: Section? = nil
        var preSectionLines: [String] = []
        var seenFirstHeading = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            // Accept any ATX heading level (1–6 hashes followed by a space).
            // Older default prompts used `### Section`; the v3.3.8 prompt uses
            // `## Section`. Both should land in the structured grid.
            //
            // Also accept `**Section Title:**` (bold-with-optional-colon) on a
            // line by itself — this is what user-customised prompts produce
            // ("Key Discussion Points:", "Decisions Made:", etc.). Without
            // this branch those summaries silently fell through to flat
            // markdown and the user lost the 2-column grid layout.
            if trimmed.range(of: #"^#{1,6}\s+"#, options: .regularExpression) != nil {
                if let sec = currentSection { sections.append(sec) }
                seenFirstHeading = true
                let raw = trimmed.replacingOccurrences(of: "^#+\\s*", with: "", options: .regularExpression)
                currentSection = Section(kind: sectionKind(for: raw), title: raw, items: [])
            } else if let boldHeading = Self.boldHeadingTitle(in: trimmed) {
                if let sec = currentSection { sections.append(sec) }
                seenFirstHeading = true
                currentSection = Section(kind: sectionKind(for: boldHeading), title: boldHeading, items: [])
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                let body = String(trimmed.dropFirst(2))
                let item = parseItem(body)
                if currentSection != nil {
                    currentSection!.items.append(item)
                }
            } else if let m = trimmed.range(of: #"^\d+\.\s+"#, options: .regularExpression) {
                // Numbered items (`1. text`, `2. text`) — common when the AI is
                // prompted with a numbered list rather than dash bullets.
                let body = String(trimmed[m.upperBound...])
                let item = parseItem(body)
                if currentSection != nil {
                    currentSection!.items.append(item)
                }
            } else if seenFirstHeading, currentSection != nil {
                // Prose paragraph inside a section — capture as a free-form item
                // so the structured grid renders it instead of silently dropping it.
                let item = parseItem(trimmed)
                currentSection!.items.append(item)
            } else if !seenFirstHeading {
                preSectionLines.append(trimmed)
            }
        }
        if let sec = currentSection { sections.append(sec) }

        tldr = Array(preSectionLines.prefix(2))

        if tldr.isEmpty && !sections.isEmpty {
            let counts = sections.map { "\($0.items.count) \($0.title.lowercased())" }.joined(separator: " · ")
            tldr = [counts]
        }

        return ParsedSummary(tldr: tldr, sections: sections)
    }

    /// Detect a "bold-style" heading line — `**Title**` or `**Title:**` —
    /// returning the cleaned title or nil if the line isn't a bold heading.
    /// Allows the structured 2-column grid to render summaries that use
    /// bold-text section headers instead of `## ` ATX headings (very common
    /// in user-customised prompts and older defaults).
    private static func boldHeadingTitle(in line: String) -> String? {
        // Must start AND end with ** so we don't catch lines that have
        // bold *inside* prose (e.g. "**Decision:** we will..." — that's
        // a list item, not a heading).
        guard line.hasPrefix("**"), line.hasSuffix("**") else { return nil }
        let inner = String(line.dropFirst(2).dropLast(2))
        // Reject lines with internal `**` — those are inline bold, not headings.
        guard !inner.contains("**") else { return nil }
        // Strip a trailing colon if present.
        let cleaned = inner.hasSuffix(":") ? String(inner.dropLast()) : inner
        let trimmed = cleaned.trimmingCharacters(in: .whitespaces)
        // Heuristic length cap — real headings are short. Past 80 chars
        // it's almost certainly a bolded sentence in prose.
        guard !trimmed.isEmpty, trimmed.count <= 80 else { return nil }
        return trimmed
    }

    private static func parseItem(_ text: String) -> Item {
        // "**Entity** — body"
        if text.hasPrefix("**") {
            let parts = text.components(separatedBy: "**")
            if parts.count >= 3 {
                let entity = parts[1]
                let tail = parts[2...].joined()
                    .trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "^\\s*[—\\-–:]+\\s*", with: "", options: .regularExpression)
                if !entity.isEmpty && !tail.isEmpty {
                    return Item(entity: entity, body: tail)
                }
            }
        }
        return Item(entity: nil, body: text)
    }

    private static func sectionKind(for title: String) -> SectionKind {
        let lower = title.lowercased()
        if lower.contains("decision") { return .decisions }
        if lower.contains("follow") || lower.contains("action") { return .followups }
        if lower.contains("outcome") || lower.contains("result") { return .outcomes }
        return .notes
    }
}

// MARK: - Preview

// #Preview("With Summary") {
//     SummaryView(meetingId: "preview-1")
//         .environment(AppState())
//         .frame(width: 600, height: 500)
//         .background(Color.appBackground)
// }

// #Preview("Empty") {
//     SummaryView(meetingId: "no-summary")
//         .environment(AppState())
//         .frame(width: 600, height: 500)
//         .background(Color.appBackground)
// }

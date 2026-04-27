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
    @State private var recipes: [Recipe] = []
    @State private var selectedRecipe: Recipe? = nil

    private let exportService = ExportService()

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
        .onChange(of: appState.taskQueueManager.allTasks) { _, tasks in
            // Reload summary when a regeneration task for this meeting completes.
            let justCompleted = tasks.contains {
                $0.type == .regeneration &&
                $0.meetingId == meetingId &&
                $0.status == .completed
            }
            if justCompleted {
                Task { await loadSummary() }
            }
        }
        .task {
            meeting = try? await appState.meetingRepository.find(id: meetingId)
            async let summaryLoad: () = loadSummary()
            async let metaLoad: () = loadEmptyStateMeta()
            await summaryLoad
            await metaLoad
        }
        .sheet(isPresented: $showHistory) {
            SummaryHistoryView(meetingId: meetingId)
                .environment(appState)
        }
    }

    // MARK: - No Summary Empty State

    @ViewBuilder
    private var noSummaryEmptyState: some View {
        VStack(spacing: 0) {
            Spacer()
            if transcriptCount == 0 {
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

    @ViewBuilder
    private func summaryContent(_ summary: MeetingSummary) -> some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 12) {
                if let model = summary.modelUsed {
                    Label(model, systemImage: "cpu")
                        .font(.caption)
                        .foregroundStyle(Color.appTextTertiary)
                }

                Text("Generated \(DateFormatting.fullDateTime(from: summary.generatedAt))")
                    .font(.caption)
                    .foregroundStyle(Color.appTextTertiary)

                // "Edited" badge — driven by live edit state, so it appears as
                // soon as the user diverges from the AI text.
                if isEdited {
                    Text("Edited")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.appWarning)
                        .clipShape(Capsule())
                }

                // Subtle "Saved" flash after each debounced auto-save.
                if showSavedFlash {
                    Label("Saved", systemImage: "checkmark")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                        .foregroundStyle(Color.appSuccess)
                        .transition(.opacity)
                }

                // Smaller inline regen indicator (NOT a full-screen replacement).
                if isRegenerating {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Regenerating…")
                            .font(.caption)
                            .foregroundStyle(Color.appTextSecondary)
                    }
                }

                Spacer()

                standardToolbar(summary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()
                .foregroundStyle(Color.appSeparator)

            if let error = regenerateError {
                regenerateErrorBanner(error)
            }

            // Always-mounted inline editor + inline action items (P1-T04 + P1-T02).
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    TextEditor(text: $editableContent)
                        .font(.body)
                        .foregroundStyle(Color.appTextPrimary)
                        .scrollContentBackground(.hidden)
                        .lineSpacing(4)
                        .frame(minHeight: 240)
                        .background(Color.appBackground)

                    Divider()
                        .padding(.vertical, 16)

                    InlineActionItemsSection(meetingId: meetingId)

                    Divider()
                        .padding(.vertical, 16)

                    // "View raw transcript" link (P1-T01) — secondary, de-emphasized.
                    // Posts the existing .switchTab notification rather than threading
                    // a binding through; MeetingDetailView already listens for this.
                    Button {
                        NotificationCenter.default.post(name: .switchTab, object: "transcript")
                    } label: {
                        Label("View raw transcript", systemImage: "text.quote")
                            .font(.caption)
                            .foregroundStyle(Color.appTextSecondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 8)
                }
                .padding(16)
            }
        }
        .onAppear { loadEditorIfNeeded(from: summary) }
        .onChange(of: summary.id) { _, _ in
            // A different summary version landed (regen complete) — reload editor.
            hasLoadedEditor = false
            loadEditorIfNeeded(from: summary)
        }
        .onChange(of: editableContent) { _, _ in
            // Skip the initial load assignment.
            guard hasLoadedEditor else { return }
            scheduleSave()
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
        Button {
            copyToClipboard(editableContent)
        } label: {
            Label(
                copiedToClipboard ? "Copied" : "Copy",
                systemImage: copiedToClipboard ? "checkmark" : "doc.on.doc"
            )
            .font(.caption)
            .fontWeight(.medium)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)

        Button {
            copyAsMarkdown(summary)
        } label: {
            Label(
                copiedMarkdownToClipboard ? "Copied" : "Copy as Markdown",
                systemImage: copiedMarkdownToClipboard ? "checkmark" : "text.document"
            )
            .font(.caption)
            .fontWeight(.medium)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)

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

        ShareSummaryButton(summary: summary, meeting: meeting, exportService: exportService)
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

    private func copyToClipboard(_ text: String) {
        ShareService.copyToClipboard(text)

        withAnimation {
            copiedToClipboard = true
        }

        Task {
            try? await Task.sleep(for: .seconds(2))
            await MainActor.run {
                withAnimation {
                    copiedToClipboard = false
                }
            }
        }
    }
}

// MARK: - Share Button

/// Hosts an `NSSharingServicePicker` anchored to the button's own NSView,
/// so the share sheet appears in the correct position.
#if canImport(AppKit)
private struct ShareSummaryButton: View {
    let summary: MeetingSummary
    let meeting: Meeting?
    let exportService: ExportService

    var body: some View {
        ShareSummaryButtonRepresentable(summary: summary, meeting: meeting, exportService: exportService)
            .fixedSize()
    }
}

private struct ShareSummaryButtonRepresentable: NSViewRepresentable {
    let summary: MeetingSummary
    let meeting: Meeting?
    let exportService: ExportService

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(
            title: "Share",
            target: context.coordinator,
            action: #selector(Coordinator.share(_:))
        )
        button.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Share")
        button.imagePosition = .imageLeading
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.isBordered = true
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        context.coordinator.summary = summary
        context.coordinator.meeting = meeting
        context.coordinator.exportService = exportService
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(summary: summary, meeting: meeting, exportService: exportService)
    }

    @MainActor
    final class Coordinator: NSObject {
        var summary: MeetingSummary
        var meeting: Meeting?
        var exportService: ExportService

        init(summary: MeetingSummary, meeting: Meeting?, exportService: ExportService) {
            self.summary = summary
            self.meeting = meeting
            self.exportService = exportService
        }

        @objc func share(_ sender: NSButton) {
            let formattedText: String
            if let meeting {
                formattedText = exportService.exportSummaryMarkdown(meeting: meeting, summary: summary)
            } else {
                formattedText = summary.summaryText
            }
            let picker = NSSharingServicePicker(items: [formattedText])
            picker.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }
}
#endif

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

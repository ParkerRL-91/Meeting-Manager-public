import SwiftUI

/// Renders the per-meeting "Enhanced Notes" artifact — the user's raw notes
/// rewritten into a polished version that keeps their own structure. Read-only
/// view; generation is enqueued via the task queue (the `.enhanceNotes` type).
///
/// States mirror `DetailedOutlineView`:
///   - **No notes:** nothing to enhance — point the user at the Raw tab.
///   - **Notes exist, not yet enhanced:** an "Enhance Notes" CTA.
///   - **Populated:** render the Markdown with a Re-enhance button and a footer
///     showing model + timestamp.
///   - **Populated but stale:** the source notes changed since the enhancement
///     was produced — show a banner offering "Re-enhance".
struct EnhancedNotesView: View {
    let meetingId: String

    @Environment(AppState.self) private var appState
    @State private var enhanced: EnhancedNote?
    @State private var currentNotes: String = ""
    @State private var isLoading = true

    /// True while an `.enhanceNotes` task for this meeting is pending or
    /// running. Drives the inline "Enhancing…" indicator + disables the button.
    private var isGenerating: Bool {
        appState.taskQueueManager.allTasks.contains {
            $0.type == .enhanceNotes &&
            $0.meetingId == meetingId &&
            ($0.status == .pending || $0.status == .running)
        }
    }

    /// The most recent failed `.enhanceNotes` task error, if the last attempt
    /// failed (e.g. "No AI backend available").
    private var generateError: String? {
        appState.taskQueueManager.allTasks
            .filter { $0.type == .enhanceNotes && $0.meetingId == meetingId && $0.status == .failed }
            .sorted { $0.createdAt > $1.createdAt }
            .first?.error
    }

    private var hasNotes: Bool {
        !currentNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// True when an enhancement exists but the source notes have since changed.
    private var isStale: Bool {
        guard let enhanced, hasNotes else { return false }
        return enhanced.sourceNotesHash != EnhancedNote.stableHash(currentNotes)
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let enhanced, !enhanced.content.isEmpty {
                populatedBody(enhanced)
            } else if !hasNotes {
                noNotesState
            } else {
                notEnhancedState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: meetingId) {
            await load()
        }
        .refreshOnTaskCompletion(
            meetingId: meetingId,
            types: [.enhanceNotes],
            tasks: appState.taskQueueManager.allTasks
        ) {
            Task { await load() }
        }
    }

    // MARK: - States

    @ViewBuilder
    private func populatedBody(_ enhanced: EnhancedNote) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Spacer()
                Button {
                    copyMarkdown(enhanced.content)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }

                Button {
                    enhance()
                } label: {
                    if isGenerating {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Enhancing…")
                        }
                    } else {
                        Label("Re-enhance", systemImage: "sparkles")
                    }
                }
                .disabled(isGenerating || !hasNotes)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)

            if isStale {
                staleBanner
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    MarkdownRenderer(text: enhanced.content, baseFontSize: 14)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text(footerLine(enhanced))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 16)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
        }
    }

    private var staleBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.appWarning)
            Text("Your notes have changed since this was enhanced.")
                .font(.caption)
                .foregroundStyle(Color.appTextSecondary)
            Spacer()
            if !isGenerating {
                Button("Re-enhance") { enhance() }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.appAccent)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(Color.appWarning.opacity(0.12))
    }

    private var noNotesState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "note.text")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)
            Text("No Notes to Enhance")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("Enhance Notes polishes the notes you captured into a cleaner\nversion in your own structure. Write some notes in the Raw tab,\nthen enhance them here.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
            Spacer()
        }
        .padding(.horizontal, 40)
    }

    private var notEnhancedState: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "sparkles")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            VStack(spacing: 6) {
                Text("Notes Not Yet Enhanced")
                    .font(.title3.weight(.semibold))
                Text("Rewrite your raw notes into a polished version that keeps your own headings and structure, with terse points expanded into full sentences.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if let generateError {
                Text(generateError)
                    .font(.caption)
                    .foregroundStyle(Color.appRecording)
                    .multilineTextAlignment(.center)
            }
            if isGenerating {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Enhancing notes…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                Button {
                    enhance()
                } label: {
                    Label("Enhance Notes", systemImage: "sparkles")
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.appAccent)
                .controlSize(.large)
            }
            Spacer()
        }
        .padding(.horizontal, 40)
    }

    // MARK: - Actions

    private func enhance() {
        Task {
            _ = await appState.taskQueueManager.enqueue(
                type: .enhanceNotes,
                meetingId: meetingId,
                priority: 4
            )
        }
    }

    private func copyMarkdown(_ text: String) {
        #if canImport(AppKit)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        #endif
    }

    private func footerLine(_ enhanced: EnhancedNote) -> String {
        let when = enhanced.generatedAt.formatted(date: .abbreviated, time: .shortened)
        if let model = enhanced.modelUsed, !model.isEmpty {
            return "\(model) · \(when)"
        }
        return when
    }

    // MARK: - Data

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        enhanced = try? await appState.enhancedNoteRepository.enhancedNote(meetingId: meetingId)
        currentNotes = (try? await appState.noteRepository.combinedNotes(meetingId: meetingId)) ?? ""
    }
}

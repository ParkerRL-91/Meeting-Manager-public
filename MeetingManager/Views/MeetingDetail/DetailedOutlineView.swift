import SwiftUI

/// Renders the per-meeting detailed outline (time-stamped topic sections
/// with speaker attribution + prose + optional fact bullets). Read-only
/// view; regeneration is enqueued via the task queue.
///
/// Three states:
///   - **Empty (no transcript yet):** mirror `SummaryView`'s "No
///     Transcript Available" empty state.
///   - **Empty (transcript exists, outline not yet generated):** show a
///     "Generate Outline" CTA that enqueues a `detailedOutline` task.
///   - **Populated:** render the Markdown blob with a Regenerate button
///     and a small footer line showing model + generation timestamp.
struct DetailedOutlineView: View {
    let meetingId: String

    @Environment(AppState.self) private var appState
    @State private var outline: DetailedOutline?
    @State private var transcriptCount: Int = 0
    @State private var isLoading = true

    /// True while a `detailedOutline` task for this meeting is pending or
    /// running. Drives the inline "Generating..." indicator + disables the
    /// Regenerate button.
    private var isGenerating: Bool {
        appState.taskQueueManager.allTasks.contains {
            $0.type == .detailedOutline &&
            $0.meetingId == meetingId &&
            ($0.status == .pending || $0.status == .running)
        }
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let outline, !outline.text.isEmpty {
                populatedBody(outline)
            } else if transcriptCount == 0 {
                noTranscriptState
            } else {
                noOutlineState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: meetingId) {
            await load()
        }
        .onChange(of: appState.taskQueueManager.allTasks) { _, _ in
            // When a detailedOutline task transitions out of running we
            // reload to pick up the new blob. Cheap — the load is two
            // small reads.
            Task { await load() }
        }
    }

    // MARK: - States

    @ViewBuilder
    private func populatedBody(_ outline: DetailedOutline) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Top action bar — mirrors SummaryView's pattern
            HStack(spacing: 8) {
                Spacer()
                Button {
                    copyMarkdown(outline.text)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }

                Button {
                    regenerate()
                } label: {
                    if isGenerating {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Generating…")
                        }
                    } else {
                        Label("Regenerate", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(isGenerating)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    MarkdownRenderer(text: outline.text, baseFontSize: 14)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text(footerLine(outline))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 16)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
        }
    }

    private var noTranscriptState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)
            Text("No Transcript Available")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("A detailed outline can only be generated from a transcript.\nRecord this meeting to capture audio, then Meeting Manager\nwill produce the outline automatically after the summary.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
            Spacer()
        }
        .padding(.horizontal, 40)
    }

    private var noOutlineState: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            VStack(spacing: 6) {
                Text("Outline Not Yet Generated")
                    .font(.title3.weight(.semibold))
                Text("A detailed time-stamped outline of the meeting's topics, with speaker attribution and discussion arcs.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if isGenerating {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Generating outline…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                Button {
                    regenerate()
                } label: {
                    Label("Generate Outline", systemImage: "sparkles")
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

    private func regenerate() {
        Task {
            _ = await appState.taskQueueManager.enqueue(
                type: .detailedOutline,
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

    private func footerLine(_ outline: DetailedOutline) -> String {
        let when = outline.generatedAt.formatted(date: .abbreviated, time: .shortened)
        if let model = outline.modelUsed, !model.isEmpty {
            return "\(model) · \(when)"
        }
        return when
    }

    // MARK: - Data

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        let repo = DetailedOutlineRepository()
        outline = (try? await repo.outline(meetingId: meetingId))
        let txRepo = TranscriptRepository(database: AppDatabase.shared)
        let segments = (try? await txRepo.transcriptsForMeeting(meetingId, limit: 1)) ?? []
        transcriptCount = segments.count
    }
}

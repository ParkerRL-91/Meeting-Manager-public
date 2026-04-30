import SwiftUI
import AppKit

/// Settings tab for the Knowledge Base feature — lets the user point at a
/// folder, see how many files have been indexed, kick off a manual re-index,
/// or clear the configured folder. Also surfaces the rules about which file
/// types are read and which are ignored, so there's no surprise about PDFs
/// and images being skipped.
struct KnowledgeBaseSettingsView: View {

    @State private var rootURL: URL?
    @State private var fileCount: Int = 0
    @State private var chunkCount: Int = 0
    @State private var lastIndexed: Date?
    @State private var isIndexing: Bool = false
    @State private var refreshTimer: Timer?

    private let repo = KBDocumentRepository()

    var body: some View {
        Form {
            Section {
                Text("The Knowledge Base is a folder of your own documents — meeting notes, project docs, OKRs, anything written down — that Meeting Manager reads (read-only) and uses as background context when it writes meeting briefs, summaries, and chat answers. Think of it as “stuff the AI should know about you and your work” without having to paste it in every time.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Folder") {
                if let url = rootURL {
                    LabeledContent("Indexed folder") {
                        Text(url.path)
                            .font(.callout)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    LabeledContent("Files indexed") {
                        Text("\(fileCount) file\(fileCount == 1 ? "" : "s") · \(chunkCount) chunk\(chunkCount == 1 ? "" : "s")")
                            .foregroundStyle(.secondary)
                    }
                    if let date = lastIndexed {
                        LabeledContent("Last indexed") {
                            Text(date, format: .relative(presentation: .named))
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Button {
                            chooseFolder()
                        } label: {
                            Label("Change folder…", systemImage: "folder")
                        }

                        Button {
                            reindexNow()
                        } label: {
                            if isIndexing {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text("Indexing…")
                                }
                            } else {
                                Label("Re-index", systemImage: "arrow.clockwise.circle")
                            }
                        }
                        .disabled(isIndexing)

                        Spacer()

                        Button(role: .destructive) {
                            clearKB()
                        } label: {
                            Label("Clear", systemImage: "trash")
                                .foregroundStyle(.red)
                        }
                    }
                } else {
                    Text("No folder selected. Pick one to start using your own docs as context.")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    Button {
                        chooseFolder()
                    } label: {
                        Label("Select Knowledge Base folder…", systemImage: "folder.badge.plus")
                    }
                }
            }

            Section("What gets indexed") {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Markdown (.md, .markdown)", systemImage: "doc.text")
                    Label("Plain text (.txt, .text)", systemImage: "doc.plaintext")
                    Label("HTML (.html, .htm)", systemImage: "doc.richtext")
                    Label("Word documents (.docx)", systemImage: "doc.append")
                }
                .font(.callout)
                .foregroundStyle(.primary)

                Text("Every subfolder is walked recursively. Hidden files (anything starting with `.`) and files inside hidden folders are skipped.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Ignored") {
                VStack(alignment: .leading, spacing: 6) {
                    Label("PDFs", systemImage: "doc.fill")
                        .foregroundStyle(.secondary)
                    Label("Images (.png, .jpg, .heic, …)", systemImage: "photo")
                        .foregroundStyle(.secondary)
                    Label("Spreadsheets, presentations, archives, binaries", systemImage: "doc.zipper")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)

                Text("PDFs and images are intentionally not indexed — text extraction from them is unreliable and would clutter retrieval with junk. If you want a PDF indexed, save it as a `.txt` or `.md` first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("How it's used") {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Pre-meeting briefs pull in excerpts that match the meeting's title, participants, and prior discussion threads.", systemImage: "sparkles")
                    Label("In-meeting chat retrieves excerpts that match each question you ask.", systemImage: "bubble.left.and.bubble.right")
                    Label("Generated summaries can cite Knowledge Base sources alongside the transcript.", systemImage: "text.quote")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Text("With a local model (Ollama), retrieved excerpts stay on your Mac — Ollama runs on-device. With Claude, the excerpts that match a given meeting are sent to Claude alongside the transcript and notes (the same data Claude already sees for summaries) — never the full folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .task { await refresh() }
        .onAppear { startTimer() }
        .onDisappear { stopTimer() }
    }

    // MARK: - Actions

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select a folder to use as your Knowledge Base. Subfolders are included."
        panel.prompt = "Select"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            await KnowledgeBaseService.shared.setRoot(url: url)
            await refresh()
        }
    }

    private func reindexNow() {
        Task {
            await KnowledgeBaseService.shared.reindex()
            await refresh()
        }
    }

    private func clearKB() {
        Task {
            await KnowledgeBaseService.shared.clearRoot()
            await refresh()
        }
    }

    private func refresh() async {
        rootURL = KnowledgeBaseService.shared.rootURL
        fileCount = (try? await repo.documentCount()) ?? 0
        chunkCount = (try? await repo.chunkCount()) ?? 0
        lastIndexed = (try? await repo.lastIndexedAt()) ?? KnowledgeBaseService.shared.lastIndexedAt
        isIndexing = KnowledgeBaseService.shared.isIndexing
    }

    private func startTimer() {
        // Refresh while a re-index runs so file count + last-indexed stay live.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            Task { @MainActor in await refresh() }
        }
    }

    private func stopTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
}

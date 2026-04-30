import SwiftUI
import AppKit

/// Onboarding step that introduces the Knowledge Base in plain language —
/// no jargon ("RAG", "embeddings", "context window"), concrete examples of
/// what to put in, what's actually read, and what's ignored. Skippable.
struct KnowledgeBaseStepView: View {
    let onSkip: () -> Void

    @State private var selectedURL: URL? = KnowledgeBaseService.shared.rootURL
    @State private var isIndexing: Bool = false
    @State private var fileCount: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header

                    plainLanguageExplanation

                    whatItIsGoodFor

                    indexedAndIgnoredLists

                    privacyNote

                    folderPicker
                }
                .padding(.horizontal, 32)
                .padding(.top, 32)
                .padding(.bottom, 24)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "books.vertical.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(Color.appAccent)
                Text("Set up your Knowledge Base")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(Color.appTextPrimary)
            }
            Text("Optional · Skip and add later in Settings if you'd rather")
                .font(.callout)
                .foregroundStyle(Color.appTextSecondary)
        }
    }

    private var plainLanguageExplanation: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What is this?")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.appTextPrimary)

            Text("A Knowledge Base is a folder on your Mac full of text documents you'd like Meeting Manager to read in the background — things like meeting notes, project docs, OKRs, runbooks, technical specs, your team's wiki exports.")
                .font(.body)
                .foregroundStyle(Color.appTextPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Text("When you open a meeting, Meeting Manager peeks at this folder and pulls in the few snippets that look relevant to that meeting's topic, then hands them to the AI alongside the transcript and notes. The result: briefs, summaries, and chat answers that already know about your projects, terminology, and decisions — without you having to copy-paste anything.")
                .font(.body)
                .foregroundStyle(Color.appTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
    }

    private var whatItIsGoodFor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Things people put in their KB")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.appTextPrimary)

            VStack(alignment: .leading, spacing: 8) {
                bullet("A folder of meeting notes exported from Notion, Apple Notes, or Obsidian")
                bullet("Project briefs, PRDs, design docs")
                bullet("Quarterly OKRs, roadmaps, planning docs")
                bullet("Runbooks and onboarding docs for your team")
                bullet("Personal notes about contacts, vendors, recurring topics")
            }
        }
    }

    private var indexedAndIgnoredLists: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Read")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.appAccent)
                fileLabel(icon: "doc.text", name: "Markdown (.md)")
                fileLabel(icon: "doc.plaintext", name: "Plain text (.txt)")
                fileLabel(icon: "doc.richtext", name: "HTML (.html)")
                fileLabel(icon: "doc.append", name: "Word docs (.docx)")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 8) {
                Text("Ignored")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.appTextTertiary)
                fileLabel(icon: "doc.fill", name: "PDFs", muted: true)
                fileLabel(icon: "photo", name: "Images", muted: true)
                fileLabel(icon: "doc.zipper", name: "Spreadsheets, archives", muted: true)
                fileLabel(icon: "eye.slash", name: "Hidden files (.git, .DS_Store)", muted: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(Color.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var privacyNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield")
                .foregroundStyle(Color.appAccent)
                .font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text("Your files stay on your machine.")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Color.appTextPrimary)
                Text("Meeting Manager reads the folder locally and stores a search index in its own database. When you use a local model (Ollama), nothing leaves your Mac — the snippets, the prompt, and the response all stay on-device. When you use Claude, the snippets that match a given meeting are sent to Claude alongside the transcript and notes (the same data Claude already sees for summaries) — never the full folder.")
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(Color.appAccent.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var folderPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pick your folder")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.appTextPrimary)

            if let url = selectedURL {
                HStack(spacing: 10) {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(Color.appAccent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(url.path)
                            .font(.callout)
                            .foregroundStyle(Color.appTextPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if isIndexing {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Indexing…")
                                    .font(.caption)
                                    .foregroundStyle(Color.appTextSecondary)
                            }
                        } else if fileCount > 0 {
                            Text("\(fileCount) file\(fileCount == 1 ? "" : "s") indexed")
                                .font(.caption)
                                .foregroundStyle(Color.appTextSecondary)
                        }
                    }
                    Spacer()
                    Button("Change…") { chooseFolder() }
                }
                .padding(12)
                .background(Color.appSurface)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Button {
                    chooseFolder()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "folder.badge.plus")
                        Text("Select a folder…")
                            .fontWeight(.medium)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Color.appAccent)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            HStack {
                Button("Skip for now") { onSkip() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.appTextSecondary)
                Spacer()
                if selectedURL != nil {
                    Button("Continue") { onSkip() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .tint(Color.appAccent)
                }
            }
            .padding(.top, 8)
        }
    }

    // MARK: - Actions

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select a folder of documents to use as your Knowledge Base. Subfolders are included."
        panel.prompt = "Select"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        selectedURL = url
        isIndexing = true
        Task {
            await KnowledgeBaseService.shared.setRoot(url: url)
            fileCount = (try? await KBDocumentRepository().documentCount()) ?? 0
            isIndexing = false
        }
    }

    // MARK: - Helpers

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•").foregroundStyle(Color.appAccent)
            Text(text)
                .font(.body)
                .foregroundStyle(Color.appTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func fileLabel(icon: String, name: String, muted: Bool = false) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .frame(width: 18)
                .foregroundStyle(muted ? Color.appTextTertiary : Color.appTextPrimary)
            Text(name)
                .font(.callout)
                .foregroundStyle(muted ? Color.appTextSecondary : Color.appTextPrimary)
        }
    }
}

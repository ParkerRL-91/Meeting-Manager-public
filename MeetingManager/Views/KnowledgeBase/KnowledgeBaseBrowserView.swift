import SwiftUI
import AppKit

/// PRJ-014 Phase 1 — read-only browser + viewer for the connected Knowledge
/// Base. On-disk files under `KnowledgeBaseService.rootURL` are the source of
/// truth (the `kbDocument` table holds search chunks, not whole files), so the
/// left pane walks the folder tree off the main actor and the right pane reads
/// the selected file directly.
///
/// Layout mirrors `PeopleView`: a fixed-width left list + divider + detail pane.
/// Editing, save, and citation deep-link consumption arrive in later phases.
struct KnowledgeBaseBrowserView: View {
    @Environment(AppState.self) private var appState

    @State private var root: KnowledgeBaseService.KBNode?
    @State private var isLoading = true
    @State private var searchQuery = ""
    @State private var selectedPath: String?
    @State private var expandedPaths: Set<String> = []

    var body: some View {
        HStack(spacing: 0) {
            // MARK: - Left: folder tree + search
            VStack(spacing: 0) {
                listHeader
                Divider().background(Color.appSeparator)

                if isLoading {
                    Spacer()
                    ProgressView().controlSize(.small)
                    Spacer()
                } else if let root, hasSupportedFiles(root) {
                    treeList(root: root)
                } else {
                    Spacer()
                    EmptyStateView(
                        icon: "doc.text.magnifyingglass",
                        title: "No readable documents here",
                        subtitle: "Meeting Manager reads .md, .txt, .html, and .docx files. This folder has none yet.",
                        ctaLabel: "Reveal in Finder",
                        ctaAction: revealRootInFinder
                    )
                    Spacer()
                }
            }
            .frame(width: 300)
            .background(Color.appBackground)

            Divider().background(Color.appSeparator)

            // MARK: - Right: detail viewer
            detailPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.appBackground)
        }
        .background(Color.appBackground)
        .task { await loadTree() }
    }

    // MARK: - Left pane

    private var listHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Knowledge Base")
                    .font(.headline)
                    .foregroundStyle(Color.appTextPrimary)
                Spacer()
                Button {
                    Task { await loadTree() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help("Reload from disk")
            }

            SearchBar(query: $searchQuery, placeholder: "Search files…")
        }
        .padding(12)
    }

    @ViewBuilder
    private func treeList(root: KnowledgeBaseService.KBNode) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(visibleRows(of: root), id: \.node.path) { row in
                    nodeRow(row)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 6)
        }
    }

    private func nodeRow(_ row: TreeRow) -> some View {
        let node = row.node
        return Button {
            if node.isDirectory {
                toggleExpanded(node.path)
            } else {
                selectedPath = node.path
            }
        } label: {
            HStack(spacing: 6) {
                if node.isDirectory {
                    Image(systemName: expandedPaths.contains(node.path) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.appTextTertiary)
                        .frame(width: 10)
                } else {
                    Spacer().frame(width: 10)
                }
                Image(systemName: icon(for: node))
                    .font(.caption)
                    .foregroundStyle(node.isDirectory ? Color.appAccent : Color.appTextSecondary)
                    .frame(width: 16)
                Text(node.name)
                    .font(.callout)
                    .foregroundStyle(Color.appTextPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 5)
            .padding(.leading, CGFloat(row.depth) * 14 + 6)
            .padding(.trailing, 6)
            .background(
                selectedPath == node.path && !node.isDirectory
                    ? Color.appAccentSubtle : Color.clear
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Right pane

    @ViewBuilder
    private var detailPane: some View {
        if let path = selectedPath {
            KBDocumentDetailView(fileURL: URL(fileURLWithPath: path))
                .id(path)
        } else {
            EmptyStateView(
                icon: "books.vertical",
                title: "Browse your documents",
                subtitle: "Select a file on the left to read it. Meeting Manager renders Markdown and HTML; PDFs and Word files open in their default app."
            )
        }
    }

    // MARK: - Tree flattening + filtering

    private struct TreeRow { let node: KnowledgeBaseService.KBNode; let depth: Int }

    /// Flatten the tree into the rows currently visible, honoring expansion and
    /// the search filter. When searching, all matching files are shown with
    /// their ancestor folders auto-expanded; folder collapse is ignored.
    private func visibleRows(of root: KnowledgeBaseService.KBNode) -> [TreeRow] {
        var rows: [TreeRow] = []
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        func walk(_ node: KnowledgeBaseService.KBNode, depth: Int) {
            for child in node.children {
                if child.isDirectory {
                    let matchingDescendants = !query.isEmpty && subtreeMatches(child, query: query)
                    if query.isEmpty || matchingDescendants {
                        rows.append(TreeRow(node: child, depth: depth))
                        let expanded = query.isEmpty
                            ? expandedPaths.contains(child.path)
                            : true
                        if expanded { walk(child, depth: depth + 1) }
                    }
                } else {
                    if query.isEmpty || child.name.lowercased().contains(query) {
                        rows.append(TreeRow(node: child, depth: depth))
                    }
                }
            }
        }
        walk(root, depth: 0)
        return rows
    }

    private func subtreeMatches(_ node: KnowledgeBaseService.KBNode, query: String) -> Bool {
        for child in node.children {
            if child.isDirectory {
                if subtreeMatches(child, query: query) { return true }
            } else if child.name.lowercased().contains(query) {
                return true
            }
        }
        return false
    }

    private func hasSupportedFiles(_ node: KnowledgeBaseService.KBNode) -> Bool {
        for child in node.children {
            if child.isDirectory {
                if hasSupportedFiles(child) { return true }
            } else {
                return true
            }
        }
        return false
    }

    // MARK: - Actions

    private func loadTree() async {
        isLoading = true
        root = await KnowledgeBaseService.shared.documentTree()
        isLoading = false
    }

    private func toggleExpanded(_ path: String) {
        if expandedPaths.contains(path) { expandedPaths.remove(path) }
        else { expandedPaths.insert(path) }
    }

    private func revealRootInFinder() {
        guard let root = KnowledgeBaseService.shared.rootURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([root])
    }

    private func icon(for node: KnowledgeBaseService.KBNode) -> String {
        if node.isDirectory { return "folder" }
        switch (node.name as NSString).pathExtension.lowercased() {
        case "md", "markdown": return "doc.text"
        case "txt", "text": return "doc.plaintext"
        case "html", "htm": return "doc.richtext"
        case "docx": return "doc.append"
        case "pdf": return "doc.viewfinder"
        case "eml": return "envelope"
        default: return "doc"
        }
    }
}

/// Read-only detail pane for one KB file. Renders Markdown/HTML inline; offers
/// "Open in default app" for formats with no in-app viewer (PDF, docx, eml).
/// Edit mode arrives in Phase 2.
struct KBDocumentDetailView: View {
    let fileURL: URL

    @State private var content: String?
    @State private var isLoading = true
    @State private var modifiedAt: Date?

    private var ext: String { fileURL.pathExtension.lowercased() }

    private var relativePath: String {
        guard let root = KnowledgeBaseService.shared.rootURL else { return fileURL.lastPathComponent }
        let full = fileURL.path
        if full.hasPrefix(root.path) {
            let trimmed = String(full.dropFirst(root.path.count))
            return trimmed.hasPrefix("/") ? String(trimmed.dropFirst()) : trimmed
        }
        return fileURL.lastPathComponent
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Color.appSeparator)
            content(for: ext)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: fileURL) { await load() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(relativePath)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Color.appTextPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let modifiedAt {
                    Text("Modified \(modifiedAt.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(Color.appTextTertiary)
                }
            }
            Spacer()
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            } label: {
                Label("Reveal in Finder", systemImage: "magnifyingglass")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func content(for ext: String) -> some View {
        if isLoading {
            ProgressView().controlSize(.small)
        } else {
            switch ext {
            case "md", "markdown", "txt", "text":
                if let content {
                    ScrollView {
                        MarkdownRenderer(text: content, headingStyle: .display)
                            .padding(20)
                    }
                } else {
                    unreadableState
                }
            case "html", "htm":
                HTMLFileView(fileURL: fileURL)
            default:
                openExternallyState
            }
        }
    }

    private var openExternallyState: some View {
        EmptyStateView(
            icon: ext == "pdf" ? "doc.viewfinder" : "doc.append",
            title: "Opens in its default app",
            subtitle: "Meeting Manager indexes this \(ext.uppercased()) file for search but doesn't render it in-app. Open it in the app that handles \(ext.uppercased()) files.",
            ctaLabel: "Open in default app",
            ctaAction: { NSWorkspace.shared.open(fileURL) }
        )
    }

    private var unreadableState: some View {
        EmptyStateView(
            icon: "exclamationmark.triangle",
            title: "Couldn't read this file",
            subtitle: "The file may have moved, or it isn't valid text.",
            ctaLabel: "Reveal in Finder",
            ctaAction: { NSWorkspace.shared.activateFileViewerSelecting([fileURL]) }
        )
    }

    private func load() async {
        isLoading = true
        modifiedAt = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if ["md", "markdown", "txt", "text"].contains(ext) {
            content = await KnowledgeBaseService.shared.readTextFile(at: fileURL)
        } else {
            content = nil
        }
        isLoading = false
    }
}

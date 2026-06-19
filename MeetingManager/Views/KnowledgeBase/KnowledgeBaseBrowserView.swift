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

    // Editor coordination (Phase 2). The detail pane reports unsaved edits up
    // here so an in-app navigation away (select another file, switch sidebar
    // destination, incoming deep-link) can prompt the unsaved-edit guard.
    @State private var editorIsDirty = false
    /// A navigation the user requested while the editor had unsaved edits. Held
    /// until they answer the guard; nil otherwise.
    @State private var pendingNavigation: PendingNavigation?
    /// The held navigation captured for the async "Save" path. Tapping any alert
    /// button dismisses the alert, which synchronously runs `guardAlertBinding`'s
    /// setter and nils `pendingNavigation` — so the deferred save callback would
    /// otherwise find it gone. We snapshot it here when "Save" is tapped and have
    /// the post-save callback consume this instead.
    @State private var navAfterSave: PendingNavigation?
    /// Bumped to ask the detail pane to save then run the held navigation.
    @State private var saveAndProceedToken = 0

    // Create-new sheet state.
    @State private var showCreateSheet = false
    @State private var newFileName = ""
    @State private var newFileDirPath: String = ""
    @State private var createError: String?

    private enum PendingNavigation: Equatable {
        case selectFile(String)
        case clearSelection
    }

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
        .alert("Save changes before leaving?", isPresented: guardAlertBinding) {
            Button("Save") {
                // Snapshot the target before the dismissal setter nils
                // `pendingNavigation`; the post-save callback consumes it.
                navAfterSave = pendingNavigation
                saveAndProceedToken += 1
            }
            Button("Discard", role: .destructive) { performPendingNavigation() }
            Button("Cancel", role: .cancel) {
                pendingNavigation = nil
                navAfterSave = nil
            }
        } message: {
            Text("This note has unsaved edits. Save them, discard them, or stay here.")
        }
        .sheet(isPresented: $showCreateSheet) { createSheet }
        .onChange(of: appState.selectedKBPath) { _, newPath in
            // Incoming citation deep-link (later phases set this). Route through
            // the same unsaved-edit guard so an in-progress edit is never lost.
            guard let path = newPath else { return }
            requestSelect(path)
        }
        .onAppear {
            if let path = appState.selectedKBPath { requestSelect(path) }
        }
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
                    presentCreateSheet()
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help("Create a new note")

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
                requestSelect(node.path)
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
            KBDocumentDetailView(
                fileURL: URL(fileURLWithPath: path),
                isDirty: $editorIsDirty,
                saveAndProceedToken: saveAndProceedToken,
                onSavedForNavigation: { performPendingNavigation() },
                onDeleted: { handleDeleted(path) },
                onTreeChanged: { Task { await loadTree() } }
            )
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

    // MARK: - Navigation guard

    private var guardAlertBinding: Binding<Bool> {
        Binding(
            get: { pendingNavigation != nil },
            set: { if !$0 { pendingNavigation = nil } }
        )
    }

    /// Request selecting a file. If the current editor is dirty, hold the request
    /// behind the unsaved-edit guard; otherwise switch immediately.
    private func requestSelect(_ path: String) {
        guard path != selectedPath else { return }
        if editorIsDirty {
            pendingNavigation = .selectFile(path)
        } else {
            selectedPath = path
        }
    }

    /// Run whichever navigation was held behind the guard. Called synchronously
    /// from "Discard" (where `pendingNavigation` is still set) and asynchronously
    /// from the detail pane after a guard-triggered save completes (where the
    /// alert dismissal already nilled `pendingNavigation`, so the "Save" snapshot
    /// in `navAfterSave` is the live target). Prefer the snapshot.
    private func performPendingNavigation() {
        guard let nav = navAfterSave ?? pendingNavigation else { return }
        navAfterSave = nil
        pendingNavigation = nil
        editorIsDirty = false
        switch nav {
        case .selectFile(let path): selectedPath = path
        case .clearSelection: selectedPath = nil
        }
    }

    private func handleDeleted(_ path: String) {
        editorIsDirty = false
        if selectedPath == path { selectedPath = nil }
        Task { await loadTree() }
    }

    // MARK: - Create new note

    private func presentCreateSheet() {
        guard let root = KnowledgeBaseService.shared.rootURL else { return }
        // Default the new file's folder to the selected file's directory, else root.
        if let sel = selectedPath {
            newFileDirPath = URL(fileURLWithPath: sel).deletingLastPathComponent().path
        } else {
            newFileDirPath = root.path
        }
        newFileName = ""
        createError = nil
        showCreateSheet = true
    }

    @ViewBuilder
    private var createSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New note")
                .font(.headline)
                .foregroundStyle(Color.appTextPrimary)

            VStack(alignment: .leading, spacing: 6) {
                Text("Name")
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)
                TextField("Untitled", text: $newFileName)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Folder")
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)
                Picker("", selection: $newFileDirPath) {
                    ForEach(folderOptions(), id: \.path) { opt in
                        Text(opt.label).tag(opt.path)
                    }
                }
                .labelsHidden()
            }

            Text("A new Markdown (.md) note will be created here.")
                .font(.caption)
                .foregroundStyle(Color.appTextTertiary)

            if let createError {
                Text(createError)
                    .font(.caption)
                    .foregroundStyle(Color.appWarning)
            }

            HStack {
                Spacer()
                Button("Cancel") { showCreateSheet = false }
                Button("Create") { Task { await createFile() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(newFileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private struct FolderOption { let path: String; let label: String }

    /// Flatten the tree's folders into picker options, relative-path labelled.
    private func folderOptions() -> [FolderOption] {
        guard let root else {
            if let r = KnowledgeBaseService.shared.rootURL {
                return [FolderOption(path: r.path, label: r.lastPathComponent)]
            }
            return []
        }
        var out: [FolderOption] = []
        func walk(_ node: KnowledgeBaseService.KBNode) {
            if node.isDirectory {
                let label = node.relativePath.isEmpty ? node.name : node.relativePath
                out.append(FolderOption(path: node.path, label: label))
                for child in node.children where child.isDirectory { walk(child) }
            }
        }
        walk(root)
        return out
    }

    private func createFile() async {
        let dir = URL(fileURLWithPath: newFileDirPath)
        let outcome = await KnowledgeBaseService.shared.createMarkdownFile(name: newFileName, in: dir)
        switch outcome {
        case .created(let url):
            showCreateSheet = false
            await loadTree()
            expandedPaths.insert(dir.path)
            editorIsDirty = false
            selectedPath = url.path
        case .alreadyExists:
            createError = "A note with that name already exists in this folder."
        case .outsideRoot:
            createError = "Pick a folder inside your Knowledge Base."
        case .failed(let msg):
            createError = "Couldn't create the note: \(msg)"
        }
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

/// Detail pane for one KB file. Defaults to the RENDERED view (Markdown/HTML);
/// Edit is a deliberate toggle (mirrors SummaryView's Edit/Done). `.md`/`.txt`
/// edit = `MarkdownTextEditor` + formatting toolbar + live `MarkdownRenderer`
/// preview; `.html` edit = labeled source mode + live `HTMLStringView` preview.
/// Save/Revert are explicit; saving does atomic write + content-hash conflict
/// detection + targeted reindex. PDF/docx/eml open in their default app.
struct KBDocumentDetailView: View {
    let fileURL: URL
    /// Reports unsaved edits up to the browser so it can guard navigation.
    @Binding var isDirty: Bool
    /// Bumped by the browser to mean "save, then run the held navigation".
    var saveAndProceedToken: Int
    /// Called after a guard-triggered save completes successfully.
    var onSavedForNavigation: () -> Void
    /// Called after the file is deleted (so the browser can clear + reload).
    var onDeleted: () -> Void
    /// Called when the on-disk tree changed but the current selection stays open
    /// (e.g. "Save mine as a copy" adds a sibling without deselecting this file).
    var onTreeChanged: () -> Void

    @State private var content: String = ""          // editor buffer
    @State private var loadedContent: String = ""    // last-saved baseline
    @State private var loadedHash: String?           // hash at load (conflict basis)
    @State private var isLoading = true
    @State private var readFailed = false
    @State private var modifiedAt: Date?

    @State private var isEditing = false
    @State private var formatCommand: MarkdownFormatCommand?

    @State private var saveError: String?
    @State private var conflictContent: String?      // newer on-disk content
    @State private var showConflict = false
    @State private var showDeleteConfirm = false

    private var ext: String { fileURL.pathExtension.lowercased() }
    private var isTextEditable: Bool { ["md", "markdown", "txt", "text"].contains(ext) }
    private var isHTML: Bool { ext == "html" || ext == "htm" }
    private var isEditable: Bool { isTextEditable || isHTML }

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
            if let saveError {
                saveErrorBanner(saveError)
            }
            mainContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: fileURL) { await load() }
        .onChange(of: content) { _, _ in updateDirty() }
        .onChange(of: saveAndProceedToken) { _, _ in
            Task { await saveThenProceed() }
        }
        .alert("This document changed on disk", isPresented: $showConflict) {
            Button("Keep my changes") { Task { await resolveConflictKeepMine() } }
            Button("Save mine as a copy") { Task { await resolveConflictSaveCopy() } }
            Button("Discard and reload", role: .cancel) { resolveConflictReload() }
        } message: {
            Text("Someone (or another app) edited this file since you opened it. Choose what to do — reloading the newer version is the safe default.")
        }
        .confirmationDialog("Delete this note?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) { Task { await delete() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(fileURL.lastPathComponent) will be moved to the Trash. You can restore it from there.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(relativePath)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Color.appTextPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    if isDirty {
                        Text("Unsaved changes")
                            .font(.caption)
                            .foregroundStyle(Color.appWarning)
                    } else if let modifiedAt {
                        Text("Modified \(modifiedAt.formatted(.relative(presentation: .named)))")
                            .font(.caption)
                            .foregroundStyle(Color.appTextTertiary)
                    }
                }
            }
            Spacer()
            headerActions
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var headerActions: some View {
        if isEditing {
            Button("Revert") { revert() }
                .controlSize(.small)
                .disabled(!isDirty)
            Button("Save") { Task { await save() } }
                .controlSize(.small)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!isDirty)
            Button("Done") { Task { await finishEditing() } }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
        } else {
            if isEditable && !readFailed {
                Button {
                    isEditing = true
                } label: {
                    Label("Edit", systemImage: "pencil")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            Menu {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                } label: { Label("Reveal in Finder", systemImage: "magnifyingglass") }
                if isEditable {
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: { Label("Delete…", systemImage: "trash") }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)
        }
    }

    private func saveErrorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.appWarning)
            Text(message)
                .font(.caption)
                .foregroundStyle(Color.appTextPrimary)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(Color.appWarning.opacity(0.12))
    }

    // MARK: - Content

    @ViewBuilder
    private var mainContent: some View {
        if isLoading {
            ProgressView().controlSize(.small)
        } else if isTextEditable {
            if readFailed {
                unreadableState
            } else if isEditing {
                markdownEditor
            } else {
                ScrollView {
                    MarkdownRenderer(text: content, headingStyle: .display)
                        .padding(20)
                }
            }
        } else if isHTML {
            if isEditing {
                htmlEditor
            } else {
                HTMLFileView(fileURL: fileURL)
            }
        } else {
            openExternallyState
        }
    }

    // MARK: - Markdown editor (toolbar + live preview)

    private var markdownEditor: some View {
        VStack(spacing: 0) {
            formattingToolbar
            Divider().background(Color.appSeparator)
            HSplitView {
                MarkdownTextEditor(
                    text: $content,
                    baseFontSize: 14,
                    textColor: NSColor.labelColor,
                    insets: NSSize(width: 16, height: 16),
                    command: $formatCommand
                )
                .background(Color.appBackground)
                .frame(minWidth: 280)

                ScrollView {
                    MarkdownRenderer(text: content, baseFontSize: 14, headingStyle: .display)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                }
                .frame(minWidth: 280)
                .background(Color.appSurface)
            }
        }
    }

    private var formattingToolbar: some View {
        HStack(spacing: 4) {
            toolbarButton("bold", "Bold", .bold)
            toolbarButton("italic", "Italic", .italic)
            toolbarButton("number", "Heading", .heading)
            toolbarButton("list.bullet", "Bullet list", .bulletList)
            toolbarButton("text.quote", "Quote", .quote)
            toolbarButton("link", "Link", .link)
            toolbarButton("chevron.left.forwardslash.chevron.right", "Inline code", .code)
            Spacer()
            Text("Live preview on the right")
                .font(.caption2)
                .foregroundStyle(Color.appTextTertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color.appSurface)
    }

    private func toolbarButton(_ icon: String, _ help: String, _ cmd: MarkdownFormatCommand) -> some View {
        Button {
            formatCommand = cmd
        } label: {
            Image(systemName: icon)
                .font(.system(size: 12))
                .frame(width: 26, height: 22)
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    // MARK: - HTML source editor (labeled + caveat + live preview)

    private var htmlEditor: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.bubble")
                    .font(.caption)
                    .foregroundStyle(Color.appTextTertiary)
                Text("This is the page's HTML code — editing requires knowing HTML.")
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(Color.appSurface)
            Divider().background(Color.appSeparator)
            HSplitView {
                TextEditor(text: $content)
                    .font(.system(size: 13, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Color.appBackground)
                    .frame(minWidth: 280)

                HTMLStringView(html: content, baseURL: fileURL.deletingLastPathComponent())
                    .frame(minWidth: 280)
            }
        }
    }

    // MARK: - Empty / error states

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

    // MARK: - Load / dirty

    private func load() async {
        isLoading = true
        isEditing = false
        saveError = nil
        modifiedAt = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if isEditable {
            if let text = await KnowledgeBaseService.shared.readTextFile(at: fileURL) {
                content = text
                loadedContent = text
                loadedHash = await KnowledgeBaseService.shared.fileHash(at: fileURL)
                readFailed = false
            } else {
                content = ""
                loadedContent = ""
                loadedHash = nil
                readFailed = true
            }
        } else {
            content = ""
            loadedContent = ""
        }
        isDirty = false
        isLoading = false
    }

    private func updateDirty() {
        guard isEditable else { return }
        isDirty = isEditing && content != loadedContent
    }

    private func revert() {
        content = loadedContent
        isDirty = false
    }

    private func finishEditing() async {
        if isDirty { await save(); if isDirty { return } }   // save failed/conflict → stay
        isEditing = false
    }

    // MARK: - Save + conflict

    private func save() async {
        saveError = nil
        let outcome = await KnowledgeBaseService.shared.saveTextFile(
            at: fileURL, expectedHash: loadedHash, content: content)
        switch outcome {
        case .saved:
            loadedContent = content
            loadedHash = EmbeddingService.hash(content)
            modifiedAt = Date()
            isDirty = false
        case .conflict(let onDisk):
            conflictContent = onDisk
            showConflict = true
        case .failed(let msg):
            saveError = "Couldn't save: \(msg)"
        }
    }

    private func saveThenProceed() async {
        await save()
        // Only proceed if the save actually cleared the dirty flag (no conflict
        // pending, no error). The conflict/error dialogs hold the user here.
        if !isDirty && !showConflict && saveError == nil {
            onSavedForNavigation()
        }
    }

    private func resolveConflictKeepMine() async {
        showConflict = false
        if let newHash = await KnowledgeBaseService.shared.forceWriteTextFile(at: fileURL, content: content) {
            loadedContent = content
            loadedHash = newHash
            modifiedAt = Date()
            isDirty = false
        } else {
            saveError = "Couldn't save your changes."
        }
    }

    private func resolveConflictReload() {
        showConflict = false
        let onDisk = conflictContent ?? loadedContent
        content = onDisk
        loadedContent = onDisk
        Task { loadedHash = await KnowledgeBaseService.shared.fileHash(at: fileURL) }
        modifiedAt = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        isDirty = false
    }

    private func resolveConflictSaveCopy() async {
        showConflict = false
        let dir = fileURL.deletingLastPathComponent()
        let base = fileURL.deletingPathExtension().lastPathComponent
        let stamp = Date().formatted(.iso8601.year().month().day())
        let copyURL = dir.appendingPathComponent("\(base) (my copy \(stamp)).\(ext)")
        if await KnowledgeBaseService.shared.forceWriteTextFile(at: copyURL, content: content) != nil {
            // Reload this view from the newer on-disk version; the user's text is
            // safe in the copy.
            resolveConflictReload()
            onTreeChanged()   // refresh the tree so the new copy appears; keep this file open
        } else {
            saveError = "Couldn't save a copy."
        }
    }

    // MARK: - Delete

    private func delete() async {
        if await KnowledgeBaseService.shared.deleteFile(at: fileURL) {
            isDirty = false
            onDeleted()
        } else {
            saveError = "Couldn't move this file to the Trash."
        }
    }
}

import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The task detail editor (PRJ-013 Phase 4). Opened from a board card / inbox row
/// / Today / All row via `AppState.selectedTaskId`; rendered in the right pane of
/// `TaskManagerRootView`. Edits title, notes (markdown), priority, due/reminder,
/// stage, tags, and assignee; manages one level of subtasks; and attaches
/// files/images (pick, drop, paste) with inline thumbnails and open-in-Finder.
///
/// All persistence routes through the single owners: edits via
/// `ActionItemRepository.save`, completion via `setCompleted`, stage via
/// `moveToStage`. Completing every subtask does NOT auto-complete the parent.
///
/// DEFERRED to Phase 7 (their tables/rules arrive then): a dependencies
/// (blocked-by) picker and a recurrence editor.
struct TaskDetailView: View {
    let taskId: Int64
    /// Called after a change that the parent shell should reflect (board reload,
    /// inbox count, etc.).
    var onChange: () -> Void = {}

    @Environment(AppState.self) private var appState

    @State private var item: ActionItem?
    @State private var stages: [TaskStage] = []
    @State private var subtasks: [ActionItem] = []
    @State private var attachments: [TaskAttachment] = []
    @State private var meetingTitle: String?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var newSubtaskTitle = ""

    // Editable mirrors (committed to the repo on change / commit).
    @State private var title = ""
    @State private var notes = ""
    @State private var assignee = ""
    @State private var tagsText = ""
    @State private var priority = 0
    @State private var hasDueDate = false
    @State private var dueDate = Date()
    @State private var hasReminder = false
    @State private var reminderAt = Date()

    private let repo = ActionItemRepository(database: .shared)
    private let stageRepo = TaskStageRepository(database: .shared)
    private let attachmentRepo = TaskAttachmentRepository(database: .shared)
    private let attachmentService = TaskAttachmentService()

    private static let priorityLabels = ["None", "Low", "Medium", "High", "Urgent"]

    var body: some View {
        Group {
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if item == nil {
                EmptyStateView(
                    icon: "questionmark.square.dashed",
                    title: "Task not found",
                    subtitle: "This task may have been deleted. Pick another from the list."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                editor
            }
        }
        .background(Color.appBackground)
        .task(id: taskId) { await load() }
        .overlay(alignment: .bottom) { errorToast }
    }

    // MARK: - Editor

    private var editor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                titleField
                metaSection
                notesSection
                subtasksSection
                attachmentsSection
                if meetingTitle != nil { backlinkSection }
                footerActions
            }
            .padding(20)
            .frame(maxWidth: 640, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var titleField: some View {
        HStack(alignment: .top, spacing: 10) {
            Button { Task { await toggleComplete() } } label: {
                Image(systemName: (item?.isCompleted ?? false) ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle((item?.isCompleted ?? false) ? Color.appSuccess : Color.appTextTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel((item?.isCompleted ?? false) ? "Mark incomplete" : "Mark complete")

            TextField("Task title", text: $title, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.appTextPrimary)
                .onSubmit { Task { await commitFields() } }
                .onChange(of: title) { _, _ in scheduleCommit() }
        }
    }

    private var metaSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    fieldLabel("Priority")
                    Picker("Priority", selection: $priority) {
                        ForEach(0..<Self.priorityLabels.count, id: \.self) { i in
                            Text(Self.priorityLabels[i]).tag(i)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .onChange(of: priority) { _, _ in Task { await commitFields() } }
                }
                VStack(alignment: .leading, spacing: 4) {
                    fieldLabel("Stage")
                    Picker("Stage", selection: stageSelection) {
                        Text("No stage").tag(Int64?.none)
                        ForEach(stages) { stage in
                            Text(stage.name).tag(Optional(stage.id ?? -1))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                fieldLabel("Assignee")
                TextField("Unassigned", text: $assignee)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
                    .onChange(of: assignee) { _, _ in scheduleCommit() }
            }

            VStack(alignment: .leading, spacing: 4) {
                fieldLabel("Tags")
                TextField("Comma-separated", text: $tagsText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
                    .onChange(of: tagsText) { _, _ in scheduleCommit() }
            }

            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: $hasDueDate) { fieldLabel("Due date") }
                    .onChange(of: hasDueDate) { _, _ in Task { await commitFields() } }
                if hasDueDate {
                    DatePicker("", selection: $dueDate, displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                        .onChange(of: dueDate) { _, _ in Task { await commitFields() } }
                }
                Toggle(isOn: $hasReminder) { fieldLabel("Custom reminder time") }
                    .onChange(of: hasReminder) { _, _ in Task { await commitFields() } }
                if hasReminder {
                    DatePicker("", selection: $reminderAt, displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                        .onChange(of: reminderAt) { _, _ in Task { await commitFields() } }
                }
            }

            // TODO: Phase 7 — dependencies (blocked-by) picker and recurrence editor
            // land here once `taskDependency` / `recurrenceRuleJSON` rules ship.
        }
    }

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel("Notes (markdown)")
            TextEditor(text: $notes)
                .font(.system(size: 13))
                .frame(minHeight: 120)
                .padding(6)
                .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.appSeparator, lineWidth: 1))
                .onChange(of: notes) { _, _ in scheduleCommit() }
        }
    }

    // MARK: - Subtasks

    private var subtasksSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                fieldLabel("Subtasks")
                Spacer()
                if !subtasks.isEmpty {
                    Text("\(completedSubtaskCount)/\(subtasks.count)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.appTextTertiary)
                        .monospacedDigit()
                }
            }

            if !subtasks.isEmpty {
                ProgressView(value: Double(completedSubtaskCount), total: Double(subtasks.count))
                    .frame(maxWidth: 280)

                ForEach(Array(subtasks.enumerated()), id: \.element.id) { index, sub in
                    subtaskRow(sub, index: index)
                }
            }

            // One level only: a subtask itself cannot gain children.
            if item?.parentTaskId == nil {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 13)).foregroundStyle(Color.appTextTertiary)
                    TextField("Add a subtask…", text: $newSubtaskTitle)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .onSubmit { Task { await addSubtask() } }
                }
                .padding(10)
                .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func subtaskRow(_ sub: ActionItem, index: Int) -> some View {
        HStack(spacing: 8) {
            Button { Task { await completeSubtask(sub) } } label: {
                Image(systemName: sub.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(sub.isCompleted ? Color.appSuccess : Color.appTextTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(sub.isCompleted ? "Mark subtask incomplete" : "Mark subtask complete")
            Text(sub.title)
                .font(.system(size: 13))
                .foregroundStyle(Color.appTextPrimary)
                .strikethrough(sub.isCompleted, color: Color.appTextTertiary)
            Spacer(minLength: 0)
            Button { Task { await moveSubtask(from: index, to: index - 1) } } label: {
                Image(systemName: "chevron.up").font(.system(size: 11)).foregroundStyle(Color.appTextTertiary)
            }
            .buttonStyle(.plain)
            .disabled(index == 0)
            .help("Move up")
            .accessibilityLabel("Move subtask up")
            Button { Task { await moveSubtask(from: index, to: index + 2) } } label: {
                Image(systemName: "chevron.down").font(.system(size: 11)).foregroundStyle(Color.appTextTertiary)
            }
            .buttonStyle(.plain)
            .disabled(index == subtasks.count - 1)
            .help("Move down")
            .accessibilityLabel("Move subtask down")
            Button { Task { await deleteSubtask(sub) } } label: {
                Image(systemName: "trash").font(.system(size: 11)).foregroundStyle(Color.appTextTertiary)
            }
            .buttonStyle(.plain)
            .help("Delete subtask")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Attachments

    private var attachmentsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                fieldLabel("Attachments")
                Spacer()
                Button("Add file…") { pickFile() }
                    .font(.system(size: 12))
            }

            if !attachments.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 10)], spacing: 10) {
                    ForEach(attachments) { att in
                        attachmentTile(att)
                    }
                }
            }

            dropZone
        }
    }

    private func attachmentTile(_ att: TaskAttachment) -> some View {
        VStack(spacing: 6) {
            Group {
                if att.kind == .image, let thumb = attachmentService.thumbnail(for: att) {
                    Image(nsImage: thumb)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: att.kind == .image ? "photo" : "doc")
                        .font(.system(size: 28))
                        .foregroundStyle(Color.appTextTertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: 110, height: 80)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .background(Color.appBackground, in: RoundedRectangle(cornerRadius: 6))

            Text(att.originalName)
                .font(.system(size: 10))
                .foregroundStyle(Color.appTextSecondary)
                .lineLimit(1)
                .frame(width: 110)
        }
        .padding(6)
        .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 8))
        .contextMenu {
            Button("Show in Finder") { attachmentService.revealInFinder(att) }
            Button("Remove", role: .destructive) { Task { await removeAttachment(att) } }
        }
    }

    private var dropZone: some View {
        HStack(spacing: 8) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 13)).foregroundStyle(Color.appTextTertiary)
            Text("Drop files here, or paste an image (⌘V)")
                .font(.system(size: 12)).foregroundStyle(Color.appTextTertiary)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(Color.appSurface.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.appSeparator, style: StrokeStyle(lineWidth: 1, dash: [4]))
        )
        .dropDestination(for: URL.self) { urls, _ in
            Task { await attachFiles(urls) }
            return !urls.isEmpty
        }
        .onPasteCommand(of: [.image, .png, .tiff, .jpeg, .fileURL]) { providers in
            Task { await handlePaste(providers) }
        }
    }

    // MARK: - Backlink

    private var backlinkSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel("From meeting")
            Button {
                if let mid = item?.meetingId { appState.selectedMeetingId = mid }
            } label: {
                Label(meetingTitle ?? "Meeting", systemImage: "calendar.badge.clock")
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.appAccent)
        }
    }

    private var footerActions: some View {
        HStack(spacing: 12) {
            Button(item?.archivedAt == nil ? "Archive" : "Unarchive") {
                Task { await toggleArchive() }
            }
            Button("Delete", role: .destructive) { Task { await deleteTask() } }
            Spacer()
            if let updated = item?.updatedAt {
                Text("Updated \(updated.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 11)).foregroundStyle(Color.appTextTertiary)
            }
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private var errorToast: some View {
        if let errorMessage {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.appWarning)
                Text(errorMessage).font(.system(size: 12)).foregroundStyle(Color.appTextPrimary)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Color.appSurface, in: Capsule())
            .overlay(Capsule().stroke(Color.appSeparator, lineWidth: 1))
            .padding(.bottom, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                self.errorMessage = nil
            }
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.appTextSecondary)
    }

    // MARK: - Derived

    private var completedSubtaskCount: Int { subtasks.filter(\.isCompleted).count }

    private var stageSelection: Binding<Int64?> {
        Binding(
            get: { item?.stageId },
            set: { newValue in Task { await moveToStage(newValue) } }
        )
    }

    // MARK: - Load

    private func load() async {
        isLoading = (item == nil)
        defer { isLoading = false }
        async let loadedStages = stageRepo.allStages()
        async let loadedItem = repo.find(id: taskId)
        stages = (try? await loadedStages) ?? []
        guard let fetched = (try? await loadedItem) ?? nil else {
            item = nil
            return
        }
        item = fetched
        title = fetched.title
        notes = fetched.notes ?? ""
        assignee = fetched.assignee ?? ""
        tagsText = fetched.tags.joined(separator: ", ")
        priority = fetched.priority
        hasDueDate = fetched.dueDate != nil
        dueDate = fetched.dueDate ?? Date()
        hasReminder = fetched.reminderAt != nil
        reminderAt = fetched.reminderAt ?? (fetched.dueDate ?? Date())
        subtasks = (try? await repo.subtasks(of: taskId)) ?? []
        attachments = (try? await attachmentRepo.attachments(forTask: taskId)) ?? []
        if let mid = fetched.meetingId {
            meetingTitle = ((try? await appState.meetingRepository.find(id: mid)) ?? nil)?.title
        } else {
            meetingTitle = nil
        }
    }

    // MARK: - Field commit (debounced for text)

    @State private var commitTask: Task<Void, Never>?

    private func scheduleCommit() {
        commitTask?.cancel()
        commitTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            await commitFields()
        }
    }

    private func commitFields() async {
        guard var current = item else { return }
        current.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        current.notes = notes.isEmpty ? nil : notes
        current.assignee = assignee.isEmpty ? nil : assignee
        current.tags = tagsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        current.priority = priority
        current.dueDate = hasDueDate ? dueDate : nil
        current.reminderAt = hasReminder ? reminderAt : nil
        try? await repo.save(&current)
        item = current
        onChange()
    }

    // MARK: - Mutations (single owners)

    private func toggleComplete() async {
        guard let current = item else { return }
        try? await repo.setCompleted(id: taskId, !current.isCompleted)
        await load()
        onChange()
    }

    private func moveToStage(_ stageId: Int64?) async {
        try? await repo.moveToStage(id: taskId, stageId: stageId)
        await load()
        onChange()
    }

    private func toggleArchive() async {
        guard let current = item else { return }
        try? await repo.setArchived(id: taskId, current.archivedAt == nil)
        await load()
        onChange()
    }

    private func deleteTask() async {
        try? await repo.softDelete(id: taskId)
        appState.selectedTaskId = nil
        onChange()
    }

    // MARK: - Subtask mutations

    private func addSubtask() async {
        let trimmed = newSubtaskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var sub = ActionItem(
            parentTaskId: taskId,
            title: trimmed,
            triageState: .accepted,
            source: "manual"
        )
        try? await repo.save(&sub)
        newSubtaskTitle = ""
        subtasks = (try? await repo.subtasks(of: taskId)) ?? []
    }

    private func completeSubtask(_ sub: ActionItem) async {
        guard let id = sub.id else { return }
        // Completing every subtask must NOT auto-complete the parent (manual only).
        try? await repo.setCompleted(id: id, !sub.isCompleted)
        subtasks = (try? await repo.subtasks(of: taskId)) ?? []
    }

    private func deleteSubtask(_ sub: ActionItem) async {
        guard let id = sub.id else { return }
        try? await repo.softDelete(id: id)
        subtasks = (try? await repo.subtasks(of: taskId)) ?? []
    }

    /// Reorder via explicit up/down affordances (each row carries chevron buttons).
    /// `to` uses SwiftUI's `move(fromOffsets:toOffset:)` insertion-index semantics:
    /// move-up passes `index - 1`, move-down passes `index + 2`. The new order is
    /// persisted as a contiguous `sortOrder` sequence, so it survives a reload —
    /// `subtasks(of:)` orders by `sortOrder`.
    private func moveSubtask(from index: Int, to: Int) async {
        guard subtasks.indices.contains(index) else { return }
        let dest = min(max(to, 0), subtasks.count)
        var ordered = subtasks
        ordered.move(fromOffsets: IndexSet(integer: index), toOffset: dest)
        for (i, sub) in ordered.enumerated() {
            if let id = sub.id { try? await repo.reorder(id: id, sortOrder: Double(i)) }
        }
        subtasks = (try? await repo.subtasks(of: taskId)) ?? []
    }

    // MARK: - Attachment mutations

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Attach"
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await attachFiles(urls) }
    }

    private func attachFiles(_ urls: [URL]) async {
        for url in urls {
            do {
                _ = try await attachmentService.attach(fileURL: url, toTask: taskId)
            } catch {
                showError(error)
            }
        }
        attachments = (try? await attachmentRepo.attachments(forTask: taskId)) ?? []
    }

    private func handlePaste(_ providers: [NSItemProvider]) async {
        for provider in providers {
            if provider.canLoadObject(ofClass: NSImage.self) {
                if let data = await loadImageData(provider) {
                    do {
                        _ = try await attachmentService.attach(
                            imageData: data, originalName: "Pasted image.png", toTask: taskId
                        )
                    } catch {
                        showError(error)
                    }
                }
            } else if let url = await loadFileURL(provider) {
                do {
                    _ = try await attachmentService.attach(fileURL: url, toTask: taskId)
                } catch {
                    showError(error)
                }
            }
        }
        attachments = (try? await attachmentRepo.attachments(forTask: taskId)) ?? []
    }

    private func loadImageData(_ provider: NSItemProvider) async -> Data? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: NSImage.self) { object, _ in
                guard let image = object as? NSImage,
                      let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: png)
            }
        }
    }

    private func loadFileURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
    }

    private func removeAttachment(_ att: TaskAttachment) async {
        try? await attachmentService.remove(att)
        attachments = (try? await attachmentRepo.attachments(forTask: taskId)) ?? []
    }

    private func showError(_ error: Error) {
        withAnimation { errorMessage = error.localizedDescription }
    }
}

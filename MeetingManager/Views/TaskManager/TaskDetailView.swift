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
/// PRJ-013 Phase 7 adds a project picker, a dependencies (blocked-by) picker with a
/// cycle guard, and a recurrence editor (writes `recurrenceRuleJSON`).
struct TaskDetailView: View {
    let taskId: Int64
    /// Called after a change that the parent shell should reflect (board reload,
    /// inbox count, etc.).
    var onChange: () -> Void = {}

    @Environment(AppState.self) private var appState

    @State private var item: ActionItem?
    @State private var stages: [TaskStage] = []
    @State private var projects: [TaskProject] = []
    @State private var subtasks: [ActionItem] = []
    @State private var attachments: [TaskAttachment] = []
    @State private var blockers: [ActionItem] = []
    @State private var candidateBlockers: [ActionItem] = []
    @State private var meetingTitle: String?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var newSubtaskTitle = ""

    // Recurrence editor mirrors.
    @State private var isRecurring = false
    @State private var recurrenceFrequency: TaskRecurrenceRule.Frequency = .weekly
    @State private var recurrenceInterval = 1
    @State private var hasRecurrenceEnd = false
    @State private var recurrenceEnd = Date()

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
    private let projectRepo = TaskProjectRepository(database: .shared)
    private let dependencyRepo = TaskDependencyRepository(database: .shared)
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
                recurrenceSection
                if item?.parentTaskId == nil { dependenciesSection }
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
                VStack(alignment: .leading, spacing: 4) {
                    fieldLabel("Project")
                    Picker("Project", selection: projectSelection) {
                        Text("None").tag(Int64?.none)
                        ForEach(projects) { project in
                            Text(project.name).tag(Optional(project.id ?? -1))
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

    // MARK: - Recurrence (PRJ-013 Phase 7)

    private var recurrenceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $isRecurring) { fieldLabel("Repeats") }
                .onChange(of: isRecurring) { _, _ in Task { await commitRecurrence() } }
            if isRecurring {
                HStack(spacing: 10) {
                    Text("Every")
                        .font(.system(size: 12)).foregroundStyle(Color.appTextSecondary)
                    Stepper(value: $recurrenceInterval, in: 1...52) {
                        Text("\(recurrenceInterval)").monospacedDigit()
                            .font(.system(size: 12)).foregroundStyle(Color.appTextPrimary)
                    }
                    .fixedSize()
                    .onChange(of: recurrenceInterval) { _, _ in Task { await commitRecurrence() } }
                    Picker("Frequency", selection: $recurrenceFrequency) {
                        ForEach(TaskRecurrenceRule.Frequency.allCases) { freq in
                            Text(freq.label).tag(freq)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .onChange(of: recurrenceFrequency) { _, _ in Task { await commitRecurrence() } }
                }
                Toggle(isOn: $hasRecurrenceEnd) {
                    Text("Stop after a date")
                        .font(.system(size: 12)).foregroundStyle(Color.appTextSecondary)
                }
                .onChange(of: hasRecurrenceEnd) { _, _ in Task { await commitRecurrence() } }
                if hasRecurrenceEnd {
                    DatePicker("", selection: $recurrenceEnd, displayedComponents: [.date])
                        .labelsHidden()
                        .onChange(of: recurrenceEnd) { _, _ in Task { await commitRecurrence() } }
                }
                Text("A new occurrence is created when you complete this task, based on its due date.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.appTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Dependencies (PRJ-013 Phase 7)

    private var dependenciesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                fieldLabel("Blocked by")
                Spacer()
                Menu {
                    if candidateBlockers.isEmpty {
                        Text("No other tasks available")
                    }
                    ForEach(candidateBlockers) { candidate in
                        Button(candidate.title) { Task { await addBlocker(candidate) } }
                    }
                } label: {
                    Label("Add", systemImage: "plus")
                        .font(.system(size: 12))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            if blockers.isEmpty {
                Text("Not waiting on anything. Add a task here to mark this one blocked until that task is complete.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.appTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(blockers) { blocker in
                    blockerRow(blocker)
                }
            }
        }
    }

    private func blockerRow(_ blocker: ActionItem) -> some View {
        HStack(spacing: 8) {
            Image(systemName: blocker.isCompleted ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 13))
                .foregroundStyle(blocker.isCompleted ? Color.appSuccess : Color.appWarning)
            Text(blocker.title)
                .font(.system(size: 13))
                .foregroundStyle(Color.appTextPrimary)
                .strikethrough(blocker.isCompleted, color: Color.appTextTertiary)
            Spacer(minLength: 0)
            Button { Task { await removeBlocker(blocker) } } label: {
                Image(systemName: "xmark.circle").font(.system(size: 12)).foregroundStyle(Color.appTextTertiary)
            }
            .buttonStyle(.plain)
            .help("Remove dependency")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 8))
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

    private var projectSelection: Binding<Int64?> {
        Binding(
            get: { item?.projectId },
            set: { newValue in Task { await assignProject(newValue) } }
        )
    }

    // MARK: - Load

    private func load() async {
        isLoading = (item == nil)
        defer { isLoading = false }
        async let loadedStages = stageRepo.allStages()
        async let loadedProjects = projectRepo.allProjects()
        async let loadedItem = repo.find(id: taskId)
        stages = (try? await loadedStages) ?? []
        projects = (try? await loadedProjects) ?? []
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
        seedRecurrence(from: fetched)
        subtasks = (try? await repo.subtasks(of: taskId)) ?? []
        attachments = (try? await attachmentRepo.attachments(forTask: taskId)) ?? []
        blockers = (try? await dependencyRepo.blockers(of: taskId)) ?? []
        await loadCandidateBlockers()
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

    private func assignProject(_ projectId: Int64?) async {
        try? await repo.setProject(id: taskId, projectId: projectId)
        item?.projectId = projectId
        onChange()
    }

    // MARK: - Recurrence (PRJ-013 Phase 7)

    private func seedRecurrence(from fetched: ActionItem) {
        if let rule = TaskRecurrenceRule.decode(fetched.recurrenceRuleJSON) {
            isRecurring = true
            recurrenceFrequency = rule.frequency
            recurrenceInterval = max(rule.interval, 1)
            hasRecurrenceEnd = rule.endDate != nil
            recurrenceEnd = rule.endDate ?? (fetched.dueDate ?? Date())
        } else {
            isRecurring = false
            recurrenceFrequency = .weekly
            recurrenceInterval = 1
            hasRecurrenceEnd = false
        }
    }

    private func commitRecurrence() async {
        guard var current = item else { return }
        if isRecurring {
            let rule = TaskRecurrenceRule(
                frequency: recurrenceFrequency,
                interval: recurrenceInterval,
                endDate: hasRecurrenceEnd ? recurrenceEnd : nil
            )
            current.recurrenceRuleJSON = rule.encoded()
        } else {
            current.recurrenceRuleJSON = nil
        }
        try? await repo.save(&current)
        item = current
        onChange()
    }

    // MARK: - Dependencies (PRJ-013 Phase 7)

    private func loadCandidateBlockers() async {
        let board = (try? await repo.boardTasks()) ?? []
        let existing = Set(blockers.compactMap(\.id))
        candidateBlockers = board.filter { candidate in
            guard let cid = candidate.id else { return false }
            return cid != taskId && !existing.contains(cid)
        }
    }

    private func addBlocker(_ blocker: ActionItem) async {
        guard let blockerId = blocker.id else { return }
        do {
            try await dependencyRepo.add(taskId: taskId, dependsOnTaskId: blockerId)
        } catch {
            showError(error)
        }
        blockers = (try? await dependencyRepo.blockers(of: taskId)) ?? []
        await loadCandidateBlockers()
        onChange()
    }

    private func removeBlocker(_ blocker: ActionItem) async {
        guard let blockerId = blocker.id else { return }
        try? await dependencyRepo.remove(taskId: taskId, dependsOnTaskId: blockerId)
        blockers = (try? await dependencyRepo.blockers(of: taskId)) ?? []
        await loadCandidateBlockers()
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

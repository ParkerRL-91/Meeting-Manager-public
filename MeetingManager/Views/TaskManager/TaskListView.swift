import SwiftUI

/// The All view (PRJ-013 Phase 6). A searchable, filterable list over every task.
/// The default scope is the live board (accepted, not deleted); a Scope picker
/// switches to the Completed / Archived / Dismissed / Trash history sets. Filters
/// (stage, priority, tag, assignee, due range) narrow the live scope; Trash offers
/// an "Empty Trash now" action that purges soft-deleted rows (and their on-disk
/// attachment files) immediately.
struct TaskListView: View {
    let onOpenTask: (ActionItem) -> Void

    enum Scope: String, CaseIterable, Identifiable {
        case active = "Active"
        case completed = "Completed"
        case archived = "Archived"
        case dismissed = "Dismissed"
        case trash = "Trash"
        var id: String { rawValue }
    }

    enum DueRange: String, CaseIterable, Identifiable {
        case any = "Any due"
        case overdue = "Overdue"
        case today = "Today"
        case week = "Next 7 days"
        case none = "No date"
        var id: String { rawValue }
    }

    @State private var items: [ActionItem] = []
    @State private var stages: [TaskStage] = []
    @State private var query = ""
    @State private var scope: Scope = .active
    @State private var stageFilter: Int64?
    @State private var priorityFilter: Int?
    @State private var tagFilter: String?
    @State private var assigneeFilter: String?
    @State private var dueFilter: DueRange = .any
    @State private var isLoading = false
    @State private var isPurging = false

    private let repo = ActionItemRepository(database: .shared)
    private let stageRepo = TaskStageRepository(database: .shared)

    private var availableTags: [String] {
        Array(Set(items.flatMap(\.tags))).sorted()
    }

    private var availableAssignees: [String] {
        Array(Set(items.compactMap { $0.assignee }.filter { !$0.isEmpty })).sorted()
    }

    private var filtersActive: Bool {
        stageFilter != nil || priorityFilter != nil || tagFilter != nil
            || assigneeFilter != nil || dueFilter != .any
    }

    private var filtered: [ActionItem] {
        var result = items
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            result = result.filter {
                $0.title.lowercased().contains(q)
                    || ($0.assignee?.lowercased().contains(q) ?? false)
                    || $0.tags.contains(where: { $0.lowercased().contains(q) })
            }
        }
        if scope == .active {
            if let stageFilter { result = result.filter { $0.stageId == stageFilter } }
            if let priorityFilter { result = result.filter { $0.priority == priorityFilter } }
            if let tagFilter { result = result.filter { $0.tags.contains(tagFilter) } }
            if let assigneeFilter { result = result.filter { $0.assignee == assigneeFilter } }
            result = applyDueRange(result)
        }
        return result
    }

    private func applyDueRange(_ list: [ActionItem]) -> [ActionItem] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let tomorrow = cal.date(byAdding: .day, value: 1, to: start) ?? start
        let weekEnd = cal.date(byAdding: .day, value: 7, to: start) ?? start
        switch dueFilter {
        case .any: return list
        case .overdue: return list.filter { ($0.dueDate.map { $0 < start }) ?? false }
        case .today: return list.filter { ($0.dueDate.map { $0 >= start && $0 < tomorrow }) ?? false }
        case .week: return list.filter { ($0.dueDate.map { $0 >= start && $0 < weekEnd }) ?? false }
        case .none: return list.filter { $0.dueDate == nil }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            scopePicker
            searchBar
            if scope == .active { filterBar }
            if scope == .trash, !items.isEmpty { trashBar }
            Divider().background(Color.appSeparator)
            content
        }
        .background(Color.appBackground)
        .task { await load() }
        .onChange(of: scope) { _, _ in
            clearFilters()
            Task { await load() }
        }
    }

    private var scopePicker: some View {
        Picker("Scope", selection: $scope) {
            ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12)).foregroundStyle(Color.appTextTertiary)
            TextField("Search title, assignee, or tag…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                }
                .buttonStyle(.plain).foregroundStyle(Color.appTextTertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                stageMenu
                priorityMenu
                if !availableTags.isEmpty { tagMenu }
                if !availableAssignees.isEmpty { assigneeMenu }
                dueMenu
                if filtersActive {
                    Button("Clear") { clearFilters() }
                        .font(.system(size: 11))
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    private var stageMenu: some View {
        Menu {
            Button("All stages") { stageFilter = nil }
            Divider()
            ForEach(stages) { stage in
                Button(stage.name) { stageFilter = stage.id }
            }
        } label: {
            filterLabel("Stage", value: stages.first(where: { $0.id == stageFilter })?.name)
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    private var priorityMenu: some View {
        let labels = ["None", "Low", "Medium", "High", "Urgent"]
        return Menu {
            Button("Any priority") { priorityFilter = nil }
            Divider()
            ForEach(0..<labels.count, id: \.self) { level in
                Button(labels[level]) { priorityFilter = level }
            }
        } label: {
            filterLabel("Priority", value: priorityFilter.map { labels[$0] })
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    private var tagMenu: some View {
        Menu {
            Button("Any tag") { tagFilter = nil }
            Divider()
            ForEach(availableTags, id: \.self) { tag in
                Button("#\(tag)") { tagFilter = tag }
            }
        } label: {
            filterLabel("Tag", value: tagFilter.map { "#\($0)" })
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    private var assigneeMenu: some View {
        Menu {
            Button("Anyone") { assigneeFilter = nil }
            Divider()
            ForEach(availableAssignees, id: \.self) { name in
                Button(name) { assigneeFilter = name }
            }
        } label: {
            filterLabel("Assignee", value: assigneeFilter)
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    private var dueMenu: some View {
        Menu {
            ForEach(DueRange.allCases) { range in
                Button(range.rawValue) { dueFilter = range }
            }
        } label: {
            filterLabel("Due", value: dueFilter == .any ? nil : dueFilter.rawValue)
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    private func filterLabel(_ name: String, value: String?) -> some View {
        HStack(spacing: 4) {
            Text(value ?? name)
                .font(.system(size: 11, weight: value == nil ? .regular : .semibold))
            Image(systemName: "chevron.down").font(.system(size: 8))
        }
        .foregroundStyle(value == nil ? Color.appTextSecondary : Color.appAccent)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
            (value == nil ? Color.appSurface : Color.appAccent.opacity(0.12)),
            in: Capsule()
        )
    }

    private var trashBar: some View {
        HStack {
            Text("\(items.count) item\(items.count == 1 ? "" : "s") in Trash")
                .font(.caption).foregroundStyle(Color.appTextSecondary)
            Spacer()
            Button("Empty Trash now") { Task { await emptyTrash() } }
                .disabled(isPurging)
                .help("Permanently delete trashed tasks and their attachment files")
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filtered.isEmpty {
            EmptyStateView(icon: emptyIcon, title: emptyTitle, subtitle: emptySubtitle)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(filtered) { item in
                        TaskRowView(
                            item: item,
                            onComplete: { Task { await complete(item) } },
                            onTap: { onOpenTask(item) }
                        )
                    }
                }
                .padding(16)
            }
        }
    }

    private var emptyIcon: String {
        switch scope {
        case .active: return query.isEmpty && !filtersActive ? "list.bullet" : "magnifyingglass"
        case .completed: return "checkmark.circle"
        case .archived: return "archivebox"
        case .dismissed: return "xmark.bin"
        case .trash: return "trash"
        }
    }

    private var emptyTitle: String {
        if scope == .active && (!query.isEmpty || filtersActive) { return "No matches" }
        switch scope {
        case .active: return "No tasks yet"
        case .completed: return "Nothing completed yet"
        case .archived: return "Nothing archived"
        case .dismissed: return "Nothing dismissed"
        case .trash: return "Trash is empty"
        }
    }

    private var emptySubtitle: String {
        if scope == .active && (!query.isEmpty || filtersActive) {
            return "No tasks match your search and filters."
        }
        switch scope {
        case .active: return "Accept tasks from the inbox or add them on the board and they'll all show here."
        case .completed: return "Tasks you complete land here so you can look back at what got done."
        case .archived: return "Archived tasks are hidden from the board but kept for reference."
        case .dismissed: return "Suggestions you dismissed from the inbox are recoverable here."
        case .trash: return "Deleted tasks wait here before they're purged. Undo restores them."
        }
    }

    // MARK: - Actions

    private func complete(_ item: ActionItem) async {
        guard let id = item.id else { return }
        try? await repo.setCompleted(id: id, !item.isCompleted)
        await load()
    }

    private func emptyTrash() async {
        isPurging = true
        defer { isPurging = false }
        // Purge everything currently in the trash regardless of age (the user asked
        // explicitly). On-disk attachment files are removed via the attachment
        // service, which pairs the DB purge with file cleanup.
        try? await TaskAttachmentService().purgeDeletedTasks(olderThan: Date())
        await load()
    }

    private func clearFilters() {
        stageFilter = nil
        priorityFilter = nil
        tagFilter = nil
        assigneeFilter = nil
        dueFilter = .any
    }

    private func load() async {
        isLoading = items.isEmpty
        defer { isLoading = false }
        if stages.isEmpty {
            stages = (try? await stageRepo.allStages()) ?? []
        }
        switch scope {
        case .active:
            items = (try? await repo.boardTasks()) ?? []
        case .completed:
            items = (try? await repo.historyItems(.completed)) ?? []
        case .archived:
            items = (try? await repo.historyItems(.archived)) ?? []
        case .dismissed:
            items = (try? await repo.historyItems(.dismissed)) ?? []
        case .trash:
            items = (try? await repo.historyItems(.trash)) ?? []
        }
    }
}

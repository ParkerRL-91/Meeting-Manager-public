import SwiftUI

/// The Kanban board (PRJ-013 Phase 3). Columns come from
/// `TaskStageRepository.allStages`; cards from `ActionItemRepository.boardTasks`
/// grouped by `stageId`. A synthetic leading "No stage" column shows only when
/// stage-less accepted tasks exist. Cards move by drag, context menu, ⌃⌘←/→, and
/// VoiceOver actions — all through `ActionItemRepository.moveToStage`. WIP limits
/// are soft (warn + highlight, never block). Multi-select enables bulk move /
/// complete.
struct KanbanBoardView: View {
    let onOpenTask: (ActionItem) -> Void

    @State private var stages: [TaskStage] = []
    @State private var itemsByStage: [Int64: [ActionItem]] = [:]
    @State private var noStageItems: [ActionItem] = []
    @State private var selectedIds: Set<Int64> = []
    /// The card that keyboard shortcuts act on (last tapped/selected).
    @State private var focusedItem: ActionItem?
    @State private var isLoading = false

    private let repo = ActionItemRepository(database: .shared)
    private let stageRepo = TaskStageRepository(database: .shared)

    var body: some View {
        VStack(spacing: 0) {
            if !selectedIds.isEmpty { bulkBar }
            content
        }
        .background(Color.appBackground)
        .task { await load() }
    }

    // MARK: - Bulk action bar

    private var bulkBar: some View {
        HStack(spacing: 12) {
            Text("\(selectedIds.count) selected")
                .font(.caption).fontWeight(.medium)
                .foregroundStyle(Color.appTextSecondary)
            Menu("Move to") {
                ForEach(stages) { stage in
                    Button(stage.name) { Task { await bulkMove(to: stage.id) } }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Button("Complete") { Task { await bulkComplete() } }
            Spacer()
            Button("Clear") { selectedIds.removeAll() }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.appSurface)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if stages.isEmpty {
            EmptyStateView(
                icon: "rectangle.split.3x1",
                title: "No stages configured",
                subtitle: "Add Kanban stages in Settings → Task Stages to start organizing your tasks into columns."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    if !noStageItems.isEmpty {
                        column(for: nil, items: noStageItems)
                    }
                    ForEach(stages) { stage in
                        column(for: stage, items: stage.id.map { itemsByStage[$0] ?? [] } ?? [])
                    }
                }
                .padding(16)
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .background(keyboardShortcuts)
        }
    }

    private func column(for stage: TaskStage?, items: [ActionItem]) -> some View {
        KanbanColumnView(
            stage: stage,
            allStages: stages,
            items: items,
            selectedIds: selectedIds,
            onDropTask: { tid in Task { await move(taskId: tid, to: stage?.id) } },
            onMoveItem: { item, target in Task { await move(item: item, to: target) } },
            onCompleteItem: { item in Task { await complete(item) } },
            onShiftItem: { item, delta in Task { await shift(item, by: delta) } },
            onTapItem: { item in focusedItem = item; onOpenTask(item) },
            onToggleSelect: { toggleSelect($0) },
            onQuickAdd: { title in Task { await quickAdd(title, to: stage?.id) } }
        )
    }

    /// Invisible buttons that bind ⌃⌘←/→ to shifting the focused card's stage.
    private var keyboardShortcuts: some View {
        ZStack {
            Button("") { Task { if let f = focusedItem { await shift(f, by: -1) } } }
                .keyboardShortcut(.leftArrow, modifiers: [.control, .command])
            Button("") { Task { if let f = focusedItem { await shift(f, by: 1) } } }
                .keyboardShortcut(.rightArrow, modifiers: [.control, .command])
        }
        .opacity(0)
        .accessibilityHidden(true)
    }

    // MARK: - Mutations (all through the repository owners)

    private func move(item: ActionItem, to stageId: Int64?) async {
        guard let id = item.id else { return }
        await move(taskId: id, to: stageId)
    }

    private func move(taskId: Int64, to stageId: Int64?) async {
        try? await repo.moveToStage(id: taskId, stageId: stageId)
        await load()
    }

    private func shift(_ item: ActionItem, by delta: Int) async {
        guard !stages.isEmpty else { return }
        // Treat the "No stage" bucket as index -1 so a forward shift lands it on
        // the first real stage.
        let current = stages.firstIndex(where: { $0.id == item.stageId }) ?? -1
        let target = current + delta
        guard target >= 0, target < stages.count else { return }
        await move(item: item, to: stages[target].id)
    }

    private func complete(_ item: ActionItem) async {
        guard let id = item.id else { return }
        try? await repo.setCompleted(id: id, !item.isCompleted)
        await load()
    }

    private func quickAdd(_ title: String, to stageId: Int64?) async {
        var item = ActionItem(
            stageId: stageId,
            title: title,
            triageState: .accepted,
            source: "manual"
        )
        try? await repo.save(&item)
        await load()
    }

    private func toggleSelect(_ item: ActionItem) {
        guard let id = item.id else { return }
        if selectedIds.contains(id) { selectedIds.remove(id) } else { selectedIds.insert(id) }
    }

    private func bulkMove(to stageId: Int64?) async {
        for id in selectedIds { try? await repo.moveToStage(id: id, stageId: stageId) }
        selectedIds.removeAll()
        await load()
    }

    private func bulkComplete() async {
        for id in selectedIds { try? await repo.setCompleted(id: id, true) }
        selectedIds.removeAll()
        await load()
    }

    // MARK: - Load

    private func load() async {
        isLoading = stages.isEmpty
        defer { isLoading = false }
        let loadedStages = (try? await stageRepo.allStages()) ?? []
        let tasks = (try? await repo.boardTasks()) ?? []
        var grouped: [Int64: [ActionItem]] = [:]
        var noStage: [ActionItem] = []
        for task in tasks {
            if let sid = task.stageId, loadedStages.contains(where: { $0.id == sid }) {
                grouped[sid, default: []].append(task)
            } else {
                noStage.append(task)
            }
        }
        stages = loadedStages
        itemsByStage = grouped
        noStageItems = noStage
        // Drop selections / focus for tasks that no longer appear.
        let liveIds = Set(tasks.compactMap(\.id))
        selectedIds.formIntersection(liveIds)
        if let f = focusedItem?.id, !liveIds.contains(f) { focusedItem = nil }
    }
}

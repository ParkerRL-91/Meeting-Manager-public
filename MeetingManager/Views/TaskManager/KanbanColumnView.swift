import SwiftUI

/// One Kanban column (PRJ-013 Phase 3). Renders a stage (or the synthetic "No
/// stage" bucket when `stage == nil`) with its cards, a soft WIP warning, a
/// per-column quick-add, and a drop destination. All mutations route up to the
/// board so the repository stays the single owner of stage/completion writes.
struct KanbanColumnView: View {
    /// nil = the synthetic leading "No stage" bucket (shown only when non-empty).
    let stage: TaskStage?
    let allStages: [TaskStage]
    let items: [ActionItem]
    let selectedIds: Set<Int64>
    /// Task ids with an incomplete blocker (PRJ-013 Phase 7) — drives the badge.
    var blockedIds: Set<Int64> = []

    let onDropTask: (Int64) -> Void          // a card was dropped here
    let onMoveItem: (ActionItem, Int64?) -> Void
    let onCompleteItem: (ActionItem) -> Void
    let onShiftItem: (ActionItem, Int) -> Void
    let onTapItem: (ActionItem) -> Void
    let onToggleSelect: (ActionItem) -> Void
    let onQuickAdd: (String) -> Void

    @State private var isDropTargeted = false
    @State private var quickAddText = ""

    private var wipExceeded: Bool {
        guard let limit = stage?.wipLimit, limit > 0 else { return false }
        return items.count > limit
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Color.appSeparator)
            cards
            if stage != nil {
                quickAdd
            }
        }
        .frame(width: 260)
        .background(Color.appBackground, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(borderColor, lineWidth: isDropTargeted || wipExceeded ? 2 : 1)
        )
        .dropDestination(for: String.self) { droppedIds, _ in
            guard let first = droppedIds.first, let tid = Int64(first) else { return false }
            onDropTask(tid)
            return true
        } isTargeted: { isDropTargeted = $0 }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let hex = stage?.colorHex, let color = Color(hex: hex) {
                Circle().fill(color).frame(width: 9, height: 9)
            }
            Text(stage?.name ?? "No stage")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.appTextPrimary)
            Text("\(items.count)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.appTextTertiary)
                .monospacedDigit()
            Spacer()
            if let limit = stage?.wipLimit, limit > 0 {
                Text("\(items.count)/\(limit)")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(wipExceeded ? Color.appWarning : Color.appTextTertiary)
                    .help(wipExceeded ? "Over the WIP limit of \(limit)" : "WIP limit \(limit)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var cards: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(items) { item in
                    TaskCardView(
                        item: item,
                        stages: allStages,
                        isSelected: item.id.map { selectedIds.contains($0) } ?? false,
                        isBlocked: item.id.map { blockedIds.contains($0) } ?? false,
                        onMove: { onMoveItem(item, $0) },
                        onComplete: { onCompleteItem(item) },
                        onShiftStage: { onShiftItem(item, $0) },
                        onTap: { onTapItem(item) },
                        onToggleSelect: { onToggleSelect(item) }
                    )
                }
                if items.isEmpty {
                    Text(stage == nil ? "No stage-less tasks" : "Drop tasks here")
                        .font(.caption)
                        .foregroundStyle(Color.appTextTertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                }
            }
            .padding(10)
        }
        .frame(maxHeight: .infinity)
    }

    private var quickAdd: some View {
        HStack(spacing: 6) {
            TextField("Add a task…", text: $quickAddText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .onSubmit(submitQuickAdd)
            if !quickAddText.isEmpty {
                Button(action: submitQuickAdd) {
                    Image(systemName: "return").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.appAccent)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.appSurface)
    }

    private func submitQuickAdd() {
        let trimmed = quickAddText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onQuickAdd(trimmed)
        quickAddText = ""
    }

    private var borderColor: Color {
        if isDropTargeted { return Color.appAccent }
        if wipExceeded { return Color.appWarning }
        return Color.appSeparator
    }
}

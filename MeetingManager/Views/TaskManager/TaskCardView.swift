import SwiftUI

/// A single task card on the Kanban board (PRJ-013 Phase 3). Movable by pointer
/// (drag), keyboard (the board owns ⌃⌘←/→ shortcuts and routes to the selected
/// card), context menu ("Move to stage ▸"), and VoiceOver (`accessibilityActions`
/// mirroring the move verbs). Every move funnels through the board's `onMove`,
/// which calls `ActionItemRepository.moveToStage`.
struct TaskCardView: View {
    let item: ActionItem
    let stages: [TaskStage]
    let isSelected: Bool
    /// All move/complete verbs route up so the single completion/stage owners stay
    /// authoritative. `onMove(stageId)` accepts nil for the "No stage" bucket.
    let onMove: (Int64?) -> Void
    let onComplete: () -> Void
    let onShiftStage: (Int) -> Void   // -1 previous, +1 next
    let onTap: () -> Void
    let onToggleSelect: () -> Void

    private static let priorityLabels = ["", "Low", "Medium", "High", "Urgent"]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Button(action: onComplete) {
                    Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14))
                        .foregroundStyle(item.isCompleted ? Color.appSuccess : Color.appTextTertiary)
                }
                .buttonStyle(.plain)
                .help(item.isCompleted ? "Mark incomplete" : "Mark complete")
                .accessibilityLabel(item.isCompleted ? "Mark incomplete" : "Mark complete")

                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.appTextPrimary)
                    .strikethrough(item.isCompleted, color: Color.appTextTertiary)
                    .lineLimit(3)
                Spacer(minLength: 0)
            }

            if hasMeta {
                HStack(spacing: 8) {
                    if item.priority > 0 {
                        Label(Self.priorityLabels[min(item.priority, 4)], systemImage: "flag.fill")
                            .font(.system(size: 10.5))
                            .foregroundStyle(priorityColor)
                    }
                    if let assignee = item.assignee, !assignee.isEmpty {
                        Label(assignee, systemImage: "person")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Color.appTextSecondary)
                            .lineLimit(1)
                    }
                    if let due = item.dueDate {
                        Label(due.formatted(date: .abbreviated, time: .omitted), systemImage: "calendar")
                            .font(.system(size: 10.5))
                            .foregroundStyle(dueIsOverdue ? Color.appRecording : Color.appTextSecondary)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.appAccent : Color.appSeparator, lineWidth: isSelected ? 2 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture { onTap() }
        .draggable(String(item.id ?? -1))
        .contextMenu { contextMenu }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(item.title))
        .accessibilityHint(Text("Task card. Use actions to move between stages or complete."))
        .accessibilityActions { accessibilityActions }
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button(item.isCompleted ? "Mark incomplete" : "Mark complete", action: onComplete)
        Button(isSelected ? "Deselect" : "Select", action: onToggleSelect)
        Divider()
        Menu("Move to stage") {
            ForEach(stages) { stage in
                Button(stage.name) { onMove(stage.id) }
                    .disabled(stage.id == item.stageId)
            }
            if item.stageId != nil {
                Divider()
                Button("No stage") { onMove(nil) }
            }
        }
        Button("Move to previous stage") { onShiftStage(-1) }
        Button("Move to next stage") { onShiftStage(1) }
    }

    @ViewBuilder
    private var accessibilityActions: some View {
        Button(item.isCompleted ? "Mark incomplete" : "Mark complete", action: onComplete)
        Button("Move to previous stage") { onShiftStage(-1) }
        Button("Move to next stage") { onShiftStage(1) }
        ForEach(stages) { stage in
            Button("Move to \(stage.name)") { onMove(stage.id) }
        }
    }

    private var hasMeta: Bool {
        item.priority > 0 || (item.assignee?.isEmpty == false) || item.dueDate != nil
    }

    private var dueIsOverdue: Bool {
        guard let due = item.dueDate, !item.isCompleted else { return false }
        return due < Calendar.current.startOfDay(for: Date())
    }

    private var priorityColor: Color {
        switch item.priority {
        case 4: return Color.appRecording
        case 3: return Color.appWarning
        default: return Color.appTextSecondary
        }
    }
}

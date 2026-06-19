import SwiftUI

/// The Today view (PRJ-013). Surfaces overdue (red) / due-today / upcoming /
/// no-date tasks from the repository smart lists. Each row and card context menu
/// offers an in-app snooze/defer ("+1 day", "this weekend") that sets the task's
/// due date without opening the editor, so undated tasks are never invisible and
/// dated ones can be repositioned in one click.
struct TaskTodayView: View {
    /// When set, only tasks in this project are shown (PRJ-013 Phase 7).
    var projectFilter: Int64? = nil
    let onOpenTask: (TaskItem) -> Void

    @State private var overdue: [TaskItem] = []
    @State private var dueToday: [TaskItem] = []
    @State private var upcoming: [TaskItem] = []
    @State private var noDate: [TaskItem] = []
    @State private var isLoading = false

    private let repo = TaskRepository(database: .shared)

    private var isEmpty: Bool {
        overdue.isEmpty && dueToday.isEmpty && upcoming.isEmpty && noDate.isEmpty
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isEmpty {
                EmptyStateView(
                    icon: "checkmark.circle",
                    title: "Nothing scheduled",
                    subtitle: "Tasks with due dates appear here grouped by when they're due. Accepted tasks with no date show under Someday."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        section("Overdue", overdue, tint: Color.appRecording)
                        section("Due today", dueToday, tint: Color.appAccent)
                        section("Upcoming", upcoming, tint: Color.appTextSecondary)
                        section("Someday", noDate, tint: Color.appTextTertiary)
                    }
                    .padding(16)
                }
            }
        }
        .background(Color.appBackground)
        .task { await load() }
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [TaskItem], tint: Color) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(tint)
                    Text("\(items.count)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.appTextTertiary)
                        .monospacedDigit()
                }
                ForEach(items) { item in
                    TaskRowView(
                        item: item,
                        onComplete: { Task { await complete(item) } },
                        onTap: { onOpenTask(item) },
                        onSnoozeOneDay: { Task { await snooze(item, days: 1) } },
                        onSnoozeWeekend: { Task { await snoozeToWeekend(item) } }
                    )
                }
            }
        }
    }

    private func complete(_ item: TaskItem) async {
        guard let id = item.id else { return }
        try? await repo.setCompleted(id: id, !item.isCompleted)
        await load()
    }

    /// "+1 day" from the task's current due date (or today if it had none).
    private func snooze(_ item: TaskItem, days: Int) async {
        guard let id = item.id else { return }
        let base = item.dueDate ?? Calendar.current.startOfDay(for: Date())
        let next = Calendar.current.date(byAdding: .day, value: days, to: base) ?? base
        try? await repo.setDueDate(id: id, next)
        await load()
    }

    /// "This weekend" — the upcoming Saturday.
    private func snoozeToWeekend(_ item: TaskItem) async {
        guard let id = item.id else { return }
        let start = Calendar.current.startOfDay(for: Date())
        var target = start
        for offset in 1...7 {
            if let candidate = Calendar.current.date(byAdding: .day, value: offset, to: start),
               Calendar.current.component(.weekday, from: candidate) == 7 {
                target = candidate
                break
            }
        }
        try? await repo.setDueDate(id: id, target)
        await load()
    }

    private func load() async {
        isLoading = isEmpty
        defer { isLoading = false }
        async let o = repo.overdueItems()
        async let d = repo.dueTodayItems()
        async let u = repo.upcomingItems()
        async let n = repo.noDateItems()
        overdue = projected((try? await o) ?? [])
        dueToday = projected((try? await d) ?? [])
        upcoming = projected((try? await u) ?? [])
        noDate = projected((try? await n) ?? [])
    }

    /// Applies the active project filter (PRJ-013 Phase 7).
    private func projected(_ items: [TaskItem]) -> [TaskItem] {
        guard let projectFilter else { return items }
        return items.filter { $0.projectId == projectFilter }
    }
}

/// Shared flat row used by Today / All lists. The snooze callbacks are optional so
/// the All list can reuse the row without offering defer verbs.
struct TaskRowView: View {
    let item: TaskItem
    let onComplete: () -> Void
    let onTap: () -> Void
    var onSnoozeOneDay: (() -> Void)? = nil
    var onSnoozeWeekend: (() -> Void)? = nil
    /// When set, the row shows a Restore affordance (used by the All view's Trash
    /// scope) that lifts the task back out of soft-delete.
    var onRestore: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: onComplete) {
                Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(item.isCompleted ? Color.appSuccess : Color.appTextTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.isCompleted ? "Mark incomplete" : "Mark complete")

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.appTextPrimary)
                    .strikethrough(item.isCompleted, color: Color.appTextTertiary)
                HStack(spacing: 10) {
                    if let assignee = item.assignee, !assignee.isEmpty {
                        Label(assignee, systemImage: "person")
                            .font(.system(size: 10.5)).foregroundStyle(Color.appTextSecondary)
                    }
                    if let due = item.dueDate {
                        Label(due.formatted(date: .abbreviated, time: .omitted), systemImage: "calendar")
                            .font(.system(size: 10.5)).foregroundStyle(Color.appTextSecondary)
                    }
                }
            }
            Spacer(minLength: 0)
            if let onRestore {
                Button("Restore", action: onRestore)
                    .font(.system(size: 12))
                    .help("Restore this task from the Trash")
            }
            if onSnoozeOneDay != nil || onSnoozeWeekend != nil {
                snoozeMenu
            }
        }
        .padding(12)
        .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture(perform: onTap)
        .contextMenu {
            if let onRestore { Button("Restore", action: onRestore) }
            if let onSnoozeOneDay { Button("Snooze +1 day", action: onSnoozeOneDay) }
            if let onSnoozeWeekend { Button("Snooze to this weekend", action: onSnoozeWeekend) }
        }
    }

    private var snoozeMenu: some View {
        Menu {
            if let onSnoozeOneDay { Button("+1 day", action: onSnoozeOneDay) }
            if let onSnoozeWeekend { Button("This weekend", action: onSnoozeWeekend) }
        } label: {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 12))
                .foregroundStyle(Color.appTextTertiary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Snooze this task")
        .accessibilityLabel("Snooze task")
    }
}

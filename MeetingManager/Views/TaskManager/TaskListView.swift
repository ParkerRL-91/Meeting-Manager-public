import SwiftUI

/// The All view (PRJ-013 Phase 3, foundational). A flat, searchable list of every
/// accepted board task. The full filter set (stage/priority/tag/assignee/range)
/// and the Completed/Archived/Dismissed history filters land in Phase 6; this
/// phase ships title/assignee search + completion so the shell's All tab is real.
struct TaskListView: View {
    let onOpenTask: (ActionItem) -> Void

    @State private var items: [ActionItem] = []
    @State private var query = ""
    @State private var isLoading = false

    private let repo = ActionItemRepository(database: .shared)

    private var filtered: [ActionItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return items }
        return items.filter {
            $0.title.lowercased().contains(q) || ($0.assignee?.lowercased().contains(q) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider().background(Color.appSeparator)
            content
        }
        .background(Color.appBackground)
        .task { await load() }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12)).foregroundStyle(Color.appTextTertiary)
            TextField("Search tasks…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filtered.isEmpty {
            EmptyStateView(
                icon: "list.bullet",
                title: query.isEmpty ? "No tasks yet" : "No matches",
                subtitle: query.isEmpty
                    ? "Accept tasks from the inbox or add them on the board and they'll all show here."
                    : "No tasks match your search."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(filtered) { item in
                        TaskRowView(item: item, onComplete: { Task { await complete(item) } }, onTap: { onOpenTask(item) })
                    }
                }
                .padding(16)
            }
        }
    }

    private func complete(_ item: ActionItem) async {
        guard let id = item.id else { return }
        try? await repo.setCompleted(id: id, !item.isCompleted)
        await load()
    }

    private func load() async {
        isLoading = items.isEmpty
        defer { isLoading = false }
        items = (try? await repo.boardTasks()) ?? []
    }
}

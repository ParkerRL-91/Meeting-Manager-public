import SwiftUI

/// Top-level container for the user task manager (PRJ-013). A segmented shell over
/// the four task surfaces: the triage Inbox, the Kanban Board, the Today smart
/// list, and the All list. The Projects tab and the detail split-pane arrive in
/// later phases; for now "open task" sets `AppState.selectedTaskId` so the
/// deep-link plumbing is in place (the detail pane lands in Phase 4).
struct TaskManagerRootView: View {
    @Environment(AppState.self) private var appState

    enum Tab: String, CaseIterable, Identifiable {
        case inbox = "Inbox"
        case board = "Board"
        case today = "Today"
        case all = "All"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .board
    @State private var inboxCount = 0

    private let repo = ActionItemRepository(database: .shared)

    var body: some View {
        VStack(spacing: 0) {
            picker
            Divider().background(Color.appSeparator)
            content
        }
        .background(Color.appBackground)
        .task { await refreshInboxCount() }
        .onChange(of: tab) { _, _ in Task { await refreshInboxCount() } }
    }

    private var picker: some View {
        Picker("View", selection: $tab) {
            ForEach(Tab.allCases) { t in
                if t == .inbox && inboxCount > 0 {
                    Text("\(t.rawValue) (\(inboxCount))").tag(t)
                } else {
                    Text(t.rawValue).tag(t)
                }
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .inbox:
            TaskTriageInboxView()
        case .board:
            KanbanBoardView(onOpenTask: openTask)
        case .today:
            TaskTodayView(onOpenTask: openTask)
        case .all:
            TaskListView(onOpenTask: openTask)
        }
    }

    private func openTask(_ item: ActionItem) {
        appState.selectedTaskId = item.id
    }

    private func refreshInboxCount() async {
        inboxCount = ((try? await repo.inboxItems()) ?? []).count
    }
}

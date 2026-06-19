import SwiftUI

/// Top-level container for the user task manager (PRJ-013). A segmented shell over
/// the four task surfaces: the triage Inbox, the Kanban Board, the Today smart
/// list, and the All list. A detail split-pane (Phase 4) opens on the right when a
/// task is selected (`AppState.selectedTaskId`). The Projects tab arrives in a
/// later phase.
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
    /// Bumped after a detail edit so the active surface reloads.
    @State private var refreshToken = 0

    private let repo = ActionItemRepository(database: .shared)

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                picker
                Divider().background(Color.appSeparator)
                content
            }
            .frame(minWidth: 360)

            if let taskId = appState.selectedTaskId {
                detailPane(taskId)
                    .frame(minWidth: 320, idealWidth: 420)
            }
        }
        .background(Color.appBackground)
        .task { await refreshInboxCount() }
        .onChange(of: tab) { _, _ in Task { await refreshInboxCount() } }
    }

    private func detailPane(_ taskId: Int64) -> some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button {
                    appState.selectedTaskId = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.appTextTertiary)
                }
                .buttonStyle(.plain)
                .help("Close task")
                .accessibilityLabel("Close task")
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            TaskDetailView(taskId: taskId) {
                refreshToken += 1
                Task { await refreshInboxCount() }
            }
            .id(taskId)
        }
        .background(Color.appBackground)
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
        Group {
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
        // Reload the active surface when a detail edit reports a change.
        .id("\(tab.id)-\(refreshToken)")
    }

    private func openTask(_ item: ActionItem) {
        appState.selectedTaskId = item.id
    }

    private func refreshInboxCount() async {
        inboxCount = ((try? await repo.inboxItems()) ?? []).count
    }
}

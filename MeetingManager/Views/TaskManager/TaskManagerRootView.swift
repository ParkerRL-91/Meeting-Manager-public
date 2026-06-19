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
        case projects = "Projects"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .board
    @State private var inboxCount = 0
    /// Active project filter applied to Board / Today / All (nil = all). Owned here
    /// so the Projects tab's selection scopes the other surfaces (PRJ-013 Phase 7).
    @State private var projectFilter: Int64?
    /// Bumped after a detail edit so the active surface reloads.
    @State private var refreshToken = 0
    @State private var showQuickAdd = false
    @State private var showAICompose = false
    @State private var showTour = false
    /// Transient "Deleted · Undo" snackbar shown after a soft-delete in the detail
    /// pane (which unmounts on delete, so the snackbar lives here, above it).
    @State private var deleteUndo: DeleteUndo?

    private struct DeleteUndo: Identifiable {
        let id = UUID()
        let taskId: Int64
        let title: String
    }

    /// One-shot flag: the first-run task tour is shown once per install.
    @AppStorage("tasks.hasSeenTour") private var hasSeenTour = false

    private let repo = TaskRepository(database: .shared)

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                topBar
                Divider().background(Color.appSeparator)
                content
            }
            .frame(minWidth: 360)

            if let taskId = appState.selectedTaskId {
                detailPane(taskId)
                    .frame(minWidth: 320, idealWidth: 480, maxWidth: 640)
            }
        }
        .background(Color.appBackground)
        .overlay(alignment: .bottom) {
            if let deleteUndo {
                deleteUndoBar(deleteUndo)
            }
        }
        .overlay {
            if showTour {
                TaskTourView { hasSeenTour = true; showTour = false }
                    .transition(.opacity)
            }
        }
        .popover(isPresented: $showQuickAdd, arrowEdge: .top) {
            TaskQuickAddView(
                onAdded: { _ in
                    refreshToken += 1
                    Task { await refreshInboxCount() }
                },
                onOpenTask: { id in
                    showQuickAdd = false
                    appState.selectedTaskId = id
                }
            )
        }
        .sheet(isPresented: $showAICompose) {
            TaskAIComposeView(
                onAdded: { _ in
                    refreshToken += 1
                    Task { await refreshInboxCount() }
                },
                onOpenTask: { id in
                    appState.selectedTaskId = id
                }
            )
        }
        .task {
            await refreshInboxCount()
            if !hasSeenTour { showTour = true }
        }
        .onChange(of: tab) { _, _ in Task { await refreshInboxCount() } }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            picker
            Spacer()
            Button {
                showAICompose = true
            } label: {
                Label("Create with AI", systemImage: "sparkles")
            }
            .buttonStyle(.borderless)
            .help("Describe a task in plain language; AI fills in the date, recurrence, and details")
            .keyboardShortcut("n", modifiers: [.command, .option])
            Button {
                showQuickAdd = true
            } label: {
                Label("Quick Add", systemImage: "plus.circle.fill")
            }
            .help("Quickly add a task (parses dates, priority, and #tags)")
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .padding(.trailing, 16)
        }
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
            TaskDetailView(
                taskId: taskId,
                onChange: {
                    refreshToken += 1
                    Task { await refreshInboxCount() }
                },
                onDeleted: { id, title in
                    deleteUndo = DeleteUndo(taskId: id, title: title)
                }
            )
            .id(taskId)
        }
        .background(Color.appBackground)
    }

    private func deleteUndoBar(_ undo: DeleteUndo) -> some View {
        HStack(spacing: 12) {
            Text("Deleted “\(undo.title)”")
                .font(.caption)
                .foregroundStyle(Color.appTextSecondary)
                .lineLimit(1)
            Button("Undo") {
                Task {
                    try? await repo.undoDelete(id: undo.taskId)
                    refreshToken += 1
                    await refreshInboxCount()
                    appState.selectedTaskId = undo.taskId
                }
                deleteUndo = nil
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.appSurface, in: Capsule())
        .overlay(Capsule().stroke(Color.appSeparator, lineWidth: 1))
        .padding(.bottom, 16)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .task(id: undo.id) {
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if deleteUndo?.id == undo.id { deleteUndo = nil }
        }
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
                KanbanBoardView(projectFilter: projectFilter, onOpenTask: openTask)
            case .today:
                TaskTodayView(projectFilter: projectFilter, onOpenTask: openTask)
            case .all:
                TaskListView(projectFilter: projectFilter, onOpenTask: openTask)
            case .projects:
                TaskProjectsView(projectFilter: $projectFilter)
            }
        }
        // Reload the active surface when a detail edit reports a change or the
        // project filter changes.
        .id("\(tab.id)-\(refreshToken)-\(projectFilter.map(String.init) ?? "all")")
    }

    private func openTask(_ item: TaskItem) {
        appState.selectedTaskId = item.id
    }

    private func refreshInboxCount() async {
        inboxCount = ((try? await repo.inboxItems()) ?? []).count
    }
}

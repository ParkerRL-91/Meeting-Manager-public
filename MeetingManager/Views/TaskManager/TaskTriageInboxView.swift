import SwiftUI

/// The review queue (PRJ-013). AI-identified action items land here (`triageState
/// == .inbox`); the user accepts them onto the board or dismisses them. Accept and
/// dismiss are both reversible via the transient Undo bar.
struct TaskTriageInboxView: View {
    @Environment(AppState.self) private var appState

    @State private var items: [ActionItem] = []
    @State private var meetingTitles: [String: String] = [:]
    @State private var isLoading = false
    @State private var undo: UndoAction?

    private let repo = ActionItemRepository(database: .shared)

    private struct UndoAction: Identifiable {
        let id = UUID()
        let label: String
        let revert: () async -> Void
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Color.appSeparator)
            content
            if let undo {
                undoBar(undo)
            }
        }
        .background(Color.appBackground)
        .task { await load() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Inbox")
                    .font(.title2).fontWeight(.semibold)
                    .foregroundStyle(Color.appTextPrimary)
                Text("\(items.count) task\(items.count == 1 ? "" : "s") to review")
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)
            }
            Spacer()
            if !items.isEmpty {
                Button("Accept All") { Task { await acceptAll() } }
                    .help("Move every queued task onto the board")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if items.isEmpty {
            EmptyStateView(
                icon: "tray",
                title: "Nothing to review",
                subtitle: "Action items found in your meetings appear here so you can accept them onto your board or dismiss them."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(items) { item in
                        row(item)
                    }
                }
                .padding(16)
            }
        }
    }

    private func row(_ item: ActionItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(item.title)
                    .font(.body)
                    .foregroundStyle(Color.appTextPrimary)
                HStack(spacing: 10) {
                    if let assignee = item.assignee, !assignee.isEmpty {
                        Label(assignee, systemImage: "person")
                            .font(.caption).foregroundStyle(Color.appTextSecondary)
                    }
                    if let due = item.dueDate {
                        Label(due.formatted(date: .abbreviated, time: .omitted), systemImage: "calendar")
                            .font(.caption).foregroundStyle(Color.appTextSecondary)
                    }
                    if let mid = item.meetingId, let title = meetingTitles[mid] {
                        Label(title, systemImage: "calendar.badge.clock")
                            .font(.caption).foregroundStyle(Color.appTextTertiary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 8)
            Button { Task { await accept(item) } } label: {
                Image(systemName: "checkmark.circle.fill").font(.title3)
            }
            .buttonStyle(.plain).foregroundStyle(.green)
            .help("Accept onto the board")
            Button { Task { await dismissItem(item) } } label: {
                Image(systemName: "xmark.circle.fill").font(.title3)
            }
            .buttonStyle(.plain).foregroundStyle(Color.appTextTertiary)
            .help("Dismiss")
        }
        .padding(12)
        .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 8))
    }

    private func undoBar(_ undo: UndoAction) -> some View {
        HStack {
            Text(undo.label)
                .font(.caption)
                .foregroundStyle(Color.appTextSecondary)
                .lineLimit(1)
            Spacer()
            Button("Undo") {
                Task { await undo.revert(); await load() }
                self.undo = nil
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color.appSurface)
    }

    // MARK: - Data

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        let loaded = (try? await repo.inboxItems()) ?? []
        var titles: [String: String] = [:]
        for mid in Set(loaded.compactMap(\.meetingId)) {
            if let meeting = (try? await appState.meetingRepository.find(id: mid)) ?? nil {
                titles[mid] = meeting.title
            }
        }
        items = loaded
        meetingTitles = titles
    }

    private func accept(_ item: ActionItem) async {
        guard let id = item.id else { return }
        try? await repo.accept(id: id)
        undo = UndoAction(label: "Accepted “\(item.title)”") { try? await repo.restoreToInbox(id: id) }
        await load()
    }

    private func dismissItem(_ item: ActionItem) async {
        guard let id = item.id else { return }
        try? await repo.dismiss(id: id)
        undo = UndoAction(label: "Dismissed “\(item.title)”") { try? await repo.restoreToInbox(id: id) }
        await load()
    }

    private func acceptAll() async {
        for item in items {
            if let id = item.id { try? await repo.accept(id: id) }
        }
        undo = nil
        await load()
    }
}

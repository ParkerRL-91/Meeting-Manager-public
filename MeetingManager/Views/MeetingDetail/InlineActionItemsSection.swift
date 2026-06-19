import SwiftUI
import os

/// Compact action-items list rendered inline beneath the summary text.
/// Replaces the dedicated Action Items tab — items belong with the summary,
/// not behind another click (P1-T02).
struct InlineActionItemsSection: View {
    let meetingId: String

    @Environment(AppState.self) private var appState
    @State private var items: [TaskItem] = []
    @State private var isAddingNew = false
    @State private var newItemTitle = ""
    @State private var errorMessage: String?
    @FocusState private var newItemFocused: Bool

    private let repo = TaskRepository()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if items.isEmpty && !isAddingNew {
                Text("No action items yet")
                    .font(.subheadline)
                    .italic()
                    .foregroundStyle(Color.appTextTertiary)
                    .padding(.vertical, 4)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(items) { item in
                        row(item)
                    }
                }
            }

            if isAddingNew {
                newItemField
            }
        }
        .padding(.vertical, 12)
        .task { await reload() }
        .refreshOnTaskCompletion(
            meetingId: meetingId,
            types: [.summary, .regeneration, .enrichment],
            tasks: appState.taskQueueManager.allTasks
        ) {
            Task { await reload() }
        }
        .errorAlert($errorMessage)
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack {
            Text("Action Items (\(items.count))")
                .font(.headline)
                .foregroundStyle(Color.appTextPrimary)

            Spacer()

            Button {
                isAddingNew = true
                newItemTitle = ""
                // Defer focus to next runloop so the field has mounted.
                DispatchQueue.main.async { newItemFocused = true }
            } label: {
                Label("Add item", systemImage: "plus")
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(Color.appAccent)
        }
    }

    // MARK: - Row

    @ViewBuilder
    private func row(_ item: TaskItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                guard let id = item.id else { return }
                Task {
                    do {
                        try await repo.toggleComplete(id: id)
                    } catch {
                        Logger.database.error("Failed to toggle action item \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                        await MainActor.run {
                            errorMessage = "Failed to update action item: \(error.localizedDescription)"
                        }
                    }
                    await reload()
                }
            } label: {
                Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(item.isCompleted ? Color.appSuccess : Color.appTextSecondary)
            }
            .buttonStyle(.plain)
            .help(item.isCompleted ? "Mark incomplete" : "Mark complete")

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.body)
                    .foregroundStyle(Color.appTextPrimary)
                    .strikethrough(item.isCompleted, color: Color.appTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                if (item.assignee?.isEmpty == false) || item.dueDate != nil {
                    HStack(spacing: 6) {
                        if let assignee = item.assignee, !assignee.isEmpty {
                            Label(assignee, systemImage: "person.fill")
                                .font(.caption)
                                .foregroundStyle(Color.appAccent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.appAccent.opacity(0.15), in: Capsule())
                        }
                        if let due = item.dueDate {
                            Label(DateFormatting.shortDate(from: due), systemImage: "calendar")
                                .font(.caption)
                                .foregroundStyle(Color.appTextTertiary)
                        }
                    }
                }
            }

            Spacer()
        }
    }

    // MARK: - New item field

    @ViewBuilder
    private var newItemField: some View {
        HStack(spacing: 10) {
            Image(systemName: "circle")
                .font(.title3)
                .foregroundStyle(Color.appTextTertiary)

            TextField("New action item", text: $newItemTitle)
                .textFieldStyle(.plain)
                .font(.body)
                .foregroundStyle(Color.appTextPrimary)
                .focused($newItemFocused)
                .onSubmit { commitNewItem() }

            Button("Cancel") {
                isAddingNew = false
                newItemTitle = ""
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(Color.appTextTertiary)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Actions

    private func commitNewItem() {
        let trimmed = newItemTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            isAddingNew = false
            return
        }
        var item = TaskItem(meetingId: meetingId, title: trimmed)
        Task {
            do {
                try await repo.save(&item)
            } catch {
                Logger.database.error("Failed to save new action item: \(error.localizedDescription, privacy: .public)")
                await MainActor.run {
                    errorMessage = "Failed to add action item: \(error.localizedDescription)"
                }
            }
            await MainActor.run {
                newItemTitle = ""
                isAddingNew = false
            }
            await reload()
        }
    }

    private func reload() async {
        do {
            items = try await repo.itemsForMeeting(meetingId)
        } catch {
            Logger.database.error("Failed to load action items for \(meetingId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            await MainActor.run {
                errorMessage = "Failed to load action items: \(error.localizedDescription)"
            }
            items = []
        }
    }
}

// MARK: - Preview

// #Preview {
//     InlineActionItemsSection(meetingId: "preview-1")
//         .padding()
//         .frame(width: 600)
//         .background(Color.appBackground)
// }

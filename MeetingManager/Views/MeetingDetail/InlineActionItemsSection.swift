import SwiftUI
import os

/// Compact action-items list rendered inline beneath the summary text.
/// Replaces the dedicated Action Items tab — items belong with the summary,
/// not behind another click (P1-T02).
struct InlineActionItemsSection: View {
    let meetingId: String

    @Environment(AppState.self) private var appState
    @State private var items: [ActionItem] = []
    @State private var isAddingNew = false
    @State private var newItemTitle = ""
    @State private var errorMessage: String?
    /// Tracks per-item Reminders export confirmation flashes.
    @State private var sentItemIds: Set<Int64> = []
    /// Briefly true after a successful "Send all" to show a checkmark badge.
    @State private var sentAll: Bool = false
    @FocusState private var newItemFocused: Bool

    @AppStorage("reminders.listIdentifier") private var remindersListIdentifier: String = ""

    private let repo = ActionItemRepository()

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

            if items.count >= 2 {
                sendAllButton
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
    private func row(_ item: ActionItem) -> some View {
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

            // Per-item "Send to Reminders" affordance.
            Button {
                sendToReminders(item)
            } label: {
                if let id = item.id, sentItemIds.contains(id) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.body)
                        .foregroundStyle(Color.appSuccess)
                        .transition(.opacity)
                } else {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.body)
                        .foregroundStyle(Color.appTextSecondary)
                }
            }
            .buttonStyle(.plain)
            .help("Send to Apple Reminders")
        }
    }

    // MARK: - Send all to Reminders

    @ViewBuilder
    private var sendAllButton: some View {
        HStack {
            Spacer()
            Button {
                sendAllToReminders()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: sentAll ? "checkmark.circle.fill" : "arrow.up.forward.app")
                    Text(sentAll ? "Sent to Reminders" : "Send all to Reminders")
                }
                .font(.caption)
                .fontWeight(.medium)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(sentAll ? Color.appSuccess : Color.appAccent)
        }
        .padding(.top, 4)
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
        var item = ActionItem(meetingId: meetingId, title: trimmed)
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

    private func sendToReminders(_ item: ActionItem) {
        Task {
            let service = RemindersService.shared
            if !service.isAuthorized {
                let granted = await service.requestAccess()
                guard granted else {
                    await MainActor.run {
                        errorMessage = "Reminders access was not granted. Enable it in System Settings > Privacy & Security > Reminders."
                    }
                    return
                }
            }
            do {
                let list = service.list(withIdentifier: remindersListIdentifier.isEmpty ? nil : remindersListIdentifier)
                try service.add(item, list: list)
                if let id = item.id {
                    await MainActor.run {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            sentItemIds.insert(id)
                        }
                    }
                    // Auto-clear the checkmark after a moment.
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    await MainActor.run {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            sentItemIds.remove(id)
                        }
                    }
                }
            } catch {
                Logger.general.error("Failed to send action item to Reminders: \(error.localizedDescription, privacy: .public)")
                await MainActor.run {
                    errorMessage = "Failed to send to Reminders: \(error.localizedDescription)"
                }
            }
        }
    }

    private func sendAllToReminders() {
        Task {
            let service = RemindersService.shared
            if !service.isAuthorized {
                let granted = await service.requestAccess()
                guard granted else {
                    await MainActor.run {
                        errorMessage = "Reminders access was not granted. Enable it in System Settings > Privacy & Security > Reminders."
                    }
                    return
                }
            }
            do {
                let list = service.list(withIdentifier: remindersListIdentifier.isEmpty ? nil : remindersListIdentifier)
                _ = try service.addAll(items, list: list)
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.2)) { sentAll = true }
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.2)) { sentAll = false }
                }
            } catch {
                Logger.general.error("Failed to send all action items to Reminders: \(error.localizedDescription, privacy: .public)")
                await MainActor.run {
                    errorMessage = "Failed to send to Reminders: \(error.localizedDescription)"
                }
            }
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

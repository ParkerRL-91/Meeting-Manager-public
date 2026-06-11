import SwiftUI

struct AllActionItemsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var openItems: [ActionItem] = []
    @State private var meetings: [String: Meeting] = [:]
    @State private var isLoading = true
    @State private var sentItemIds: Set<Int64> = []
    @AppStorage("reminders.listIdentifier") private var remindersListIdentifier: String = ""

    private let actionItemRepo = ActionItemRepository()

    var body: some View {
        Group {
            if isLoading {
                Spacer()
                ProgressView()
                Spacer()
            } else if openItems.isEmpty {
                Spacer()
                EmptyStateView(
                    icon: "checkmark.circle",
                    title: "No Open Action Items",
                    subtitle: "Action items are extracted from meeting transcripts after a recording ends. Start a meeting to generate your first items.",
                    ctaLabel: "Start a Meeting",
                    ctaAction: {
                        dismiss()
                        appState.startNewMeeting()
                    }
                )
                Spacer()
            } else {
                itemsList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appBackground)
        .navigationTitle("All Action Items")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Color.appTextSecondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
            }
        }
        .task {
            await loadItems()
        }
    }

    // MARK: - Grouped List

    private var groupedItems: [(Meeting?, [ActionItem])] {
        let grouped = Dictionary(grouping: openItems) { $0.meetingId }
        return grouped.map { meetingId, items in
            (meetings[meetingId], items)
        }
        .sorted { lhs, rhs in
            let lhsDate = lhs.0?.effectiveDate ?? .distantPast
            let rhsDate = rhs.0?.effectiveDate ?? .distantPast
            return lhsDate > rhsDate
        }
    }

    @ViewBuilder
    private var itemsList: some View {
        List {
            ForEach(groupedItems, id: \.0?.id) { meeting, items in
                Section {
                    ForEach(items) { item in
                        actionItemRow(item)
                    }
                } header: {
                    HStack {
                        if let meeting {
                            Text(meeting.title)
                                .font(.headline)
                                .foregroundStyle(Color.appTextPrimary)

                            Text(DateFormatting.shortDate(from: meeting.effectiveDate))
                                .font(.caption)
                                .foregroundStyle(Color.appTextTertiary)
                        } else {
                            Text("Unknown Meeting")
                                .font(.headline)
                                .foregroundStyle(Color.appTextSecondary)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: - Row

    @ViewBuilder
    private func actionItemRow(_ item: ActionItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                guard let itemId = item.id else { return }
                Task {
                    try? await actionItemRepo.toggleComplete(id: itemId)
                    await loadItems()
                }
            } label: {
                Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(item.isCompleted ? Color.appSuccess : Color.appTextSecondary)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.body)
                    .foregroundStyle(Color.appTextPrimary)

                HStack(spacing: 8) {
                    if let assignee = item.assignee, !assignee.isEmpty {
                        Label(assignee, systemImage: "person.fill")
                            .font(.caption)
                            .foregroundStyle(Color.appAccent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.appAccent.opacity(0.15), in: Capsule())
                    }

                    if let dueDate = item.dueDate {
                        Label(DateFormatting.shortDate(from: dueDate), systemImage: "calendar")
                            .font(.caption)
                            .foregroundStyle(Color.appTextTertiary)
                    }
                }
            }

            Spacer()

            // Same per-item Reminders push the meeting page has (TASK-037) —
            // the global list previously had no way to act on an item.
            Button {
                sendToReminders(item)
            } label: {
                Image(systemName: item.id.map { sentItemIds.contains($0) } == true ? "checkmark" : "bell.badge")
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)
            }
            .buttonStyle(.plain)
            .help("Add to Apple Reminders")
        }
        .padding(.vertical, 4)
    }

    private func sendToReminders(_ item: ActionItem) {
        Task {
            let service = RemindersService.shared
            if !service.isAuthorized {
                guard await service.requestAccess() else { return }
            }
            do {
                let list = service.list(withIdentifier: remindersListIdentifier.isEmpty ? nil : remindersListIdentifier)
                try service.add(item, list: list)
                if let id = item.id {
                    withAnimation(.easeInOut(duration: 0.2)) { _ = sentItemIds.insert(id) }
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    withAnimation(.easeInOut(duration: 0.2)) { _ = sentItemIds.remove(id) }
                }
            } catch {
                // Best-effort: authorization or store errors just leave the
                // bell un-checked; the meeting-page path surfaces errors.
            }
        }
    }

    // MARK: - Actions

    private func loadItems() async {
        isLoading = true
        defer { isLoading = false }

        openItems = (try? await actionItemRepo.allOpenItems()) ?? []

        // Fetch meeting details for grouping headers
        let meetingIds = Set(openItems.map(\.meetingId))
        var meetingsMap: [String: Meeting] = [:]
        for meetingId in meetingIds {
            if let meeting = try? await appState.meetingRepository.find(id: meetingId) {
                meetingsMap[meetingId] = meeting
            }
        }
        meetings = meetingsMap
    }
}

// MARK: - Preview

// #Preview("All Action Items") {
//     AllActionItemsView()
//         .environment(AppState())
//         .frame(width: 600, height: 600)
// }

// #Preview("Empty") {
//     AllActionItemsView()
//         .environment(AppState())
//         .frame(width: 600, height: 600)
// }

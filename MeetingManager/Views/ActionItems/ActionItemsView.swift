import SwiftUI

struct ActionItemsView: View {
    let meetingId: String

    @Environment(AppState.self) private var appState
    @State private var items: [ActionItem] = []
    @State private var isLoading = true
    @State private var extractor = ActionItemExtractor()
    @State private var extractTask: Task<Void, Never>?

    private let actionItemRepo = ActionItemRepository()

    var body: some View {
        Group {
            if isLoading {
                Spacer()
                ProgressView()
                Spacer()
            } else if extractor.isProcessing {
                Spacer()
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Extracting action items...")
                        .font(.body)
                        .foregroundStyle(Color.appTextSecondary)
                }
                Spacer()
            } else if items.isEmpty {
                Spacer()
                VStack(spacing: 16) {
                    EmptyStateView(
                        icon: "checklist",
                        title: "No Action Items",
                        subtitle: "Extract action items from the meeting transcript using AI."
                    )

                    Button {
                        // EXEMPT from TaskQueue: user-initiated interactive feature scoped to this view.
                        // Results are persisted to DB by ActionItemExtractor; view reloads from DB on appear.
                        // Cancellation on view disappear is correct — user left the view.
                        extractTask = Task { await extractItems() }
                    } label: {
                        Label("Extract Action Items", systemImage: "sparkles")
                            .font(.body)
                            .fontWeight(.medium)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.appAccent)

                    if let error = extractor.lastError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                }
                Spacer()
            } else {
                itemsList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDisappear { extractTask?.cancel() }
        .task {
            await loadItems()
        }
    }

    // MARK: - Items List

    @ViewBuilder
    private var itemsList: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Text("\(items.filter { !$0.isCompleted }.count) open")
                    .font(.caption)
                    .foregroundStyle(Color.appTextTertiary)

                Spacer()

                CopyButton(
                    text: { formatItemsAsMarkdown() },
                    label: "Copy as Checklist"
                )

                Button {
                    Task { await extractItems() } // EXEMPT: same as initial extract
                } label: {
                    Label("Re-extract", systemImage: "arrow.clockwise")
                        .font(.caption)
                        .fontWeight(.medium)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()
                .foregroundStyle(Color.appSeparator)

            List {
                ForEach(items) { item in
                    actionItemRow(item)
                }
            }
            .listStyle(.plain)
        }
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
                    .strikethrough(item.isCompleted, color: Color.appTextTertiary)

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
        }
        .padding(.vertical, 4)
    }

    // MARK: - Copy

    private func formatItemsAsMarkdown() -> String {
        items.map { item in
            var line = "- [\(item.isCompleted ? "x" : " ")] \(item.title)"
            if let assignee = item.assignee, !assignee.isEmpty {
                line += " (@\(assignee))"
            }
            if let dueDate = item.dueDate {
                line += " - due \(DateFormatting.shortDate(from: dueDate))"
            }
            return line
        }.joined(separator: "\n")
    }

    // MARK: - Actions

    private func loadItems() async {
        isLoading = true
        defer { isLoading = false }
        items = (try? await actionItemRepo.itemsForMeeting(meetingId)) ?? []
    }

    private func extractItems() async {
        guard let meeting = try? await appState.meetingRepository.find(id: meetingId) else { return }

        // Build textGenerator with the app's central AI routing.
        guard let textGenerator = await appState.makeTextGenerator() else {
            extractor.lastError = "No AI configured. Enable On-Device AI in Settings → On-Device, or add a Claude API key in Settings → Claude."
            return
        }

        do {
            let extracted = try await extractor.extractActionItems(
                for: meeting,
                transcriptRepo: appState.transcriptRepository,
                actionItemRepo: actionItemRepo,
                textGenerator: textGenerator
            )
            items = extracted
        } catch {
            // lastError is already set by the extractor
        }
        // Reload to get persisted items with IDs
        await loadItems()
    }
}

// MARK: - Preview

// #Preview("Action Items") {
//     ActionItemsView(meetingId: "preview-1")
//         .environment(AppState())
//         .frame(width: 600, height: 500)
//         .background(Color.appBackground)
// }

// #Preview("Empty") {
//     ActionItemsView(meetingId: "no-items")
//         .environment(AppState())
//         .frame(width: 600, height: 500)
//         .background(Color.appBackground)
// }

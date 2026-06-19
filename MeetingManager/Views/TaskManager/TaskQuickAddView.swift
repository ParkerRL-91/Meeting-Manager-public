import SwiftUI

/// System-wide quick capture (PRJ-013 Phase 6). Free-text entry runs through the
/// deterministic `TaskQuickAddParser` (date / priority / #tags), then lands as an
/// accepted task in the **default (To Do) stage** with an "Added to To Do"
/// confirmation. Used both as a standalone surface and inside the MenuBarExtra.
///
/// `// EXEMPT: user-initiated, instant` — no network/AI on this path (the
/// AI-assisted parse is a Phase 7 add-on); a plain repository write is correct
/// here, not a TaskQueueManager job.
struct TaskQuickAddView: View {
    /// Called after a successful add so a host (e.g. the board) can refresh.
    var onAdded: ((ActionItem) -> Void)? = nil
    /// Called when the user asks to open the just-added task (deep-link).
    var onOpenTask: ((Int64) -> Void)? = nil

    @State private var text = ""
    @State private var confirmation: Confirmation?
    @FocusState private var fieldFocused: Bool

    private let repo = ActionItemRepository(database: .shared)

    private struct Confirmation: Identifiable {
        let id = UUID()
        let taskId: Int64?
        let stageName: String
        let parsedDue: Date?
        let parsedPriority: Int
        let parsedTags: [String]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            field
            if let confirmation {
                confirmationRow(confirmation)
            } else {
                hint
            }
        }
        .padding(14)
        .frame(minWidth: 320)
        .background(Color.appBackground)
        .onAppear { fieldFocused = true }
    }

    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(Color.appAccent)
            TextField("Add a task — try \"email Dana tomorrow !!\"", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($fieldFocused)
                .onSubmit { Task { await add() } }
            if !text.isEmpty {
                Button { Task { await add() } } label: {
                    Image(systemName: "return").font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.appAccent)
                .help("Add to To Do")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.appSeparator, lineWidth: 1))
    }

    private var hint: some View {
        Text("Type a date (tomorrow, Friday, this weekend), a priority (!! or \"urgent\"), or #tags. They're parsed automatically.")
            .font(.system(size: 11))
            .foregroundStyle(Color.appTextTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func confirmationRow(_ c: Confirmation) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.appSuccess)
                .font(.system(size: 13))
            VStack(alignment: .leading, spacing: 2) {
                Text("Added to \(c.stageName)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.appTextPrimary)
                if let detail = parsedDetail(c) {
                    Text(detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.appTextTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let taskId = c.taskId, let onOpenTask {
                Button("Open") { onOpenTask(taskId) }
                    .font(.system(size: 11))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.appSuccessSubtle, in: RoundedRectangle(cornerRadius: 8))
    }

    private func parsedDetail(_ c: Confirmation) -> String? {
        var parts: [String] = []
        if let due = c.parsedDue {
            parts.append("due \(due.formatted(date: .abbreviated, time: .omitted))")
        }
        if c.parsedPriority > 0 {
            let labels = ["", "low", "medium", "high", "urgent"]
            parts.append("\(labels[min(c.parsedPriority, 4)]) priority")
        }
        if !c.parsedTags.isEmpty {
            parts.append(c.parsedTags.map { "#\($0)" }.joined(separator: " "))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func add() async {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        let parsed = TaskQuickAddParser().parse(raw)

        var item = ActionItem(
            title: parsed.title,
            dueDate: parsed.dueDate,
            triageState: .accepted,
            priority: parsed.priority,
            source: "manual"
        )
        item.tags = parsed.tags
        // Land on the default stage; the repository resolves it (accept routes to
        // the default stage exactly like the inbox accept path).
        try? await repo.save(&item)
        if let id = item.id {
            try? await repo.accept(id: id)
            item = (try? await repo.find(id: id)) ?? item
        }

        let stageName = await defaultStageName()
        confirmation = Confirmation(
            taskId: item.id,
            stageName: stageName,
            parsedDue: parsed.dueDate,
            parsedPriority: parsed.priority,
            parsedTags: parsed.tags
        )
        text = ""
        fieldFocused = true
        onAdded?(item)
    }

    private func defaultStageName() async -> String {
        let stages = (try? await TaskStageRepository(database: .shared).allStages()) ?? []
        return stages.first(where: { $0.isDefault })?.name ?? "To Do"
    }
}

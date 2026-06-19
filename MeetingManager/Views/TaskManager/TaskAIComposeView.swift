import SwiftUI

/// "Create Task with AI" (PRJ-015 / TASK-111). The user describes a task in one
/// plain-English sentence ("send Joel the document by next Tuesday, every week");
/// the AI extracts a full structured task — title, due date (+ optional time),
/// recurrence, priority, tags, and (conservatively) an assignee — and presents it
/// as an editable, plain-English-annotated preview the user confirms before it's
/// created. Degrades to the deterministic `TaskQuickAddParser` parse when no AI
/// backend is configured or the AI is slow/unreachable; it never blocks creation.
///
/// `// EXEMPT: user-initiated/instant` — this is a user-driven modal whose parse
/// runs the text generator with a bounded timeout and falls back to the
/// deterministic parse; a plain repository write on confirm is correct here, not a
/// TaskQueueManager job (which is for background post-meeting work).
struct TaskAIComposeView: View {
    /// Called after a successful create so a host (the board) can refresh.
    var onAdded: ((TaskItem) -> Void)? = nil
    /// Called to deep-link the just-created task (selects it in the detail pane).
    var onOpenTask: ((Int64) -> Void)? = nil

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    private enum Phase { case input, parsing, preview }

    /// Every editable field, captured as one value so we can detect hand-edits by
    /// comparing against the snapshot taken when the AI populated the preview.
    private struct Editable: Equatable {
        var title = ""
        var hasDue = false
        var due = Date()
        var dueHasTime = false
        var isRecurring = false
        var recurInterval = 1
        var recurFreq: TaskRecurrenceRule.Frequency = .weekly
        var hasRecurEnd = false
        var recurEnd = Date()
        var priority = 0
        var tagsText = ""
        var assignee = ""
    }

    @State private var text = ""
    @State private var phase: Phase = .input
    @State private var fields = Editable()
    @State private var populatedSnapshot = Editable()
    @State private var originalSentence = ""
    @State private var aiUsed = false
    @State private var hasParsedOnce = false
    @State private var slowHint = false
    @State private var showReparseConfirm = false
    @State private var committing = false
    @State private var parseTask: Task<Void, Never>?

    @FocusState private var inputFocused: Bool

    private let repo = TaskRepository(database: .shared)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            switch phase {
            case .input: inputSection
            case .parsing: parsingSection
            case .preview: previewSection
            }
        }
        .padding(20)
        .frame(width: 460)
        .frame(maxHeight: 640)
        .background(Color.appBackground)
        .onAppear { inputFocused = true }
        .onDisappear { parseTask?.cancel() }
        .confirmationDialog(
            "Re-reading your sentence will replace the fields you changed (your text is kept).",
            isPresented: $showReparseConfirm,
            titleVisibility: .visible
        ) {
            Button("Re-read and replace", role: .destructive) { runParse() }
            Button("Keep my edits", role: .cancel) { phase = .preview }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 15))
                .foregroundStyle(Color.appAccent)
            Text("Create a task with AI")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.appTextPrimary)
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(Color.appTextTertiary)
            }
            .buttonStyle(.plain)
            .help("Close")
            .accessibilityLabel("Close")
        }
    }

    // MARK: - Input

    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField(
                "Describe a task — e.g. \"Send Joel the Q3 deck by next Tuesday, every week until end of month\"",
                text: $text,
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .lineLimit(3...6)
            .focused($inputFocused)
            .padding(12)
            .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.appSeparator, lineWidth: 1))
            .onSubmit { onCreateWithAI() }

            Text("AI pulls out the task, the due date, and whether it repeats — then you review and edit before it's created.")
                .font(.system(size: 11))
                .foregroundStyle(Color.appTextTertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button { onCreateWithAI() } label: {
                    Label("Create with AI", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    // MARK: - Parsing

    private var parsingSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Reading your task…")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.appTextSecondary)
            }
            if slowHint {
                Text("Taking a moment — Cancel now to use a quick basic version.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.appTextTertiary)
                    .transition(.opacity)
            }
            HStack {
                Spacer()
                Button("Cancel") { parseTask?.cancel() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Preview

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !aiUsed {
                        Label("AI unavailable — used a basic parse. You can still edit and create.", systemImage: "wifi.slash")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.appTextTertiary)
                    }
                    titleField
                    dueField
                    recurrenceField
                    priorityField
                    tagsField
                    assigneeField
                    if !originalSentence.isEmpty {
                        Text("Interpreted from: \u{201C}\(originalSentence)\u{201D}")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Color.appTextTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 4)
            }
            Divider().background(Color.appSeparator).padding(.vertical, 12)
            HStack(spacing: 10) {
                Button("Edit text") { phase = .input; inputFocused = true }
                Spacer()
                Button("Cancel") { dismiss() }
                Button {
                    Task { await commit() }
                } label: {
                    if committing { ProgressView().controlSize(.small) } else { Text("Create Task") }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(committing || fields.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var titleField: some View {
        VStack(alignment: .leading, spacing: 5) {
            label("Task")
            TextField("Task", text: $fields.title, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .medium))
                .lineLimit(1...3)
                .padding(10)
                .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var dueField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $fields.hasDue) { label("Due date") }
            if fields.hasDue {
                DatePicker(
                    "",
                    selection: $fields.due,
                    displayedComponents: fields.dueHasTime ? [.date, .hourAndMinute] : [.date]
                )
                .labelsHidden()
                Text(dueEcho)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.appTextTertiary)
            } else if fields.isRecurring {
                Text("Starts today — change if you like.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.appTextTertiary)
            }
        }
    }

    private var recurrenceField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $fields.isRecurring) { label("Repeats") }
            if fields.isRecurring {
                Text(recurrenceSummary)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.appAccent)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Text("Every").font(.system(size: 12)).foregroundStyle(Color.appTextSecondary)
                    Stepper(value: $fields.recurInterval, in: 1...52) {
                        Text("\(fields.recurInterval)").monospacedDigit()
                            .font(.system(size: 12)).foregroundStyle(Color.appTextPrimary)
                    }
                    .fixedSize()
                    Picker("Frequency", selection: $fields.recurFreq) {
                        ForEach(TaskRecurrenceRule.Frequency.allCases) { freq in
                            Text(freq.label).tag(freq)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Toggle(isOn: $fields.hasRecurEnd) {
                    Text("Stop after a date").font(.system(size: 12)).foregroundStyle(Color.appTextSecondary)
                }
                if fields.hasRecurEnd {
                    DatePicker("", selection: $fields.recurEnd, displayedComponents: [.date]).labelsHidden()
                }
            }
        }
    }

    private var priorityField: some View {
        VStack(alignment: .leading, spacing: 5) {
            label("Priority")
            Picker("Priority", selection: $fields.priority) {
                Text("None").tag(0)
                Text("Low").tag(1)
                Text("Medium").tag(2)
                Text("High").tag(3)
                Text("Urgent").tag(4)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
    }

    private var tagsField: some View {
        VStack(alignment: .leading, spacing: 5) {
            label("Tags")
            TextField("Comma-separated", text: $fields.tagsText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(10)
                .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var assigneeField: some View {
        VStack(alignment: .leading, spacing: 5) {
            label("Assignee")
            TextField("Who owns this task", text: $fields.assignee)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(10)
                .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 8))
            if fields.assignee.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("Left empty — a named recipient isn't the task's owner. Add an assignee if someone else owns this.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.appTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.appTextSecondary)
            .textCase(.uppercase)
    }

    // MARK: - Derived

    private var recurrenceSummary: String {
        let rule = TaskRecurrenceRule(
            frequency: fields.recurFreq,
            interval: max(1, fields.recurInterval),
            endDate: fields.hasRecurEnd ? fields.recurEnd : nil
        )
        return rule.summary(dueDate: fields.hasDue ? effectiveDue() : nil)
    }

    private var dueEcho: String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = fields.dueHasTime ? "EEE, MMM d 'at' h:mm a" : "EEE, MMM d"
        return "Due \(df.string(from: effectiveDue()))"
    }

    private func effectiveDue() -> Date {
        fields.dueHasTime ? fields.due : Calendar.current.startOfDay(for: fields.due)
    }

    // MARK: - Actions

    private func onCreateWithAI() {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        if hasParsedOnce && fields != populatedSnapshot {
            showReparseConfirm = true
        } else {
            runParse()
        }
    }

    private func runParse() {
        parseTask?.cancel()
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        phase = .parsing
        slowHint = false
        parseTask = Task {
            let hint = Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if !Task.isCancelled { await MainActor.run { withAnimation { slowHint = true } } }
            }
            let parser = TaskQuickAddParser()
            let base = parser.composeBase(raw)
            let gen = await appState.makeTextGenerator(maxOutputTokens: 512, think: false)
            let result = await parser.aiCompose(raw: raw, base: base, textGenerator: gen)
            hint.cancel()
            // Cancel mid-parse falls through to the deterministic base preview — never a dead end.
            populate(from: Task.isCancelled ? base : result, raw: raw)
            phase = .preview
        }
    }

    private func populate(from r: TaskQuickAddParser.ComposeResult, raw: String) {
        var e = Editable()
        e.title = r.title
        if let d = r.dueDate {
            e.hasDue = true
            e.due = d
            e.dueHasTime = r.dueHasTime
        }
        if let rule = r.recurrence {
            e.isRecurring = true
            e.recurInterval = max(1, rule.interval)
            e.recurFreq = rule.frequency
            if let end = rule.endDate { e.hasRecurEnd = true; e.recurEnd = end }
        }
        e.priority = r.priority
        e.tagsText = r.tags.joined(separator: ", ")
        e.assignee = r.assignee ?? ""
        fields = e
        populatedSnapshot = e
        aiUsed = r.aiUsed
        originalSentence = raw
        hasParsedOnce = true
    }

    private func commit() async {
        guard !committing else { return }
        let cleanTitle = fields.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return }
        committing = true
        defer { committing = false }

        var item = TaskItem(
            title: cleanTitle,
            dueDate: fields.hasDue ? effectiveDue() : nil,
            triageState: .accepted,
            priority: fields.priority,
            source: "manual"
        )
        item.tags = parsedTags()
        if fields.isRecurring {
            let rule = TaskRecurrenceRule(
                frequency: fields.recurFreq,
                interval: max(1, fields.recurInterval),
                endDate: fields.hasRecurEnd ? fields.recurEnd : nil
            )
            item.recurrenceRuleJSON = rule.encoded()
            // A recurring task with no due date gets a visible start anchor.
            if item.dueDate == nil { item.dueDate = Calendar.current.startOfDay(for: Date()) }
        }
        let name = fields.assignee.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            item.assignee = name
            // Person linkage at commit (view/@MainActor), not in the pure parser. Single
            // unambiguous match only — matches() is first-name-keyed, so >1 hit stays unlinked.
            let people = (try? await PersonRepository(database: .shared).allPersons()) ?? []
            let hits = people.filter { $0.matches(participant: name) }
            if hits.count == 1 { item.assigneePersonId = hits[0].id }
        }

        try? await repo.save(&item)
        guard let id = item.id else { return }
        try? await repo.accept(id: id)
        item = (try? await repo.find(id: id)) ?? item
        onAdded?(item)
        onOpenTask?(id)
        dismiss()
    }

    private func parsedTags() -> [String] {
        fields.tagsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

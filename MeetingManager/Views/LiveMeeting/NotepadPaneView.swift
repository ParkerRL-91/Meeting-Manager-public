import SwiftUI
import os

/// Right pane: free-form text editor for meeting notes with auto-save.
struct NotepadPaneView: View {
    let meetingId: String
    /// Optional text to pre-populate the notepad when no existing note is found.
    var initialText: String = ""
    /// Called whenever a /action command is parsed and saved (passes the new count increment).
    var onActionCaptured: (() -> Void)? = nil

    @Environment(AppState.self) private var appState

    @State private var noteContent: String = ""
    @State private var existingNote: MeetingNote?
    @State private var saveTask: Task<Void, Never>?
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "note.text")
                    .foregroundStyle(Color.appAccent)
                Text("Notes")
                    .font(.headline)
                    .foregroundStyle(Color.appTextPrimary)
                Spacer()
                if isSaving {
                    Text("Saving...")
                        .font(.caption)
                        .foregroundStyle(Color.appTextTertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // Live Markdown editor — serif (New York) at 15pt with inline styling
            // (bold, italic, headings, bullets, quotes, code, links) applied as
            // the user types. Source mode: syntax characters stay visible.
            ZStack(alignment: .topLeading) {
                MarkdownTextEditor(
                    text: $noteContent,
                    baseFontSize: 15,
                    textColor: NSColor.labelColor,
                    insets: NSSize(width: 8, height: 8)
                )

                // Placeholder — hidden as soon as the user types anything;
                // the editor receives clicks underneath via allowsHitTesting(false).
                if noteContent.isEmpty {
                    Text("Start typing your meeting notes here…\n\nFormat with Markdown:\n# Heading   **bold**   *italic*   `code`\n- bullet · 1. numbered · - [ ] task · > quote\n\nTip: type /action to capture an action item inline")
                        .font(.system(size: 15, design: .serif))
                        .lineSpacing(4)
                        .foregroundStyle(Color.appTextTertiary)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 16)
                        .allowsHitTesting(false)
                }
            }
            .background(Color.appBackground)
        }
        .background(Color.appBackground)
        .onAppear(perform: loadNote)
        .onChange(of: noteContent) { oldValue, newValue in
            // Check for /action parsing on newline
            if newValue.count > oldValue.count && newValue.hasSuffix("\n") {
                parseActionCommandIfNeeded(in: newValue, oldContent: oldValue)
            }
            scheduleSave()
        }
        .onChange(of: initialText) { _, newValue in
            // If initialText arrives after onAppear (async load completed after view appeared),
            // append carry-forward below any existing content.
            guard !newValue.isEmpty else { return }
            if noteContent.isEmpty {
                noteContent = newValue
            } else {
                noteContent += "\n\n---\n**Open items from previous meetings:**\n" + newValue
            }
        }
        .onDisappear {
            saveTask?.cancel()
            // Perform a final synchronous-style save
            saveNoteImmediately()
        }
    }

    // MARK: - Load

    private func loadNote() {
        Task {
            do {
                if let note = try await appState.noteRepository.latestNote(meetingId: meetingId) {
                    await MainActor.run {
                        self.existingNote = note
                        if !initialText.isEmpty {
                            // Existing note — append carry-forward below rather than silently skipping
                            self.noteContent = note.content + "\n\n---\n**Open items from previous meetings:**\n" + initialText
                        } else {
                            self.noteContent = note.content
                        }
                    }
                } else if !initialText.isEmpty {
                    // No existing note — pre-populate with carry-forward content
                    await MainActor.run {
                        self.noteContent = initialText
                    }
                }
            } catch {
                Logger.database.error("Failed to load note: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Auto-save with Debounce

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return // Cancelled
            }
            await saveNote()
        }
    }

    private func saveNote() async {
        guard !noteContent.isEmpty else { return }
        await MainActor.run { isSaving = true }

        do {
            if var note = existingNote {
                note.content = noteContent
                try await appState.noteRepository.save(&note)
                await MainActor.run { self.existingNote = note }
            } else {
                var note = MeetingNote(meetingId: meetingId, content: noteContent)
                try await appState.noteRepository.save(&note)
                await MainActor.run { self.existingNote = note }
            }
        } catch {
            Logger.database.error("Failed to save note: \(error.localizedDescription, privacy: .public)")
        }

        await MainActor.run { isSaving = false }
    }

    private func saveNoteImmediately() {
        Task {
            await saveNote()
        }
    }

    // MARK: - /action Inline Parsing

    /// Called whenever a newline is typed. Looks at the line just before the newline
    /// to check for the `/action` prefix and parse it.
    private func parseActionCommandIfNeeded(in newContent: String, oldContent: String) {
        // Split into lines; the new trailing "\n" adds an empty last element
        let lines = newContent.components(separatedBy: "\n")
        // The line just completed is the second-to-last (last is the empty string after "\n")
        guard lines.count >= 2 else { return }
        let completedLine = lines[lines.count - 2]

        guard completedLine.lowercased().hasPrefix("/action") else { return }

        // Parse the /action command
        let suffix = completedLine.dropFirst("/action".count)
            .trimmingCharacters(in: .whitespaces)

        guard !suffix.isEmpty else { return }

        let parsed = ActionCommandParser.parse(suffix)
        let dueDate = NaturalLanguageDateParser.parse(parsed.dateString ?? "")
        let confirmationLine = buildConfirmationLine(
            title: parsed.title,
            assignee: parsed.assignee,
            dueDate: dueDate
        )

        // Replace the /action line in the text with the confirmation line
        var updatedLines = lines
        updatedLines[lines.count - 2] = confirmationLine
        // Prevent onChange recursion by scheduling the update asynchronously
        let updated = updatedLines.joined(separator: "\n")
        // Use Task to defer the state mutation so onChange doesn't re-enter immediately
        Task { @MainActor in
            noteContent = updated
        }

        // Save the action item
        var item = ActionItem(
            meetingId: meetingId,
            title: parsed.title,
            assignee: parsed.assignee,
            dueDate: dueDate
        )

        Task {
            do {
                try await ActionItemRepository().save(&item)
                await MainActor.run {
                    onActionCaptured?()
                }
            } catch {
                Logger.database.error("NotepadPane: failed to save /action item: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func buildConfirmationLine(title: String, assignee: String?, dueDate: Date?) -> String {
        var line = "✓ Action: \(title)"
        if let assignee = assignee, !assignee.isEmpty {
            line += " → \(assignee)"
        }
        if let dueDate = dueDate {
            let formatted = dueDate.formatted(date: .abbreviated, time: .omitted)
            line += " (due \(formatted))"
        }
        return line
    }
}

// MARK: - /action Command Parser

/// Parses the text after `/action ` into components.
/// Grammar: `[assignee:] [task] [by date]`
///
/// Examples:
///   "Sarah: finalize budget by Friday"  → assignee="Sarah", title="finalize budget", date="Friday"
///   "review the proposal"               → assignee=nil, title="review the proposal", date=nil
///   "send report by next week"          → assignee=nil, title="send report", date="next week"
enum ActionCommandParser {

    struct ParsedAction {
        let title: String
        let assignee: String?
        let dateString: String?
    }

    static func parse(_ input: String) -> ParsedAction {
        var remaining = input

        // 1. Extract assignee: if the first "word" (sequence of non-space chars) ends with ":"
        var assignee: String? = nil
        let firstSpaceIdx = remaining.firstIndex(of: " ")
        let colonIdx = remaining.firstIndex(of: ":")

        if let colon = colonIdx,
           (firstSpaceIdx == nil || colon < firstSpaceIdx!) {
            // Everything before the colon is the assignee
            let candidate = String(remaining[remaining.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            if !candidate.isEmpty {
                assignee = candidate
                // Advance past "colon + optional space"
                let afterColon = remaining.index(after: colon)
                remaining = String(remaining[afterColon...]).trimmingCharacters(in: .whitespaces)
            }
        }

        // 2. Extract " by <date>" suffix (case-insensitive)
        var dateString: String? = nil
        let byKeywords = [" by "]
        for keyword in byKeywords {
            if let byRange = remaining.range(of: keyword, options: .caseInsensitive) {
                let taskPart = String(remaining[remaining.startIndex..<byRange.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
                let datePart = String(remaining[byRange.upperBound...])
                    .trimmingCharacters(in: .whitespaces)
                if !taskPart.isEmpty {
                    remaining = taskPart
                    dateString = datePart.isEmpty ? nil : datePart
                    break
                }
            }
        }

        let title = remaining.trimmingCharacters(in: .whitespaces)
        return ParsedAction(
            title: title.isEmpty ? input : title,
            assignee: assignee,
            dateString: dateString
        )
    }
}

// MARK: - Preview

// #Preview {
//     NotepadPaneView(meetingId: "preview-123")
//         .frame(width: 350, height: 500)
//         .environment(AppState())
// }

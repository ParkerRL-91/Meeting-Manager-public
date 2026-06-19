import SwiftUI

/// A brief first-run tour of the task manager (PRJ-013 Phase 6). One card per
/// surface — Inbox, Board, Today, Quick-add, MenuBarExtra — so the novel
/// triage-gate concept (AI tasks are reviewed before they become real) is
/// discoverable. Shown once, gated by a UserDefaults flag; "Skip" and "Done" both
/// dismiss and set the flag.
struct TaskTourView: View {
    /// Called when the tour is finished or skipped.
    let onFinish: () -> Void

    @State private var page = 0

    private let cards: [(icon: String, title: String, body: String)] = [
        ("tray", "AI tasks land in the Inbox first",
         "Action items found in your meetings arrive in the Inbox for review. They aren't real tasks until you accept them, so nothing clutters your board automatically."),
        ("rectangle.split.3x1", "Accepted tasks live on the Board",
         "The Board is a Kanban view with configurable stages. Move cards by drag, by the ⌃⌘← / ⌃⌘→ shortcuts, by the right-click menu, or with VoiceOver."),
        ("calendar", "Today groups what's due",
         "The Today view shows overdue, due-today, and upcoming tasks, plus a Someday section for undated ones. Snooze a task by +1 day or to this weekend without opening it."),
        ("plus.circle", "Quick-add understands plain text",
         "Type a task like \"email Dana tomorrow !!\" and the date and priority are parsed automatically. Quick-add lands the task in your To Do stage."),
        ("menubar.arrow.up.rectangle", "Capture from the menu bar",
         "The task icon in your menu bar opens quick-add from anywhere, so you can capture a task without switching to the app first.")
    ]

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            card
            Spacer(minLength: 0)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
    }

    private var card: some View {
        let c = cards[page]
        return VStack(spacing: 14) {
            Image(systemName: c.icon)
                .font(.system(size: 44))
                .foregroundStyle(Color.appAccent)
            Text("Step \(page + 1) of \(cards.count)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.appTextTertiary)
            Text(c.title)
                .font(.title2).fontWeight(.semibold)
                .foregroundStyle(Color.appTextPrimary)
                .multilineTextAlignment(.center)
            Text(c.body)
                .font(.body)
                .foregroundStyle(Color.appTextSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 380)
        .padding(28)
        .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.appSeparator, lineWidth: 1))
        .padding(.horizontal, 24)
    }

    private var footer: some View {
        HStack {
            Button("Skip") { onFinish() }
                .foregroundStyle(Color.appTextSecondary)
            Spacer()
            HStack(spacing: 5) {
                ForEach(0..<cards.count, id: \.self) { i in
                    Circle()
                        .fill(i == page ? Color.appAccent : Color.appSeparator)
                        .frame(width: 6, height: 6)
                }
            }
            Spacer()
            if page < cards.count - 1 {
                Button("Next") { withAnimation { page += 1 } }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Done") { onFinish() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
    }
}

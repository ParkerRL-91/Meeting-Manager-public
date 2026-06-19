import SwiftUI

/// Top-level container for the user task manager (PRJ-013). For now it surfaces
/// the triage Inbox; the Kanban board + Today/All tabs are added in Phase 3.
struct TaskManagerRootView: View {
    var body: some View {
        TaskTriageInboxView()
    }
}

import SwiftUI

/// Presentation model for a note draft that survived a session which ended
/// before SQLite could commit. Built at launch by `AppState` from the sidecar
/// files `NoteDraftStore` writes per keystroke.
struct RecoverableDraft: Identifiable {
    let meetingId: String
    let meetingTitle: String
    let content: String
    let modifiedAt: Date

    var id: String { meetingId }
}

/// Startup recovery panel listing every meeting whose sidecar note draft
/// diverged from its stored note. Per-draft Restore / Discard. Dismissible:
/// closing without acting leaves the sidecars on disk, so the per-meeting
/// recovery in `NotepadPaneView.loadNote` still fires when the user reopens
/// that meeting, and this panel re-appears on the next launch.
struct DraftRecoverySheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(appState.recoverableDrafts) { draft in
                        DraftRecoveryRow(draft: draft)
                        if draft.id != appState.recoverableDrafts.last?.id {
                            Divider().padding(.leading, 16)
                        }
                    }
                }
            }

            Divider()

            footer
        }
        .frame(width: 480, height: 440)
        .background(Color.appBackground)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.counterclockwise.circle.fill")
                .font(.title2)
                .foregroundStyle(Color.appAccent)
            VStack(alignment: .leading, spacing: 3) {
                Text("We recovered unsaved notes")
                    .font(.headline)
                    .foregroundStyle(Color.appTextPrimary)
                Text("These meetings have note drafts that were never saved to the database. Restore the ones you want to keep, or discard the rest.")
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Dismiss") { dismiss() }
                .buttonStyle(.plain)
                .font(.callout)
                .foregroundStyle(Color.appTextSecondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// One meeting's recoverable draft: title, when it was last edited, a short
/// preview of the unsaved content, and the Restore / Discard actions.
private struct DraftRecoveryRow: View {
    @Environment(AppState.self) private var appState
    let draft: RecoverableDraft

    @State private var isRestoring = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.appTextPrimary)
                    .lineLimit(1)
                Text("Edited \(draft.modifiedAt.formatted(.relative(presentation: .named)))")
                    .font(.caption2)
                    .foregroundStyle(Color.appTextTertiary)
                Text(preview)
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            VStack(spacing: 6) {
                Button {
                    isRestoring = true
                    Task { await appState.restoreDraft(draft) }
                } label: {
                    Text("Restore").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.appAccent)
                .disabled(isRestoring)

                Button {
                    appState.discardDraft(draft)
                } label: {
                    Text("Discard").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(isRestoring)
            }
            .frame(width: 92)
        }
        .padding(16)
    }

    private var displayTitle: String {
        let trimmed = draft.meetingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled meeting" : trimmed
    }

    private var preview: String {
        draft.content
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

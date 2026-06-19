import SwiftUI

/// PRJ-014 Phase 4 — the unified "Sources" panel shown beneath an AI answer.
///
/// Two clearly-labeled groups:
///   - **"From your meetings"** — the existing per-surface meeting chips, passed in
///     via `meetingChips` so each surface keeps its own styling unchanged. This view
///     owns nothing about them except the group label.
///   - **"From your Knowledge Base"** — the new KB refs as named, *un-numbered* chips
///     (no `[n]` markers, to avoid colliding with the meeting `[n]`), under the honest
///     label "Context from your Knowledge Base".
///
/// Honest framing: the KB chips are the documents fed to the model as background, NOT a
/// claim the model quoted them — hence the label + tooltip. Clicking a chip deep-links
/// into the read-only KB viewer via `AppState.selectedKBPath`.
///
/// The KB group renders only when `kbSources` is non-empty. The meeting group renders
/// only when `meetingChips` produces content; an entirely empty panel collapses to nothing.
struct KBReferencesView: View {
    @Environment(AppState.self) private var appState

    let kbSources: [KBSourceRef]
    /// The surface's own meeting chips, rendered verbatim. Pass `nil` when a surface has
    /// no meeting-chip concept (summary, daily brief).
    let meetingChips: AnyView?

    init(kbSources: [KBSourceRef], @ViewBuilder meetingChips: () -> some View) {
        self.kbSources = kbSources
        self.meetingChips = AnyView(meetingChips())
    }

    init(kbSources: [KBSourceRef]) {
        self.kbSources = kbSources
        self.meetingChips = nil
    }

    var body: some View {
        if !kbSources.isEmpty || meetingChips != nil {
            VStack(alignment: .leading, spacing: 10) {
                if let meetingChips {
                    group(label: "From your meetings", help: nil) {
                        meetingChips
                    }
                }
                if !kbSources.isEmpty {
                    group(
                        label: "Context from your Knowledge Base",
                        help: "These documents were given to the AI as background for this answer."
                    ) {
                        FlowLayout(spacing: 6) {
                            ForEach(kbSources) { ref in
                                kbChip(ref)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func group(label: String, help: String?, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.appTextTertiary)
                    .textCase(.uppercase)
                    .tracking(0.5)
                if let help {
                    Image(systemName: "info.circle")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.appTextTertiary)
                        .help(help)
                }
            }
            content()
        }
    }

    private func kbChip(_ ref: KBSourceRef) -> some View {
        Button {
            openKBSource(ref)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "doc.text")
                    .font(.system(size: 9))
                Text(ref.fileName)
                    .font(.caption2)
                    .lineLimit(1)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.appAccentSubtle)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.appAccent)
        .help(ref.relativePath)
    }

    /// Resolve the stored relative path against the live KB root and deep-link the
    /// read-only viewer. The browser's `onChange(of: selectedKBPath)` (Phase 1/2)
    /// consumes the absolute path through the unsaved-edit guard. If no root is
    /// configured the link is a no-op (the KB sidebar item is hidden anyway).
    private func openKBSource(_ ref: KBSourceRef) {
        guard let root = KnowledgeBaseService.shared.rootURL else { return }
        let absolute = root.appendingPathComponent(ref.relativePath).path
        appState.sidebarDestination = .knowledgeBase
        appState.selectedKBPath = absolute
    }
}

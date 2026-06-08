import SwiftUI

/// Post-recording Notes tab: a Raw | Enhanced segmented toggle wrapping the
/// existing read-only notes view and the AI-enhanced view. Kept as an in-tab
/// segmented control rather than a new top-level `DetailTab` so the tab strip
/// and ⌘-number shortcuts don't churn (PRJ-007, ADR-013).
///
///   - **Raw** is the existing `NotesReviewView` — the user's notes exactly as
///     captured, untouched.
///   - **Enhanced** is `EnhancedNotesView` — the polished, structure-preserving
///     rewrite, generated on demand via the `.enhanceNotes` task.
struct NotesTabView: View {
    let meetingId: String

    private enum Mode: String, CaseIterable {
        case raw, enhanced
        var label: String {
            switch self {
            case .raw: return "Raw"
            case .enhanced: return "Enhanced"
            }
        }
    }

    @State private var mode: Mode = .raw

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 4)

            switch mode {
            case .raw:
                NotesReviewView(meetingId: meetingId)
            case .enhanced:
                EnhancedNotesView(meetingId: meetingId)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

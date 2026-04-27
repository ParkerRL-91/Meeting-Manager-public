import SwiftUI

/// Meeting type chip picker. Shown either inline (expanded prep card)
/// or as a quick sheet before starting a new ad-hoc meeting.
///
/// - When `compact` is true the picker renders as a horizontally scrollable single-row
///   chip strip suitable for embedding in cards/details.
/// - When `compact` is false the picker renders as a 2-column grid with a header and
///   a "Skip" button — appropriate for sheet presentation.
struct MeetingTemplatePickerView: View {
    /// Optional binding to the current meeting's templateId. Setting it persists.
    @Binding var selectedTemplateId: String?
    var onPick: (String?) -> Void = { _ in }
    var compact: Bool = false  // true → 1-row inline chips, false → grid sheet

    @Environment(\.dismiss) private var dismiss

    /// Built-in templates surfaced as quick-pick chips. Keep ids stable — they may be
    /// referenced from `RecordingControlBar` and persisted on `Meeting.templateId`.
    static let templates: [(id: String, label: String, icon: String)] = [
        ("standard", "Standard", "doc.text"),
        ("oneOnOne", "1:1", "person.2"),
        ("standup", "Standup", "person.3"),
        ("clientCall", "Client Call", "briefcase"),
        ("interview", "Interview", "questionmark.bubble"),
        ("brainstorm", "Brainstorm", "lightbulb"),
    ]

    var body: some View {
        if compact {
            compactBody
        } else {
            sheetBody
        }
    }

    // MARK: - Compact (inline)

    private var compactBody: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Self.templates, id: \.id) { template in
                    chip(id: template.id, label: template.label, icon: template.icon)
                }
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - Sheet (grid)

    private var sheetBody: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("What kind of meeting is this?")
                    .font(.headline)
                    .foregroundStyle(Color.appTextPrimary)
                Text("Pick a template to shape the AI summary. You can change it later.")
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)
            }

            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                spacing: 10
            ) {
                ForEach(Self.templates, id: \.id) { template in
                    chip(id: template.id, label: template.label, icon: template.icon, large: true)
                }
            }

            HStack {
                Spacer()
                Button("Skip") {
                    onPick(nil)
                    dismiss()
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
        }
        .padding(20)
        .frame(minWidth: 360)
    }

    // MARK: - Chip

    @ViewBuilder
    private func chip(id: String, label: String, icon: String, large: Bool = false) -> some View {
        let isSelected = (selectedTemplateId == id)

        Button {
            selectedTemplateId = id
            onPick(id)
            if !compact {
                dismiss()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(large ? .body : .caption)
                Text(label)
                    .font(large ? .subheadline.weight(.medium) : .caption.weight(.medium))
            }
            .foregroundStyle(isSelected ? Color.appAccent : Color.appTextSecondary)
            .padding(.horizontal, large ? 14 : 10)
            .padding(.vertical, large ? 10 : 6)
            .frame(maxWidth: large ? .infinity : nil, alignment: large ? .leading : .center)
            .background(
                Capsule()
                    .fill(isSelected ? Color.appAccent.opacity(0.15) : Color.clear)
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        isSelected ? Color.appAccent.opacity(0.4) : Color.appTextTertiary.opacity(0.3),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Helpers shared with RecordingControlBar

extension MeetingTemplatePickerView {
    /// Lookup the human label for a template id. Returns nil for unknown ids.
    static func label(for id: String) -> String? {
        templates.first(where: { $0.id == id })?.label
    }

    /// Lookup the SF Symbol for a template id. Returns nil for unknown ids.
    static func icon(for id: String) -> String? {
        templates.first(where: { $0.id == id })?.icon
    }
}

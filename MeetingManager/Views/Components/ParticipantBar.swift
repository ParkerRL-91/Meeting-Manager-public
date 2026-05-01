import SwiftUI

// MARK: - Participant Bar (shared component)

/// Horizontal row of participant avatars + names, displayed at the top of meeting views.
/// Tapping a participant triggers `onTap` with the participant's name.
///
/// When `onAddParticipant` is provided, an "Add" chip is rendered on the
/// right of the row. Clicking it opens a popover with a name field.
/// On submit, the closure is called with the trimmed name. The caller is
/// responsible for persisting the addition to the meeting record.
struct ParticipantBar: View {
    let participants: [String]
    var onTap: ((String) -> Void)?
    var onAddParticipant: ((String) -> Void)?

    @State private var showAddPopover = false
    @State private var newName: String = ""

    var body: some View {
        // Always render the bar when an add-callback is provided so users
        // can populate an empty participants list (e.g. ad-hoc meetings).
        if !participants.isEmpty || onAddParticipant != nil {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "person.2.fill")
                        .font(.caption)
                        .foregroundStyle(Color.appTextTertiary)
                    Text("Participants")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.appTextTertiary)
                }

                FlowLayout(spacing: 6) {
                    ForEach(participants, id: \.self) { name in
                        ParticipantChip(name: name) {
                            onTap?(name)
                        }
                    }
                    if onAddParticipant != nil {
                        AddParticipantChip(isOpen: $showAddPopover, name: $newName) { trimmed in
                            onAddParticipant?(trimmed)
                            newName = ""
                            showAddPopover = false
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }
}

// MARK: - Add Participant Chip

/// "+ Add" chip with popover. Caller passes a closure that handles the
/// submission. The chip itself manages its own popover state but the
/// text field is bound to a parent-owned `@State` so the parent can
/// clear it after a successful add.
private struct AddParticipantChip: View {
    @Binding var isOpen: Bool
    @Binding var name: String
    let onSubmit: (String) -> Void

    var body: some View {
        Button { isOpen = true } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.caption)
                    .foregroundStyle(Color.appAccent)
                Text("Add")
                    .font(.subheadline)
                    .foregroundStyle(Color.appAccent)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .overlay(
                Capsule().strokeBorder(Color.appAccent.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3]))
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Add participant")
                    .font(.subheadline.weight(.semibold))
                TextField("Name or email", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                    .onSubmit {
                        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty { onSubmit(trimmed) }
                    }
                HStack {
                    Spacer()
                    Button("Cancel") { isOpen = false }
                        .keyboardShortcut(.cancelAction)
                    Button("Add") {
                        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty { onSubmit(trimmed) }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(14)
        }
    }
}

// MARK: - Participant Chip

private struct ParticipantChip: View {
    let name: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                InitialsAvatar(name: name, size: 22)
                Text(name)
                    .font(.subheadline)
                    .foregroundStyle(Color.appTextPrimary)
                    .lineLimit(1)
            }
            .padding(.trailing, 8)
            .padding(.vertical, 3)
            .background(Color.appSurfaceSecondary.opacity(0.5))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Flow Layout (wrapping horizontal layout)

/// A simple wrapping horizontal layout for chips/tags.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layoutSubviews(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layoutSubviews(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() where index < subviews.count {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private func layoutSubviews(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            totalHeight = y + rowHeight
        }

        return (CGSize(width: maxWidth, height: totalHeight), positions)
    }
}

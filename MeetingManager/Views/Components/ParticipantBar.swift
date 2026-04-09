import SwiftUI

// MARK: - Participant Bar (shared component)

/// Horizontal row of participant avatars + names, displayed at the top of meeting views.
/// Tapping a participant triggers `onTap` with the participant's name.
struct ParticipantBar: View {
    let participants: [String]
    var onTap: ((String) -> Void)?

    var body: some View {
        if !participants.isEmpty {
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
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
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

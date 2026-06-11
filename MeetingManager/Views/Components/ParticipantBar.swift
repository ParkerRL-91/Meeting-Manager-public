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
    @State private var showAll = false

    /// Max chips shown in collapsed state. Keeps the bar to ~1 row on
    /// most window widths.
    private let collapsedLimit = 8

    /// Pure ranking so the matching rules are unit-testable: full-name
    /// prefix beats word prefix ("par" → "Parker Smith" over "Joel Parker")
    /// beats name contains beats alias/email prefix beats alias contains.
    /// Ties resolve alphabetically; people already on the meeting are out.
    static func rankSuggestions(
        query: String,
        people: [Person],
        excludedKeys: Set<String>,
        limit: Int = 6
    ) -> [Person] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        var scored: [(person: Person, rank: Int)] = []
        for person in people {
            guard !excludedKeys.contains(VocativeMiningService.canonicalKey(for: person.canonicalName)) else { continue }
            let nameLower = person.canonicalName.lowercased()
            let rank: Int
            if nameLower.hasPrefix(q) {
                rank = 0
            } else if nameLower.split(separator: " ").contains(where: { $0.hasPrefix(q) }) {
                rank = 1
            } else if nameLower.contains(q) {
                rank = 2
            } else if person.aliases.contains(where: { $0.lowercased().hasPrefix(q) }) {
                rank = 3
            } else if person.aliases.contains(where: { $0.lowercased().contains(q) }) {
                rank = 4
            } else {
                continue
            }
            scored.append((person, rank))
        }
        return scored
            .sorted { ($0.rank, $0.person.canonicalName) < ($1.rank, $1.person.canonicalName) }
            .prefix(limit)
            .map(\.person)
    }


    private var visibleParticipants: [String] {
        if showAll || participants.count <= collapsedLimit {
            return participants
        }
        return Array(participants.prefix(collapsedLimit))
    }

    private var hiddenCount: Int {
        max(0, participants.count - collapsedLimit)
    }

    var body: some View {
        if !participants.isEmpty || onAddParticipant != nil {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "person.2.fill")
                        .font(.caption)
                        .foregroundStyle(Color.appTextTertiary)
                    Text("Participants")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.appTextTertiary)
                    if participants.count > 1 {
                        Text("(\(participants.count))")
                            .font(.caption)
                            .foregroundStyle(Color.appTextTertiary)
                    }
                }

                FlowLayout(spacing: 6) {
                    ForEach(visibleParticipants, id: \.self) { name in
                        ParticipantChip(name: name) {
                            onTap?(name)
                        }
                    }

                    // "+N more" toggle when collapsed
                    if !showAll && hiddenCount > 0 {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { showAll = true }
                        } label: {
                            Text("+\(hiddenCount) more")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(Color.appAccent)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Color.appAccentSubtle)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }

                    // "Show less" when expanded with many participants
                    if showAll && hiddenCount > 0 {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { showAll = false }
                        } label: {
                            Text("Show less")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(Color.appTextTertiary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }

                    if onAddParticipant != nil {
                        AddParticipantChip(
                            isOpen: $showAddPopover,
                            name: $newName,
                            existingParticipants: participants
                        ) { trimmed in
                            onAddParticipant?(trimmed)
                            newName = ""
                            showAddPopover = false
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }
}

// MARK: - Add Participant Chip

/// "+ Add" chip with popover. Caller passes a closure that handles the
/// submission. The chip itself manages its own popover state but the
/// text field is bound to a parent-owned `@State` so the parent can
/// clear it after a successful add.
///
/// As the user types, matching people from the directory (calendar
/// attendees, imported Contacts — the `person` table) appear below the
/// field; clicking one submits it directly. People already on the meeting
/// are excluded via the same canonical-key dedup the add path uses.
private struct AddParticipantChip: View {
    @Binding var isOpen: Bool
    @Binding var name: String
    let existingParticipants: [String]
    let onSubmit: (String) -> Void

    /// Person directory, loaded once per popover open (the table is small —
    /// hundreds of rows — so in-memory filtering per keystroke is instant).
    @State private var directory: [Person] = []

    private var suggestions: [Person] {
        ParticipantBar.rankSuggestions(
            query: name,
            people: directory,
            excludedKeys: Set(existingParticipants.map { VocativeMiningService.canonicalKey(for: $0) })
        )
    }

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

                if !suggestions.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(suggestions) { person in
                            Button {
                                onSubmit(person.canonicalName)
                            } label: {
                                HStack(spacing: 8) {
                                    InitialsAvatar(name: person.canonicalName, size: 20)
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(person.canonicalName)
                                            .font(.subheadline)
                                            .foregroundStyle(Color.appTextPrimary)
                                            .lineLimit(1)
                                        if let email = person.primaryEmail {
                                            Text(email)
                                                .font(.caption)
                                                .foregroundStyle(Color.appTextTertiary)
                                                .lineLimit(1)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(width: 240, alignment: .leading)
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
            .task {
                directory = (try? await PersonRepository(database: AppDatabase.shared).allPersons()) ?? []
            }
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

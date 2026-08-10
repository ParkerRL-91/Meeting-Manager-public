import SwiftUI

/// Global "Decisions" — the Decision Log across all meetings (PRJ-017 F1,
/// triage in PRJ-020 / TASK-128). Segmented into Inbox / Confirmed / Dismissed:
/// extractions land in the Inbox as suggestions; the user confirms the ones
/// that are real (and corrects who owns them) before they flow outward to the
/// weekly digest, prep, and KB. Each row shows what was decided, the rationale,
/// who decided it, who was involved, and a transcript anchor.
struct DecisionBrowserView: View {
    @Environment(AppState.self) private var appState

    enum Tab: String, CaseIterable, Identifiable {
        case inbox, confirmed, dismissed
        var id: String { rawValue }
        var label: String {
            switch self {
            case .inbox: return "Inbox"
            case .confirmed: return "Confirmed"
            case .dismissed: return "Dismissed"
            }
        }
        var status: Decision.TriageStatus {
            switch self {
            case .inbox: return .suggested
            case .confirmed: return .active
            case .dismissed: return .dismissed
            }
        }
    }

    @State private var tab: Tab = .inbox
    @State private var didPickDefaultTab = false
    @State private var inbox: [Decision] = []
    @State private var confirmed: [Decision] = []
    @State private var dismissedRows: [Decision] = []
    @State private var people: [Person] = []
    @State private var searchText = ""
    @State private var personFilter: String?
    @State private var editing: Decision?
    @State private var isLoading = true
    @State private var errorMessage: String?

    private var meetingsById: [String: Meeting] {
        Dictionary(appState.meetings.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private var currentRows: [Decision] {
        switch tab {
        case .inbox: return inbox
        case .confirmed: return confirmed
        case .dismissed: return dismissedRows
        }
    }

    private func count(_ t: Tab) -> Int {
        switch t {
        case .inbox: return inbox.count
        case .confirmed: return confirmed.count
        case .dismissed: return dismissedRows.count
        }
    }

    private var filteredDecisions: [Decision] {
        let byPerson = Self.filterByPerson(currentRows, personName: personFilter)
        return Self.filter(byPerson, query: searchText, titleFor: { meetingsById[$0]?.title })
    }

    /// Distinct owner + involved names present in the current tab, for the
    /// person-filter menu. Case-insensitively deduped, alphabetical.
    private var personFilterCandidates: [String] {
        var seen = Set<String>()
        var names: [String] = []
        for d in currentRows {
            for raw in ([d.ownerName].compactMap { $0 } + d.involvedNames) {
                let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, seen.insert(name.lowercased()).inserted else { continue }
                names.append(name)
            }
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var grouped: [(meeting: Meeting?, meetingId: String, decisions: [Decision])] {
        let byMeeting = Dictionary(grouping: filteredDecisions, by: \.meetingId)
        return byMeeting
            .map { (meetingsById[$0.key], $0.key, $0.value) }
            .sorted { ($0.meeting?.effectiveDate ?? .distantPast) > ($1.meeting?.effectiveDate ?? .distantPast) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Decisions")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Color.appTextPrimary)
                Spacer()
                Text(headerCountLabel)
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Picker("View", selection: $tab) {
                ForEach(Tab.allCases) { t in
                    Text(count(t) > 0 ? "\(t.label) (\(count(t)))" : t.label).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 24)
            .padding(.bottom, 12)

            Divider().background(Color.appSeparator)

            if isLoading && inbox.isEmpty && confirmed.isEmpty && dismissedRows.isEmpty {
                Spacer(); ProgressView(); Spacer()
            } else if currentRows.isEmpty {
                emptyState
            } else {
                filterField
                if filteredDecisions.isEmpty {
                    noMatchesState
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            ForEach(grouped, id: \.meetingId) { group in
                                decisionGroup(group)
                            }
                        }
                        .padding(20)
                    }
                }
            }
        }
        .background(Color.appBackground)
        .task { await load() }
        // Live refresh: extraction landing new suggestions (or triage from the
        // meeting page) updates an already-open browser without re-navigation.
        .onReceive(NotificationCenter.default.publisher(for: .decisionDataDidChange)) { _ in
            Task { await load() }
        }
        .sheet(item: $editing) { decision in
            DecisionEditSheet(decision: decision,
                              participants: participants(for: decision.meetingId),
                              people: people) { updated in
                save(updated)
            }
        }
        .alert("Couldn't Update Decision", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var headerCountLabel: String {
        switch tab {
        case .inbox: return count(.inbox) == 1 ? "1 waiting for review" : "\(count(.inbox)) waiting for review"
        case .confirmed: return count(.confirmed) == 1 ? "1 confirmed" : "\(count(.confirmed)) confirmed"
        case .dismissed: return count(.dismissed) == 1 ? "1 dismissed" : "\(count(.dismissed)) dismissed"
        }
    }

    private var filterField: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Color.appTextTertiary)
                TextField("Filter by decision, person, or meeting", text: $searchText)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Filter decisions")
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Color.appTextTertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear filter")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.appSurfaceSecondary.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            personFilterMenu
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    /// Filter the tab to one person — matches when that name is the owner OR
    /// appears in the involved list of a decision (in-memory, TASK-129).
    private var personFilterMenu: some View {
        Menu {
            Button("Anyone") { personFilter = nil }
            if !personFilterCandidates.isEmpty {
                Divider()
                ForEach(personFilterCandidates, id: \.self) { name in
                    Button { personFilter = name } label: {
                        if personFilter?.caseInsensitiveCompare(name) == .orderedSame {
                            Label(name, systemImage: "checkmark")
                        } else {
                            Text(name)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "person.crop.circle")
                Text(personFilter ?? "Anyone")
                    .lineLimit(1)
            }
            .font(.caption)
            .foregroundStyle(personFilter == nil ? Color.appTextSecondary : Color.appAccent)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.appSurfaceSecondary.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(personFilterCandidates.isEmpty && personFilter == nil)
        .help("Filter to decisions a person owns or was involved in")
    }

    private var noMatchesState: some View {
        VStack(spacing: 6) {
            Spacer()
            Text("No decisions match your filter")
                .font(.subheadline)
                .foregroundStyle(Color.appTextSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "checkmark.seal")
                .font(.system(size: 44))
                .foregroundStyle(Color.appTextTertiary)
            switch tab {
            case .inbox:
                Text("No suggestions waiting for review")
                    .font(.title3)
                    .foregroundStyle(Color.appTextSecondary)
                Text("After a meeting is summarized, the decisions made in it are extracted here for you to confirm — what was decided, why, and who decided it.")
                    .font(.subheadline)
                    .foregroundStyle(Color.appTextTertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            case .confirmed:
                Text("No confirmed decisions yet")
                    .font(.title3)
                    .foregroundStyle(Color.appTextSecondary)
                if count(.inbox) > 0 {
                    Button {
                        tab = .inbox
                    } label: {
                        Text(count(.inbox) == 1
                             ? "1 suggestion is waiting for review in the Inbox."
                             : "\(count(.inbox)) suggestions are waiting for review in the Inbox.")
                    }
                    .buttonStyle(.link)
                } else {
                    Text("Confirm a suggestion from the Inbox and it appears here.")
                        .font(.subheadline)
                        .foregroundStyle(Color.appTextTertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }
            case .dismissed:
                Text("Nothing dismissed")
                    .font(.title3)
                    .foregroundStyle(Color.appTextSecondary)
                Text("Suggestions you mark as \u{201C}Not a decision\u{201D} land here. You can restore them to the Inbox.")
                    .font(.subheadline)
                    .foregroundStyle(Color.appTextTertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func decisionGroup(_ group: (meeting: Meeting?, meetingId: String, decisions: [Decision])) -> some View {
        let hasAudio = !(group.meeting?.audioFilePaths.isEmpty ?? true) && group.meeting?.audioPrunedAt == nil
        VStack(alignment: .leading, spacing: 8) {
            Button {
                appState.selectedMeetingId = group.meetingId
            } label: {
                HStack(spacing: 6) {
                    Text(group.meeting?.title ?? "Meeting")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.appAccent)
                    if let date = group.meeting?.effectiveDate {
                        Text(date.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption)
                            .foregroundStyle(Color.appTextTertiary)
                    }
                }
            }
            .buttonStyle(.plain)

            ForEach(group.decisions) { decision in
                DecisionRow(decision: decision,
                            hasAudio: hasAudio,
                            participants: participants(for: decision.meetingId),
                            people: people,
                            onOpen: { open(decision, hasAudio: hasAudio) },
                            onEdit: { editing = decision },
                            onDismiss: { dismiss(decision) },
                            onConfirm: { confirm(decision) },
                            onRestore: { restore(decision) },
                            onSetOwner: { name, personId in setOwner(decision, name: name, personId: personId) })
            }
        }
    }

    private func participants(for meetingId: String) -> [String] {
        meetingsById[meetingId]?.participantList ?? []
    }

    private func open(_ decision: Decision, hasAudio: Bool) {
        if hasAudio, let start = decision.startTime, let end = decision.endTime {
            appState.pendingPlaybackRange = (decision.meetingId, start, end)
        }
        appState.selectedMeetingId = decision.meetingId
    }

    private func dismiss(_ decision: Decision) {
        mutate(decision) { repo, id in try await repo.setDismissed(id: id, true) }
    }

    private func confirm(_ decision: Decision) {
        mutate(decision) { repo, id in try await repo.confirm(id: id) }
    }

    private func restore(_ decision: Decision) {
        mutate(decision) { repo, id in try await repo.restoreToInbox(id: id) }
    }

    private func setOwner(_ decision: Decision, name: String?, personId: String?) {
        mutate(decision) { repo, id in try await repo.setOwner(id: id, name: name, personId: personId) }
    }

    private func mutate(_ decision: Decision, _ op: @escaping (DecisionRepository, Int64) async throws -> Void) {
        guard let id = decision.id else { return }
        Task {
            do {
                try await op(DecisionRepository(database: appState.database), id)
                await load()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func save(_ decision: Decision) {
        Task {
            do {
                _ = try await DecisionRepository(database: appState.database).update(decision)
                await load()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        let repo = DecisionRepository(database: appState.database)
        inbox = (try? await repo.decisions(status: .suggested)) ?? []
        confirmed = (try? await repo.decisions(status: .active)) ?? []
        dismissedRows = (try? await repo.decisions(status: .dismissed)) ?? []
        if people.isEmpty {
            people = (try? await PersonRepository(database: appState.database).allPersons()) ?? []
        }
        // Default tab: Inbox when there's something to review, else Confirmed.
        if !didPickDefaultTab {
            didPickDefaultTab = true
            tab = inbox.isEmpty ? .confirmed : .inbox
        }
    }

    /// Restrict to decisions a person owns, is involved in, or is the target
    /// of (case-insensitive). A nil/empty name passes everything. Pure.
    static func filterByPerson(_ decisions: [Decision], personName: String?) -> [Decision] {
        guard let needle = personName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !needle.isEmpty else { return decisions }
        return decisions.filter { d in
            if let owner = d.ownerName, owner.lowercased().contains(needle) { return true }
            if let target = d.targetName, target.lowercased().contains(needle) { return true }
            return d.involvedNames.contains { $0.lowercased().contains(needle) }
        }
    }

    /// Case-insensitive match on decision title, rationale, owner, target,
    /// involved names, or the decision's meeting title. An empty query passes
    /// everything. Pure.
    static func filter(_ decisions: [Decision], query: String, titleFor: (String) -> String?) -> [Decision] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return decisions }
        return decisions.filter { d in
            if d.title.lowercased().contains(needle) { return true }
            if let r = d.rationale, r.lowercased().contains(needle) { return true }
            if let o = d.ownerName, o.lowercased().contains(needle) { return true }
            if let tg = d.targetName, tg.lowercased().contains(needle) { return true }
            if d.involvedNames.contains(where: { $0.lowercased().contains(needle) }) { return true }
            if let t = titleFor(d.meetingId), t.lowercased().contains(needle) { return true }
            return false
        }
    }
}

/// One decision row: what was decided, rationale, a correctable owner chip,
/// involved chips, a transcript anchor, and status-appropriate actions. Shared
/// by the browser and the per-meeting DecisionsSection. Suggested (unreviewed)
/// rows get a distinct tint and prominent inline Confirm / Not-a-decision
/// controls so triage can happen in one click.
struct DecisionRow: View {
    let decision: Decision
    let hasAudio: Bool
    var participants: [String] = []
    var people: [Person] = []
    let onOpen: () -> Void
    let onEdit: () -> Void
    let onDismiss: () -> Void
    var onConfirm: (() -> Void)? = nil
    var onRestore: (() -> Void)? = nil
    var onSetOwner: ((String?, String?) -> Void)? = nil

    @State private var showOwnerPicker = false

    private var canPlay: Bool { hasAudio && decision.hasAnchor }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if decision.hasAnchor {
                Button(action: onOpen) {
                    Image(systemName: canPlay ? "play.circle" : "text.magnifyingglass")
                        .font(.title3)
                        .foregroundStyle(Color.appAccent)
                }
                .buttonStyle(.plain)
                .help(canPlay ? "Open the meeting and play this moment" : "Show this moment in the transcript")
                .accessibilityLabel(canPlay ? "Play this decision" : "Show in transcript")
            } else {
                Image(systemName: "checkmark.seal")
                    .font(.title3)
                    .foregroundStyle(Color.appTextTertiary)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(decision.title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Color.appTextPrimary)
                    .textSelection(.enabled)

                if let rationale = decision.rationale, !rationale.isEmpty {
                    Text(rationale)
                        .font(.caption)
                        .foregroundStyle(Color.appTextSecondary)
                        .textSelection(.enabled)
                }

                HStack(spacing: 6) {
                    ownerChip
                    if let target = decision.targetName, !target.isEmpty {
                        Text("For \(target)")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(Color.appTextSecondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.appTextTertiary.opacity(0.15))
                            .clipShape(Capsule())
                            .help("Who or what this decision is for")
                            .accessibilityLabel("For \(target)")
                    }
                    if !decision.involvedNames.isEmpty {
                        Text(decision.involvedNames.joined(separator: ", "))
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(Color.appTextSecondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.appTextTertiary.opacity(0.15))
                            .clipShape(Capsule())
                    }
                    if let ts = decision.timestampLabel {
                        Text(ts)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(Color.appTextTertiary)
                    }
                }

                if decision.isSuggested, let onConfirm {
                    HStack(spacing: 8) {
                        Button(action: onConfirm) {
                            Label("Confirm", systemImage: "checkmark")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        Button(action: onEdit) {
                            Label("Edit", systemImage: "pencil")
                        }
                        .controlSize(.small)
                        Button(role: .destructive, action: onDismiss) {
                            Label("Not a decision", systemImage: "xmark")
                        }
                        .controlSize(.small)
                    }
                    .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)

            if !decision.isSuggested {
                Menu {
                    Button { onEdit() } label: { Label("Edit", systemImage: "pencil") }
                    if decision.isDismissed, let onRestore {
                        Button { onRestore() } label: { Label("Restore to Inbox", systemImage: "tray.and.arrow.up") }
                    } else {
                        Button(role: .destructive) { onDismiss() } label: { Label("Dismiss", systemImage: "xmark.circle") }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(Color.appTextTertiary)
                        .padding(4)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Decision actions")
                .accessibilityLabel("Decision actions")
            }
        }
        .padding(10)
        .background(rowBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(decision.isSuggested ? Color.appAccent.opacity(0.35) : Color.clear, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var rowBackground: Color {
        decision.isSuggested
            ? Color.appAccent.opacity(0.08)
            : Color.appSurfaceSecondary.opacity(0.35)
    }

    @ViewBuilder
    private var ownerChip: some View {
        let label = "Decided by \(decision.ownerName?.isEmpty == false ? decision.ownerName! : "\u{2014}")"
        if let onSetOwner {
            Button {
                showOwnerPicker = true
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "person.crop.circle")
                    Text(label)
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(Color.appAccent)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.appAccent.opacity(0.12))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Correct who made this decision")
            .accessibilityLabel(label)
            .popover(isPresented: $showOwnerPicker, arrowEdge: .bottom) {
                DecisionOwnerPicker(currentName: decision.ownerName,
                                    participants: participants,
                                    people: people) { name, personId in
                    onSetOwner(name, personId)
                    showOwnerPicker = false
                }
            }
        } else {
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(Color.appTextSecondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.appTextTertiary.opacity(0.15))
                .clipShape(Capsule())
        }
    }
}

/// Searchable owner picker — a popover, NOT a nested Menu (150+ People make
/// AppKit menus unusable). Meeting participants surface first, then all other
/// people, ranked by the live search text. Picking a name resolves a Person
/// link via the single-unambiguous `matches` rule; "Clear owner" sets nil.
struct DecisionOwnerPicker: View {
    let currentName: String?
    let participants: [String]
    let people: [Person]
    let onPick: (String?, String?) -> Void

    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var normalizedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var participantMatches: [String] {
        participants
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .filter { normalizedQuery.isEmpty || $0.lowercased().contains(normalizedQuery) }
    }

    private var peopleMatches: [Person] {
        let participantKeys = Set(participants.flatMap { name in
            people.filter { $0.matches(participant: name) }.map { $0.id }
        })
        let base = people
            .filter { !participantKeys.contains($0.id) }
            .sorted { $0.canonicalName.localizedCaseInsensitiveCompare($1.canonicalName) == .orderedAscending }
        guard !normalizedQuery.isEmpty else { return base }
        return base.filter { p in
            p.canonicalName.lowercased().contains(normalizedQuery)
                || p.aliases.contains { $0.lowercased().contains(normalizedQuery) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Decided by")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.appTextTertiary)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Color.appTextTertiary)
                TextField("Search people", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    // Keyboard completion for the highest-frequency correction
                    // gesture: type, Return picks the top match (participant
                    // matches outrank the directory).
                    .onSubmit {
                        if let name = participantMatches.first {
                            let hits = people.filter { $0.matches(participant: name) }
                            onPick(name, hits.count == 1 ? hits[0].id : nil)
                        } else if let person = peopleMatches.first {
                            onPick(person.canonicalName, person.id)
                        }
                    }
                    .onAppear { searchFocused = true }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.appSurfaceSecondary.opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if currentName?.isEmpty == false {
                        pickRow(title: "Clear owner", systemImage: "xmark.circle", accent: false) {
                            onPick(nil, nil)
                        }
                        Divider()
                    }

                    if !participantMatches.isEmpty {
                        sectionHeader("In this meeting")
                        ForEach(participantMatches, id: \.self) { name in
                            pickRow(title: name, systemImage: "person.fill", accent: true) {
                                onPick(name, resolvePersonId(for: name))
                            }
                        }
                    }

                    if !peopleMatches.isEmpty {
                        sectionHeader("Other people")
                        ForEach(peopleMatches, id: \.id) { person in
                            pickRow(title: person.canonicalName, systemImage: "person", accent: false) {
                                onPick(person.canonicalName, person.id)
                            }
                        }
                    }

                    if participantMatches.isEmpty && peopleMatches.isEmpty {
                        Text("No matching people")
                            .font(.caption)
                            .foregroundStyle(Color.appTextTertiary)
                            .padding(.vertical, 6)
                    }
                }
            }
            .frame(maxHeight: 240)
        }
        .padding(14)
        .frame(width: 280)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color.appTextTertiary)
            .padding(.top, 4)
    }

    private func pickRow(title: String, systemImage: String, accent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .foregroundStyle(accent ? Color.appAccent : Color.appTextTertiary)
                    .frame(width: 16)
                Text(title)
                    .foregroundStyle(Color.appTextPrimary)
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.vertical, 4)
            .padding(.horizontal, 4)
        }
        .buttonStyle(.plain)
    }

    /// Single-unambiguous Person link for a raw name; nil when zero or >1 match.
    private func resolvePersonId(for name: String) -> String? {
        let hits = people.filter { $0.matches(participant: name) }
        return hits.count == 1 ? hits[0].id : nil
    }
}

/// Edit a decision's title, rationale, owner, target, and involved people.
/// Saving stamps `editedAt`, which shields the row from being overwritten by
/// re-extraction.
struct DecisionEditSheet: View {
    let decision: Decision
    var participants: [String] = []
    var people: [Person] = []
    let onSave: (Decision) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var rationale: String
    @State private var involved: String
    @State private var ownerName: String
    @State private var ownerPersonId: String?
    @State private var targetName: String
    @State private var showOwnerPicker = false

    init(decision: Decision,
         participants: [String] = [],
         people: [Person] = [],
         onSave: @escaping (Decision) -> Void) {
        self.decision = decision
        self.participants = participants
        self.people = people
        self.onSave = onSave
        _title = State(initialValue: decision.title)
        _rationale = State(initialValue: decision.rationale ?? "")
        _involved = State(initialValue: decision.involvedNames.joined(separator: ", "))
        _ownerName = State(initialValue: decision.ownerName ?? "")
        _ownerPersonId = State(initialValue: decision.ownerPersonId)
        _targetName = State(initialValue: decision.targetName ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit Decision")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("Decision").font(.caption.weight(.semibold)).foregroundStyle(Color.appTextTertiary)
                TextField("What was decided", text: $title, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...3)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Rationale").font(.caption.weight(.semibold)).foregroundStyle(Color.appTextTertiary)
                TextField("Why (optional)", text: $rationale, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Decided by").font(.caption.weight(.semibold)).foregroundStyle(Color.appTextTertiary)
                Button {
                    showOwnerPicker = true
                } label: {
                    HStack {
                        Text(ownerName.isEmpty ? "Unknown" : ownerName)
                            .foregroundStyle(ownerName.isEmpty ? Color.appTextTertiary : Color.appTextPrimary)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                            .foregroundStyle(Color.appTextTertiary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.appSurfaceSecondary.opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showOwnerPicker, arrowEdge: .bottom) {
                    DecisionOwnerPicker(currentName: ownerName,
                                        participants: participants,
                                        people: people) { name, personId in
                        ownerName = name ?? ""
                        ownerPersonId = personId
                        showOwnerPicker = false
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                // Free text, not the person picker: the target is as often a
                // client, vendor, or product as it is a person.
                Text("For").font(.caption.weight(.semibold)).foregroundStyle(Color.appTextTertiary)
                TextField("Client, candidate, or product this applies to (optional)", text: $targetName)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Involved").font(.caption.weight(.semibold)).foregroundStyle(Color.appTextTertiary)
                TextField("Names, comma-separated", text: $involved)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    var updated = decision
                    updated.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    updated.normalizedKey = Decision.normalize(updated.title)
                    let r = rationale.trimmingCharacters(in: .whitespacesAndNewlines)
                    updated.rationale = r.isEmpty ? nil : r
                    let o = ownerName.trimmingCharacters(in: .whitespacesAndNewlines)
                    updated.ownerName = o.isEmpty ? nil : o
                    updated.ownerPersonId = o.isEmpty ? nil : ownerPersonId
                    let tg = targetName.trimmingCharacters(in: .whitespacesAndNewlines)
                    updated.targetName = tg.isEmpty ? nil : tg
                    updated.setInvolved(involved.components(separatedBy: ","))
                    onSave(updated)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

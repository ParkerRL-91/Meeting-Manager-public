import SwiftUI

/// Compact Decision Log list rendered inline beneath the summary's action
/// items (PRJ-017 F1). Shows the decisions extracted from this meeting — what
/// was decided, why, who was involved, and a transcript anchor — with inline
/// edit and dismiss. Hidden entirely when the meeting has no decisions.
struct DecisionsSection: View {
    let meetingId: String

    @Environment(AppState.self) private var appState
    @State private var decisions: [Decision] = []
    @State private var people: [Person] = []
    @State private var editing: Decision?
    @State private var errorMessage: String?

    private var meeting: Meeting? { appState.meetings.first(where: { $0.id == meetingId }) }

    private var hasAudio: Bool {
        guard let meeting else { return false }
        return !meeting.audioFilePaths.isEmpty && meeting.audioPrunedAt == nil
    }

    private var participants: [String] { meeting?.participantList ?? [] }

    var body: some View {
        Group {
            if !decisions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    SkimSectionLabel(kind: .decisions, title: "Decisions")
                        .padding(.bottom, 2)
                    ForEach(decisions) { decision in
                        DecisionRow(decision: decision,
                                    hasAudio: hasAudio,
                                    participants: participants,
                                    people: people,
                                    onOpen: { open(decision) },
                                    onEdit: { editing = decision },
                                    onDismiss: { dismiss(decision) },
                                    onConfirm: { confirm(decision) },
                                    onSetOwner: { name, personId in setOwner(decision, name: name, personId: personId) })
                    }
                }
            }
        }
        .task(id: meetingId) { await load() }
        .sheet(item: $editing) { decision in
            DecisionEditSheet(decision: decision,
                              participants: participants,
                              people: people) { updated in save(updated) }
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

    private func open(_ decision: Decision) {
        if hasAudio, let start = decision.startTime, let end = decision.endTime {
            appState.pendingPlaybackRange = (decision.meetingId, start, end)
        }
        appState.selectedMeetingId = decision.meetingId
    }

    private func dismiss(_ decision: Decision) {
        guard let id = decision.id else { return }
        Task {
            do {
                try await DecisionRepository(database: appState.database).setDismissed(id: id, true)
                decisions.removeAll { $0.id == id }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func confirm(_ decision: Decision) {
        guard let id = decision.id else { return }
        Task {
            do {
                try await DecisionRepository(database: appState.database).confirm(id: id)
                await load()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func setOwner(_ decision: Decision, name: String?, personId: String?) {
        guard let id = decision.id else { return }
        Task {
            do {
                try await DecisionRepository(database: appState.database).setOwner(id: id, name: name, personId: personId)
                await load()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func save(_ decision: Decision) {
        Task {
            do {
                let saved = try await DecisionRepository(database: appState.database).update(decision)
                if let idx = decisions.firstIndex(where: { $0.id == saved.id }) { decisions[idx] = saved }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func load() async {
        let repo = DecisionRepository(database: appState.database)
        decisions = (try? await repo.decisionsForMeeting(meetingId)) ?? []
        if people.isEmpty {
            people = (try? await PersonRepository(database: appState.database).allPersons()) ?? []
        }
    }
}

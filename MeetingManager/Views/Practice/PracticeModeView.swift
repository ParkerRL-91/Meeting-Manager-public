import SwiftUI

/// Practice-mode sheet (TASK-067): rehearse against a persona grounded
/// in a person's or company's recorded positions. Conversation state is
/// OWN-ed by this sheet and dies with it (review m11) — nothing here
/// touches GlobalChat history.
struct PracticeModeView: View {
    let personaName: String
    /// entityType + entityKey the persona is grounded in.
    let entityType: String
    let entityKey: String

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    private struct Turn: Identifiable {
        let id = UUID()
        let role: String      // "user" | "persona"
        var text: String
        var isPending = false
    }

    @State private var record: [(index: Int, fact: EntityFact)] = []
    @State private var turns: [Turn] = []
    @State private var draft = ""
    @State private var showSources = false
    @State private var pendingRequestId: UUID?
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Persona banner — unmistakably a simulation.
            HStack(spacing: 8) {
                Image(systemName: "theatermasks")
                    .foregroundStyle(Color.appWarning)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Simulation — practicing against \(personaName)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.appTextPrimary)
                    Text("Argues only from \(record.count) recorded position\(record.count == 1 ? "" : "s") in your meetings. Not a prediction.")
                        .font(.caption)
                        .foregroundStyle(Color.appTextTertiary)
                }
                Spacer()
                Button(showSources ? "Hide record" : "Show record") {
                    showSources.toggle()
                }
                .font(.caption)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .font(.caption)
            }
            .padding(12)
            .background(Color.appWarning.opacity(0.08))
            Divider()

            if showSources {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(record, id: \.index) { item in
                            Text("[\(item.index)] (\(item.fact.kind)) \(item.fact.text)")
                                .font(.caption)
                                .foregroundStyle(Color.appTextSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(12)
                }
                .frame(maxHeight: 160)
                .background(Color.appSurfaceSecondary.opacity(0.3))
                Divider()
            }

            if record.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Text("Nothing recorded to practice against yet.")
                        .font(.subheadline)
                        .foregroundStyle(Color.appTextSecondary)
                    Text("Positions come from extracted meeting facts — objections, questions, decisions. Summarize a meeting with \(personaName) first.")
                        .font(.caption)
                        .foregroundStyle(Color.appTextTertiary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 40)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(turns) { turn in
                                turnBubble(turn)
                                    .id(turn.id)
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: turns.count) { _, _ in
                        if let last = turns.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            Divider()
            HStack(spacing: 8) {
                TextField("Make your case…", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .focused($inputFocused)
                    .onSubmit { send() }
                    .disabled(record.isEmpty)
                Button("Send") { send() }
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || record.isEmpty)
            }
            .padding(12)
        }
        .frame(width: 640, height: 560)
        .task {
            let facts = (try? await EntityFactRepository(database: AppDatabase.shared)
                .facts(entityType: entityType, entityKey: entityKey, limit: 60)) ?? []
            record = PracticeMode.numberedRecord(facts: facts)
            inputFocused = true
        }
        .onDisappear {
            if let id = pendingRequestId { appState.interactiveAIBroker.cancel(id: id) }
        }
    }

    @ViewBuilder
    private func turnBubble(_ turn: Turn) -> some View {
        HStack {
            if turn.role == "user" { Spacer(minLength: 60) }
            VStack(alignment: .leading, spacing: 2) {
                Text(turn.role == "user" ? "You" : personaName)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.appTextTertiary)
                if turn.isPending {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(appState.interactiveAIBroker.isBlocked
                             ? "Waiting for the model…" : "Thinking…")
                            .font(.caption)
                            .foregroundStyle(Color.appTextTertiary)
                    }
                } else {
                    Text(turn.text)
                        .font(.callout)
                        .foregroundStyle(Color.appTextPrimary)
                        .textSelection(.enabled)
                }
            }
            .padding(10)
            .background(turn.role == "user" ? Color.appAccent.opacity(0.12) : Color.appSurfaceSecondary.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            if turn.role != "user" { Spacer(minLength: 60) }
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !record.isEmpty else { return }
        draft = ""
        turns.append(Turn(role: "user", text: text))
        let pendingId = UUID()
        pendingRequestId = pendingId
        var pending = Turn(role: "persona", text: "")
        pending.isPending = true
        turns.append(pending)
        let pendingTurnId = pending.id

        let systemPrompt = PracticeMode.systemPrompt(personaName: personaName, record: record)
        let history = turns.filter { !$0.isPending }.map { (role: $0.role, text: $0.text) }
        let userPrompt = PracticeMode.conversationPrompt(turns: history, personaName: personaName)
        let persona = personaName

        Task {
            guard let textGen = await appState.makeTextGenerator(
                maxOutputTokens: 700,
                activityLabel: "Practice: \(persona)"
            ) else {
                complete(turnId: pendingTurnId, text: "No AI configured — enable On-Device AI or add a Claude key in Settings.")
                return
            }
            appState.interactiveAIBroker.submit(id: pendingId, label: "Practice: \(persona)") {
                let response = (try? await textGen(systemPrompt, userPrompt)) ?? ""
                await MainActor.run {
                    complete(turnId: pendingTurnId,
                             text: response.isEmpty ? "Generation failed — try again." : response)
                }
            }
        }
    }

    private func complete(turnId: UUID, text: String) {
        guard let idx = turns.firstIndex(where: { $0.id == turnId }) else { return }
        turns[idx].text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        turns[idx].isPending = false
        pendingRequestId = nil
    }
}

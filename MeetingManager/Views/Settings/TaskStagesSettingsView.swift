import SwiftUI

/// Settings tab for configuring Kanban stages (PRJ-013 Phase 3). Add, rename,
/// reorder, recolor; choose the single default (where accepted tasks land) and the
/// single terminal (where completion moves a task); set a soft WIP limit. Deleting
/// a stage prompts the user to reassign its tasks to another stage — never a silent
/// orphaning — via `TaskStageRepository.delete(id:reassignTo:)`.
struct TaskStagesSettingsView: View {
    @State private var stages: [TaskStage] = []
    @State private var newStageName = ""
    @State private var pendingDelete: TaskStage?
    @State private var reassignTarget: Int64?

    private let repo = TaskStageRepository(database: .shared)

    private static let palette: [(name: String, hex: String)] = [
        ("Blue", "4F6CEF"), ("Green", "22C55E"), ("Amber", "F5B942"),
        ("Red", "EF4444"), ("Violet", "8B5CF6"), ("Slate", "6C6C75")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(Color.appSeparator)
            list
            Divider().background(Color.appSeparator)
            addRow
        }
        .background(Color.appBackground)
        .task { await load() }
        .confirmationDialog(
            "Delete “\(pendingDelete?.name ?? "")”?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            ForEach(reassignChoices) { target in
                Button("Move its tasks to \(target.name)") {
                    Task { await deleteStage(pendingDelete, reassignTo: target.id) }
                }
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("This stage's tasks must move somewhere. Choose where they go.")
        }
    }

    private var reassignChoices: [TaskStage] {
        stages.filter { $0.id != pendingDelete?.id }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Task Stages")
                .font(.title3).fontWeight(.semibold)
                .foregroundStyle(Color.appTextPrimary)
            Text("These are the columns on your task board. Exactly one default (where accepted tasks land) and one terminal (where completion moves a task) are required.")
                .font(.caption)
                .foregroundStyle(Color.appTextSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(Array(stages.enumerated()), id: \.element.id) { index, stage in
                    stageRow(stage, index: index)
                }
            }
            .padding(16)
        }
    }

    private func stageRow(_ stage: TaskStage, index: Int) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                colorMenu(stage)
                TextField("Stage name", text: nameBinding(stage))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.appTextPrimary)
                Spacer()
                VStack(spacing: 2) {
                    Button { Task { await move(index, by: -1) } } label: {
                        Image(systemName: "chevron.up")
                    }.buttonStyle(.plain).disabled(index == 0)
                    Button { Task { await move(index, by: 1) } } label: {
                        Image(systemName: "chevron.down")
                    }.buttonStyle(.plain).disabled(index == stages.count - 1)
                }
                .font(.system(size: 11)).foregroundStyle(Color.appTextTertiary)

                Button(role: .destructive) {
                    pendingDelete = stage
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.appTextTertiary)
                .disabled(stages.count <= 1)
                .help(stages.count <= 1 ? "At least one stage is required" : "Delete stage")
            }
            HStack(spacing: 16) {
                Toggle("Default", isOn: defaultBinding(stage))
                    .toggleStyle(.checkbox)
                    .disabled(stage.isDefault)
                Toggle("Terminal", isOn: terminalBinding(stage))
                    .toggleStyle(.checkbox)
                    .disabled(stage.isTerminal)
                Spacer()
                Text("WIP")
                    .font(.caption).foregroundStyle(Color.appTextSecondary)
                TextField("none", text: wipBinding(stage))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 52)
                    .font(.system(size: 12))
            }
            .font(.caption)
            .foregroundStyle(Color.appTextSecondary)
        }
        .padding(12)
        .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 8))
    }

    private func colorMenu(_ stage: TaskStage) -> some View {
        Menu {
            ForEach(Self.palette, id: \.hex) { entry in
                Button(entry.name) { Task { await recolor(stage, hex: entry.hex) } }
            }
            Button("None") { Task { await recolor(stage, hex: nil) } }
        } label: {
            Circle()
                .fill(stage.colorHex.flatMap { Color(hex: $0) } ?? Color.appTextTertiary)
                .frame(width: 14, height: 14)
                .overlay(Circle().stroke(Color.appSeparator, lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Stage color")
    }

    private var addRow: some View {
        HStack(spacing: 8) {
            TextField("New stage name", text: $newStageName)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
                .onSubmit { Task { await addStage() } }
            Button("Add Stage") { Task { await addStage() } }
                .disabled(newStageName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(16)
    }

    // MARK: - Bindings

    private func nameBinding(_ stage: TaskStage) -> Binding<String> {
        Binding(
            get: { stage.name },
            set: { newValue in
                var copy = stage
                copy.name = newValue
                Task { await save(copy) }
            }
        )
    }

    private func wipBinding(_ stage: TaskStage) -> Binding<String> {
        Binding(
            get: { stage.wipLimit.map(String.init) ?? "" },
            set: { newValue in
                var copy = stage
                let parsed = Int(newValue.trimmingCharacters(in: .whitespaces))
                copy.wipLimit = (parsed.map { $0 > 0 ? $0 : nil } ?? nil)
                Task { await save(copy) }
            }
        )
    }

    private func defaultBinding(_ stage: TaskStage) -> Binding<Bool> {
        Binding(
            get: { stage.isDefault },
            set: { on in if on, let id = stage.id { Task { await setDefault(id) } } }
        )
    }

    private func terminalBinding(_ stage: TaskStage) -> Binding<Bool> {
        Binding(
            get: { stage.isTerminal },
            set: { on in if on, let id = stage.id { Task { await setTerminal(id) } } }
        )
    }

    // MARK: - Mutations

    private func save(_ stage: TaskStage) async {
        var copy = stage
        try? await repo.save(&copy)
        await load()
    }

    private func recolor(_ stage: TaskStage, hex: String?) async {
        var copy = stage
        copy.colorHex = hex
        await save(copy)
    }

    private func setDefault(_ id: Int64) async {
        try? await repo.setDefault(id: id)
        await load()
    }

    private func setTerminal(_ id: Int64) async {
        try? await repo.setTerminal(id: id)
        await load()
    }

    private func move(_ index: Int, by delta: Int) async {
        let target = index + delta
        guard target >= 0, target < stages.count else { return }
        var reordered = stages
        reordered.swapAt(index, target)
        try? await repo.reorder(reordered.compactMap(\.id))
        await load()
    }

    private func addStage() async {
        let name = newStageName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        try? await repo.create(name: name)
        newStageName = ""
        await load()
    }

    private func deleteStage(_ stage: TaskStage?, reassignTo: Int64?) async {
        guard let id = stage?.id else { return }
        try? await repo.delete(id: id, reassignTo: reassignTo)
        pendingDelete = nil
        await load()
    }

    private func load() async {
        stages = (try? await repo.allStages()) ?? []
    }
}

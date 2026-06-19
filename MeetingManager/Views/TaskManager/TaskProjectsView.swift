import SwiftUI

/// The Projects tab (PRJ-013 Phase 7). Create / rename / recolor / reorder / delete
/// projects, and pick the active project filter applied to the Board and lists.
/// Deleting a project clears the link on its tasks (never deletes the tasks) via
/// `TaskProjectRepository.delete`. Project assignment on individual tasks happens
/// in `TaskDetailView`.
struct TaskProjectsView: View {
    /// The board/list project filter, owned by the root shell so a selection here
    /// scopes the other surfaces. Nil = all projects.
    @Binding var projectFilter: Int64?

    @State private var projects: [TaskProject] = []
    @State private var counts: [Int64: Int] = [:]
    @State private var newProjectName = ""
    @State private var pendingDelete: TaskProject?

    private let repo = TaskProjectRepository(database: .shared)
    private let taskRepo = TaskRepository(database: .shared)

    private static let palette: [(name: String, hex: String)] = [
        ("Blue", "4F6CEF"), ("Green", "22C55E"), ("Amber", "F5B942"),
        ("Red", "EF4444"), ("Violet", "8B5CF6"), ("Slate", "6C6C75")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(Color.appSeparator)
            content
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
            Button("Delete project", role: .destructive) {
                Task { await deleteProject(pendingDelete) }
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("The project's tasks are kept and become unassigned. This cannot be undone.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Projects group related tasks across meetings and stages.")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.appTextPrimary)
            Text("Pick a project to filter the Board, Today, and All views; assign a task to a project from its detail panel.")
                .font(.caption)
                .foregroundStyle(Color.appTextSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        if projects.isEmpty {
            EmptyStateView(
                icon: "folder",
                title: "No projects yet",
                subtitle: "Create a project below to group related tasks, then assign tasks to it from their detail panel."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(spacing: 8) {
                    allProjectsRow
                    ForEach(Array(projects.enumerated()), id: \.element.id) { index, project in
                        projectRow(project, index: index)
                    }
                }
                .padding(16)
            }
        }
    }

    private var allProjectsRow: some View {
        HStack(spacing: 10) {
            Image(systemName: projectFilter == nil ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(Color.appAccent)
            Text("All projects")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.appTextPrimary)
            Spacer()
        }
        .padding(12)
        .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture { projectFilter = nil }
    }

    private func projectRow(_ project: TaskProject, index: Int) -> some View {
        HStack(spacing: 10) {
            Button {
                projectFilter = (projectFilter == project.id) ? nil : project.id
            } label: {
                Image(systemName: projectFilter == project.id ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(Color.appAccent)
            }
            .buttonStyle(.plain)
            .help("Filter to this project")

            colorMenu(project)

            TextField("Project name", text: nameBinding(project))
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.appTextPrimary)

            if let id = project.id, let count = counts[id] {
                Text("\(count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.appTextTertiary)
                    .monospacedDigit()
            }

            Spacer(minLength: 0)

            VStack(spacing: 2) {
                Button { Task { await move(index, by: -1) } } label: {
                    Image(systemName: "chevron.up")
                }.buttonStyle(.plain).disabled(index == 0)
                Button { Task { await move(index, by: 1) } } label: {
                    Image(systemName: "chevron.down")
                }.buttonStyle(.plain).disabled(index == projects.count - 1)
            }
            .font(.system(size: 11)).foregroundStyle(Color.appTextTertiary)

            Button(role: .destructive) { pendingDelete = project } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.appTextTertiary)
            .help("Delete project (tasks are kept, unassigned)")
        }
        .padding(12)
        .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 8))
    }

    private func colorMenu(_ project: TaskProject) -> some View {
        Menu {
            ForEach(Self.palette, id: \.hex) { entry in
                Button(entry.name) { Task { await recolor(project, hex: entry.hex) } }
            }
            Button("None") { Task { await recolor(project, hex: nil) } }
        } label: {
            Circle()
                .fill(project.colorHex.flatMap { Color(hex: $0) } ?? Color.appTextTertiary)
                .frame(width: 14, height: 14)
                .overlay(Circle().stroke(Color.appSeparator, lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Project color")
    }

    private var addRow: some View {
        HStack(spacing: 8) {
            TextField("New project name", text: $newProjectName)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
                .onSubmit { Task { await addProject() } }
            Button("Add Project") { Task { await addProject() } }
                .disabled(newProjectName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(16)
    }

    // MARK: - Bindings

    private func nameBinding(_ project: TaskProject) -> Binding<String> {
        Binding(
            get: { project.name },
            set: { newValue in
                var copy = project
                copy.name = newValue
                Task { await save(copy) }
            }
        )
    }

    // MARK: - Mutations

    private func save(_ project: TaskProject) async {
        var copy = project
        try? await repo.save(&copy)
        await load()
    }

    private func recolor(_ project: TaskProject, hex: String?) async {
        var copy = project
        copy.colorHex = hex
        await save(copy)
    }

    private func move(_ index: Int, by delta: Int) async {
        let target = index + delta
        guard target >= 0, target < projects.count else { return }
        var reordered = projects
        reordered.swapAt(index, target)
        try? await repo.reorder(reordered.compactMap(\.id))
        await load()
    }

    private func addProject() async {
        let name = newProjectName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        try? await repo.create(name: name)
        newProjectName = ""
        await load()
    }

    private func deleteProject(_ project: TaskProject?) async {
        guard let id = project?.id else { return }
        try? await repo.delete(id: id)
        if projectFilter == id { projectFilter = nil }
        pendingDelete = nil
        await load()
    }

    private func load() async {
        projects = (try? await repo.allProjects()) ?? []
        let tasks = (try? await taskRepo.boardTasks()) ?? []
        var c: [Int64: Int] = [:]
        for task in tasks {
            if let pid = task.projectId { c[pid, default: 0] += 1 }
        }
        counts = c
    }
}

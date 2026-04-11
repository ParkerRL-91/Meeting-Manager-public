import SwiftUI

/// Displays all meeting templates with options to create, edit, and delete.
struct TemplateListView: View {

    @Environment(AppState.self) private var appState

    @State private var templates: [MeetingTemplate] = []
    @State private var isShowingEditor = false
    @State private var selectedTemplate: MeetingTemplate?
    @State private var isLoading = false

    private var repository: MeetingTemplateRepository {
        MeetingTemplateRepository(database: appState.database)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Meeting Templates")
                    .font(.headline)
                    .foregroundStyle(Color.appTextPrimary)
                Spacer()
                Button {
                    selectedTemplate = nil
                    isShowingEditor = true
                } label: {
                    Label("New Template", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.appAccent)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if templates.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text")
                        .font(.largeTitle)
                        .foregroundStyle(Color.appTextPrimary.opacity(0.3))
                    Text("No templates yet")
                        .foregroundStyle(Color.appTextPrimary.opacity(0.5))
                    Text("Create a template to pre-fill notes when recording starts.")
                        .font(.caption)
                        .foregroundStyle(Color.appTextPrimary.opacity(0.4))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                List {
                    ForEach(templates) { template in
                        TemplateRowView(template: template)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedTemplate = template
                                isShowingEditor = true
                            }
                            .listRowBackground(Color.appSurface)
                    }
                    .onDelete { indexSet in
                        Task { await deleteTemplates(at: indexSet) }
                    }
                }
                .listStyle(.plain)
            }
        }
        .background(Color.appSurface)
        .task { await loadTemplates() }
        .sheet(isPresented: $isShowingEditor, onDismiss: {
            Task { await loadTemplates() }
        }) {
            TemplateEditorView(template: selectedTemplate)
        }
    }

    // MARK: - Helpers

    private func loadTemplates() async {
        isLoading = true
        defer { isLoading = false }
        templates = (try? await repository.all()) ?? []
    }

    private func deleteTemplates(at indexSet: IndexSet) async {
        for index in indexSet {
            let template = templates[index]
            try? await repository.delete(template)
        }
        await loadTemplates()
    }
}

// MARK: - Row View

private struct TemplateRowView: View {
    let template: MeetingTemplate

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(template.name)
                .font(.body)
                .fontWeight(.medium)
                .foregroundStyle(Color.appTextPrimary)

            if !template.noteTemplate.isEmpty {
                Text(template.noteTemplate)
                    .font(.caption)
                    .foregroundStyle(Color.appTextPrimary.opacity(0.6))
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
        }
        .padding(.vertical, 4)
    }
}

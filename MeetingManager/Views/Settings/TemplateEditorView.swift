import SwiftUI

/// Sheet for creating or editing a meeting template.
struct TemplateEditorView: View {

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    // MARK: - Init

    let existingTemplate: MeetingTemplate?

    init(template: MeetingTemplate? = nil) {
        self.existingTemplate = template
    }

    // MARK: - State

    @State private var name: String = ""
    @State private var noteTemplate: String = ""
    @State private var selectedRecipeId: String = ""
    @State private var recipes: [Recipe] = []
    @State private var isSaving = false

    private var repository: MeetingTemplateRepository {
        MeetingTemplateRepository(database: appState.database)
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Text(existingTemplate == nil ? "New Template" : "Edit Template")
                    .font(.headline)
                    .foregroundStyle(Color.appTextPrimary)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Name field
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Name")
                            .font(.caption)
                            .foregroundStyle(Color.appTextPrimary.opacity(0.7))
                            .fontWeight(.medium)
                        TextField("e.g. Weekly 1:1", text: $name)
                            .textFieldStyle(.roundedBorder)
                    }

                    // Note template field
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Note Template")
                            .font(.caption)
                            .foregroundStyle(Color.appTextPrimary.opacity(0.7))
                            .fontWeight(.medium)
                        ZStack(alignment: .topLeading) {
                            if noteTemplate.isEmpty {
                                Text("Type your meeting note structure...")
                                    .foregroundStyle(Color.appTextPrimary.opacity(0.3))
                                    .padding(.top, 8)
                                    .padding(.leading, 4)
                            }
                            TextEditor(text: $noteTemplate)
                                .frame(minHeight: 160)
                                .scrollContentBackground(.hidden)
                                .background(Color.clear)
                        }
                        .padding(8)
                        .background(Color.appSurface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.appTextPrimary.opacity(0.2), lineWidth: 1)
                        )
                    }

                    // Recipe picker
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Linked Recipe (optional)")
                            .font(.caption)
                            .foregroundStyle(Color.appTextPrimary.opacity(0.7))
                            .fontWeight(.medium)
                        Picker("Recipe", selection: $selectedRecipeId) {
                            Text("None").tag("")
                            ForEach(recipes) { recipe in
                                Text(recipe.name).tag(recipe.id)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                }
                .padding(20)
            }

            Divider()

            // Button row
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button {
                    Task { await save() }
                } label: {
                    if isSaving {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Text("Save")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.appAccent)
                .disabled(!isValid || isSaving)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 480, height: 500)
        .background(Color.appSurface)
        .task {
            // Populate fields from existing template
            if let t = existingTemplate {
                name = t.name
                noteTemplate = t.noteTemplate
                selectedRecipeId = t.recipeId ?? ""
            }
            // Load recipes for picker
            let recipeRepo = RecipeRepository(database: appState.database)
            recipes = (try? await recipeRepo.allRecipes()) ?? []
        }
    }

    // MARK: - Save

    private func save() async {
        isSaving = true
        defer { isSaving = false }

        let recipeId = selectedRecipeId.isEmpty ? nil : selectedRecipeId

        var template = existingTemplate ?? MeetingTemplate(
            name: name,
            noteTemplate: noteTemplate,
            recipeId: recipeId
        )
        template.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        template.noteTemplate = noteTemplate
        template.recipeId = recipeId

        try? await repository.save(&template)
        dismiss()
    }
}

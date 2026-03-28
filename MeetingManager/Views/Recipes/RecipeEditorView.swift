import SwiftUI

/// A sheet for creating or editing a custom recipe.
struct RecipeEditorView: View {

    /// Pass `nil` to create a new recipe, or an existing recipe to edit it.
    let recipe: Recipe?
    var onSave: ((Recipe) -> Void)?

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var description: String = ""
    @State private var promptTemplate: String = ""
    @State private var category: RecipeCategory = .custom
    @State private var errorMessage: String?

    private var isEditing: Bool { recipe != nil }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !promptTemplate.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()
                .foregroundStyle(Color.appSeparator)

            HSplitView {
                editorPane
                    .frame(minWidth: 300)

                referencePane
                    .frame(minWidth: 180, idealWidth: 200)
            }
        }
        .frame(minWidth: 600, idealWidth: 700, minHeight: 450, idealHeight: 550)
        .background(Color.appBackground)
        .onAppear {
            if let recipe {
                name = recipe.name
                description = recipe.description
                promptTemplate = recipe.promptTemplate
                category = recipe.category
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text(isEditing ? "Edit Recipe" : "New Recipe")
                .font(.title2.bold())
                .foregroundStyle(Color.appTextPrimary)

            Spacer()

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(Color.appRecording)
            }

            Button("Cancel") {
                dismiss()
            }
            .buttonStyle(.bordered)

            Button("Save") {
                Task { await saveRecipe() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSave)
        }
        .padding()
    }

    // MARK: - Editor Pane

    private var editorPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Recipe Name", text: $name)
                .textFieldStyle(.roundedBorder)

            TextField("Description (optional)", text: $description)
                .textFieldStyle(.roundedBorder)

            Picker("Category", selection: $category) {
                ForEach(RecipeCategory.allCases, id: \.self) { cat in
                    Label(cat.displayName, systemImage: cat.icon)
                        .tag(cat)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 200)

            Text("Prompt Template")
                .font(.subheadline.bold())
                .foregroundStyle(Color.appTextPrimary)

            TextEditor(text: $promptTemplate)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color.appSurface)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.appSeparator, lineWidth: 1)
                )
        }
        .padding()
    }

    // MARK: - Reference Pane

    private var referencePane: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Available Variables")
                .font(.headline)
                .foregroundStyle(Color.appTextPrimary)

            Text("Use these placeholders in your prompt template. They will be replaced with actual meeting data at execution time.")
                .font(.caption)
                .foregroundStyle(Color.appTextSecondary)

            Divider()

            ForEach(PromptManager.availableVariables, id: \.token) { variable in
                VStack(alignment: .leading, spacing: 2) {
                    Text(variable.token)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(Color.appAccent)
                        .textSelection(.enabled)

                    Text(variable.description)
                        .font(.caption)
                        .foregroundStyle(Color.appTextSecondary)
                }
                .padding(.vertical, 4)
            }

            Spacer()

            tipSection
        }
        .padding()
        .background(Color.appSurface)
    }

    // MARK: - Tips

    private var tipSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 4) {
                Label("Tips", systemImage: "lightbulb")
                    .font(.caption.bold())
                    .foregroundStyle(Color.appWarning)

                Text("Be specific about the output format you want. Use Markdown headers, bullet points, or numbered lists in your instructions.")
                    .font(.caption2)
                    .foregroundStyle(Color.appTextSecondary)
            }
        }
    }

    // MARK: - Actions

    private func saveRecipe() async {
        errorMessage = nil
        let repo = RecipeRepository(database: appState.database)

        var recipeToSave = recipe ?? Recipe(
            name: "",
            description: "",
            promptTemplate: "",
            category: .custom
        )

        recipeToSave.name = name.trimmingCharacters(in: .whitespaces)
        recipeToSave.description = description.trimmingCharacters(in: .whitespaces)
        recipeToSave.promptTemplate = promptTemplate
        recipeToSave.category = category
        recipeToSave.isBuiltIn = false

        do {
            try await repo.save(&recipeToSave)
            onSave?(recipeToSave)
            dismiss()
        } catch {
            errorMessage = "Failed to save: \(error.localizedDescription)"
        }
    }
}

// MARK: - Preview

// #Preview("Recipe Editor") {
//     RecipeEditorView(recipe: nil)
//         .environment(AppState())
//         .frame(width: 700, height: 500)
// }

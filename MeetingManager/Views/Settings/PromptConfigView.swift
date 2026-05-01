import SwiftUI
import os

/// Settings view for managing all prompt templates — the default summary prompt,
/// built-in recipe prompts (read-only), and custom user prompts (editable).
struct PromptConfigView: View {

    // MARK: - State

    @Environment(AppState.self) private var appState

    /// All recipes loaded from the database.
    @State private var recipes: [Recipe] = []

    /// The currently selected item in the sidebar.
    @State private var selection: PromptSelection = .summaryPrompt

    /// The editable text for the currently selected prompt.
    @State private var editingTemplate: String = ""

    /// Tracks whether the current template has unsaved changes.
    @State private var hasChanges = false

    /// Controls the new-prompt sheet.
    @State private var showingNewPrompt = false

    /// Controls the live preview disclosure.
    @State private var showPreview = false

    /// Error / confirmation banner text.
    @State private var bannerMessage: String?

    /// Recipe being edited for name/category (nil = editing summary prompt).
    @State private var editingRecipeMeta: Recipe?

    /// Confirmation dialog for deleting a custom prompt.
    @State private var recipeToDelete: Recipe?

    private let promptManager = PromptManager()

    // MARK: - Body

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 200, idealWidth: 220, maxWidth: 280)

            editorArea
                .frame(minWidth: 320)
        }
        .task { await loadAll() }
        .sheet(isPresented: $showingNewPrompt) {
            NewPromptSheet { savedRecipe in
                Task {
                    await loadAll()
                    selection = .recipe(savedRecipe.id)
                }
            }
        }
        .alert("Delete Prompt?", isPresented: .init(
            get: { recipeToDelete != nil },
            set: { if !$0 { recipeToDelete = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let recipe = recipeToDelete {
                    Task { await deleteRecipe(recipe) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let r = recipeToDelete {
                Text("\"\(r.name)\" will be permanently deleted. Any saved results from this prompt will also be removed.")
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Prompts")
                    .font(.headline)
                    .foregroundStyle(Color.appTextPrimary)
                Spacer()
                Button {
                    showingNewPrompt = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Create a new prompt template")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            // Prompt list
            List(selection: $selection) {
                // Default summary prompt
                Section("Default") {
                    sidebarRow(
                        icon: "text.quote",
                        title: "Meeting Summary",
                        subtitle: "Global summary prompt",
                        tag: .summaryPrompt,
                        isBuiltIn: true
                    )
                }

                // Built-in recipes
                let builtIn = recipes.filter(\.isBuiltIn)
                if !builtIn.isEmpty {
                    Section("Built-in Templates") {
                        ForEach(builtIn) { recipe in
                            sidebarRow(
                                icon: recipe.category.icon,
                                title: recipe.name,
                                subtitle: recipe.category.displayName,
                                tag: .recipe(recipe.id),
                                isBuiltIn: true
                            )
                        }
                    }
                }

                // Custom prompts
                let custom = recipes.filter { !$0.isBuiltIn }
                if !custom.isEmpty {
                    Section("Custom") {
                        ForEach(custom) { recipe in
                            sidebarRow(
                                icon: recipe.category.icon,
                                title: recipe.name,
                                subtitle: recipe.category.displayName,
                                tag: .recipe(recipe.id),
                                isBuiltIn: false
                            )
                            .contextMenu {
                                Button(role: .destructive) {
                                    recipeToDelete = recipe
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .onChange(of: selection) { _, newValue in
                loadSelection(newValue)
            }
        }
        .background(Color.appSurface)
    }

    private func sidebarRow(
        icon: String,
        title: String,
        subtitle: String,
        tag: PromptSelection,
        isBuiltIn: Bool
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(Color.appAccent)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.callout)
                    .foregroundStyle(Color.appTextPrimary)
                    .lineLimit(1)

                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(Color.appTextTertiary)
            }

            Spacer()

            if isBuiltIn {
                Image(systemName: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(Color.appTextTertiary)
                    .help("Built-in — read only")
            }
        }
        .tag(tag)
        .contentShape(Rectangle())
    }

    // MARK: - Editor Area

    private var editorArea: some View {
        HSplitView {
            editorPane
                .frame(minWidth: 250)

            referencePane
                .frame(minWidth: 180, idealWidth: 200)
        }
    }

    private var editorPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header with name + actions
            editorHeader

            // Template editor
            TextEditor(text: $editingTemplate)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color.appSurface)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.appSeparator, lineWidth: 1)
                )
                .disabled(isCurrentSelectionBuiltIn)
                .opacity(isCurrentSelectionBuiltIn ? 0.7 : 1.0)
                .onChange(of: editingTemplate) { _, _ in
                    hasChanges = true
                }

            if isCurrentSelectionBuiltIn {
                Label("This is a built-in template and cannot be edited.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)
            }

            // Preview
            DisclosureGroup("Preview", isExpanded: $showPreview) {
                previewSection
            }
            .padding(.top, 4)

            // Banner
            if let bannerMessage {
                Text(bannerMessage)
                    .font(.caption)
                    .foregroundStyle(Color.appSuccess)
                    .transition(.opacity)
            }
        }
        .padding()
    }

    private var editorHeader: some View {
        // Layout: title block on the left (allowed to shrink — Text uses
        // .lineLimit so it truncates instead of pushing buttons off-screen).
        // Buttons on the right at fixed intrinsic size with .layoutPriority
        // so they never get truncated themselves.
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(selectedTitle)
                    .font(.title3.bold())
                    .foregroundStyle(Color.appTextPrimary)
                    .lineLimit(1)

                if let desc = selectedDescription {
                    Text(desc)
                        .font(.caption)
                        .foregroundStyle(Color.appTextSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                if selection == .summaryPrompt {
                    Button("Reset to Default") {
                        editingTemplate = DefaultPrompts.meetingSummary
                        hasChanges = true
                    }
                    .buttonStyle(.bordered)
                    .fixedSize()
                }

                if !isCurrentSelectionBuiltIn {
                    Button("Save") {
                        saveCurrentPrompt()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!hasChanges)
                    .fixedSize()
                }
            }
            .layoutPriority(1)
        }
    }

    // MARK: - Reference Pane

    private var referencePane: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Variables")
                .font(.headline)
                .foregroundStyle(Color.appTextPrimary)

            Text("Placeholders replaced with meeting data at runtime.")
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

    // MARK: - Preview Section

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sample output with placeholder data:")
                .font(.caption)
                .foregroundStyle(Color.appTextSecondary)

            ScrollView {
                Text(promptManager.previewSubstitution(template: editingTemplate))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Color.appTextPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(maxHeight: 200)
            .background(Color.appSurfaceSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .padding(.top, 4)
    }

    // MARK: - Tips

    private var tipSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 4) {
                Label("Tips", systemImage: "lightbulb")
                    .font(.caption.bold())
                    .foregroundStyle(Color.appWarning)

                Text("Use Markdown formatting for structured output. Be specific about sections you want (action items, decisions, etc.).")
                    .font(.caption2)
                    .foregroundStyle(Color.appTextSecondary)
            }
        }
    }

    // MARK: - Computed Helpers

    private var isCurrentSelectionBuiltIn: Bool {
        switch selection {
        case .summaryPrompt:
            return false
        case .recipe(let id):
            return recipes.first(where: { $0.id == id })?.isBuiltIn ?? false
        }
    }

    private var selectedTitle: String {
        switch selection {
        case .summaryPrompt:
            return "Meeting Summary"
        case .recipe(let id):
            return recipes.first(where: { $0.id == id })?.name ?? "Prompt"
        }
    }

    private var selectedDescription: String? {
        switch selection {
        case .summaryPrompt:
            return "The default prompt used when generating meeting summaries."
        case .recipe(let id):
            return recipes.first(where: { $0.id == id })?.description
        }
    }

    // MARK: - Data Loading

    private func loadAll() async {
        let repo = RecipeRepository(database: appState.database)
        recipes = (try? await repo.allRecipes()) ?? []
        loadSelection(selection)
    }

    private func loadSelection(_ sel: PromptSelection) {
        hasChanges = false
        showPreview = false
        bannerMessage = nil

        switch sel {
        case .summaryPrompt:
            editingTemplate = promptManager.loadTemplate(settings: appState.settings)
        case .recipe(let id):
            editingTemplate = recipes.first(where: { $0.id == id })?.promptTemplate ?? ""
        }
    }

    // MARK: - Save

    private func saveCurrentPrompt() {
        switch selection {
        case .summaryPrompt:
            promptManager.saveTemplate(editingTemplate)
            hasChanges = false
            flashBanner("Saved")

        case .recipe(let id):
            guard var recipe = recipes.first(where: { $0.id == id }),
                  !recipe.isBuiltIn else { return }
            recipe.promptTemplate = editingTemplate
            Task {
                let repo = RecipeRepository(database: appState.database)
                var mutable = recipe
                try? await repo.save(&mutable)
                await loadAll()
                selection = .recipe(id)
                hasChanges = false
                flashBanner("Saved")
            }
        }
    }

    private func deleteRecipe(_ recipe: Recipe) async {
        let repo = RecipeRepository(database: appState.database)
        try? await repo.delete(recipe)
        selection = .summaryPrompt
        await loadAll()
    }

    private func flashBanner(_ text: String) {
        withAnimation { bannerMessage = text }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation { bannerMessage = nil }
        }
    }
}

// MARK: - Prompt Selection

enum PromptSelection: Hashable {
    case summaryPrompt
    case recipe(String)
}

// MARK: - New Prompt Sheet

/// A compact sheet for creating a new custom prompt template.
struct NewPromptSheet: View {

    var onSave: ((Recipe) -> Void)?

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var description = ""
    @State private var category: RecipeCategory = .custom
    @State private var promptTemplate = ""
    @State private var errorMessage: String?

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !promptTemplate.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("New Prompt Template")
                    .font(.title2.bold())
                    .foregroundStyle(Color.appTextPrimary)

                Spacer()

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(Color.appRecording)
                }

                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)

                Button("Create") {
                    Task { await createPrompt() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
            }
            .padding()

            Divider()

            HSplitView {
                // Editor
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Prompt Name", text: $name)
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
                .frame(minWidth: 300)

                // Variables reference
                VStack(alignment: .leading, spacing: 12) {
                    Text("Variables")
                        .font(.headline)
                        .foregroundStyle(Color.appTextPrimary)

                    Text("Use these placeholders — they're replaced with meeting data at runtime.")
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
                }
                .padding()
                .background(Color.appSurface)
                .frame(minWidth: 180, idealWidth: 200)
            }
        }
        .frame(minWidth: 600, idealWidth: 700, minHeight: 450, idealHeight: 550)
        .background(Color.appBackground)
    }

    private func createPrompt() async {
        errorMessage = nil
        var recipe = Recipe(
            name: name.trimmingCharacters(in: .whitespaces),
            description: description.trimmingCharacters(in: .whitespaces),
            promptTemplate: promptTemplate,
            category: category,
            isBuiltIn: false
        )

        let repo = RecipeRepository(database: appState.database)
        do {
            try await repo.save(&recipe)
            onSave?(recipe)
            dismiss()
        } catch {
            errorMessage = "Failed to save: \(error.localizedDescription)"
        }
    }
}

// MARK: - Preview

// #Preview("Prompt Configuration") {
//     PromptConfigView()
//         .environment(AppState())
//         .frame(width: 800, height: 500)
// }

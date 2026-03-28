import SwiftUI

/// Displays all available recipes grouped by category, allowing the user to
/// select and run a recipe against a specific meeting.
struct RecipeListView: View {
    let meetingId: String

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var recipes: [Recipe] = []
    @State private var selectedRecipe: Recipe?
    @State private var showingEditor = false
    @State private var showingResult = false
    @State private var editingRecipe: Recipe?

    private var groupedRecipes: [(category: RecipeCategory, recipes: [Recipe])] {
        let dict = Dictionary(grouping: recipes, by: \.category)
        return RecipeCategory.allCases.compactMap { category in
            guard let items = dict[category], !items.isEmpty else { return nil }
            return (category: category, recipes: items)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()
                .foregroundStyle(Color.appSeparator)

            if recipes.isEmpty {
                emptyState
            } else {
                recipeList
            }
        }
        .frame(minWidth: 420, idealWidth: 500, minHeight: 400, idealHeight: 550)
        .background(Color.appBackground)
        .task {
            await loadRecipes()
        }
        .sheet(isPresented: $showingEditor) {
            RecipeEditorView(recipe: editingRecipe) { savedRecipe in
                Task { await loadRecipes() }
            }
        }
        .sheet(isPresented: $showingResult) {
            if let recipe = selectedRecipe {
                RecipeResultView(recipe: recipe, meetingId: meetingId)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Recipes")
                    .font(.title2.bold())
                    .foregroundStyle(Color.appTextPrimary)

                Text("Run AI-powered tasks on this meeting")
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)
            }

            Spacer()

            Button {
                editingRecipe = nil
                showingEditor = true
            } label: {
                Label("New Recipe", systemImage: "plus.circle")
            }
            .buttonStyle(.borderedProminent)

            Button("Done") {
                dismiss()
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }

    // MARK: - Recipe List

    private var recipeList: some View {
        List {
            ForEach(groupedRecipes, id: \.category) { group in
                Section {
                    ForEach(group.recipes) { recipe in
                        recipeRow(recipe)
                    }
                } header: {
                    Label(group.category.displayName, systemImage: group.category.icon)
                        .font(.subheadline.bold())
                        .foregroundStyle(Color.appTextSecondary)
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func recipeRow(_ recipe: Recipe) -> some View {
        Button {
            selectedRecipe = recipe
            showingResult = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: recipe.category.icon)
                    .foregroundStyle(Color.appAccent)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(recipe.name)
                        .font(.body)
                        .foregroundStyle(Color.appTextPrimary)

                    Text(recipe.description)
                        .font(.caption)
                        .foregroundStyle(Color.appTextSecondary)
                        .lineLimit(2)
                }

                Spacer()

                if recipe.isBuiltIn {
                    Text("Built-in")
                        .font(.caption2)
                        .foregroundStyle(Color.appTextTertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.appSurfaceSecondary)
                        .clipShape(Capsule())
                }

                Image(systemName: "play.circle")
                    .foregroundStyle(Color.appAccent)
                    .imageScale(.large)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if !recipe.isBuiltIn {
                Button {
                    editingRecipe = recipe
                    showingEditor = true
                } label: {
                    Label("Edit", systemImage: "pencil")
                }

                Button(role: .destructive) {
                    Task { await deleteRecipe(recipe) }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "text.book.closed")
                .font(.system(size: 40))
                .foregroundStyle(Color.appTextTertiary)
            Text("No recipes available")
                .font(.headline)
                .foregroundStyle(Color.appTextSecondary)
            Text("Create a custom recipe to get started.")
                .font(.caption)
                .foregroundStyle(Color.appTextTertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Actions

    private func loadRecipes() async {
        let repo = RecipeRepository(database: appState.database)
        recipes = (try? await repo.allRecipes()) ?? []
    }

    private func deleteRecipe(_ recipe: Recipe) async {
        let repo = RecipeRepository(database: appState.database)
        try? await repo.delete(recipe)
        await loadRecipes()
    }
}

// MARK: - Preview

#Preview("Recipe List") {
    RecipeListView(meetingId: "preview-1")
        .environment(AppState())
        .frame(width: 500, height: 550)
}

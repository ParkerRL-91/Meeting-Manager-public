import SwiftUI

struct PromptsStepView: View {
    @Environment(AppState.self) private var appState
    @State private var recipes: [Recipe] = []
    @State private var isLoading = true
    @State private var showingEditor = false

    private let recipeRepo = RecipeRepository(database: AppDatabase.shared)

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "text.badge.star")
                .font(.system(size: 56))
                .foregroundStyle(Color.appAccent)

            Text("Prompts")
                .font(.largeTitle)
                .fontWeight(.bold)
                .foregroundStyle(Color.appTextPrimary)

            Text("Meeting Manager comes with built-in prompt recipes for common tasks. You can also create your own.")
                .font(.body)
                .foregroundStyle(Color.appTextSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)

            if isLoading {
                ProgressView()
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(recipes) { recipe in
                            recipeCard(recipe)
                        }

                        // Create new prompt button
                        Button {
                            showingEditor = true
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "plus.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(Color.appAccent)
                                    .frame(width: 28)

                                Text("Create New Prompt")
                                    .font(.headline)
                                    .foregroundStyle(Color.appAccent)

                                Spacer()
                            }
                            .padding(12)
                            .background(Color.appAccent.opacity(0.08))
                            .cornerRadius(10)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color.appAccent.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [6, 3]))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxHeight: 280)
                .frame(maxWidth: 500)
            }

            Text("You can always create and edit prompts later in Settings.")
                .font(.caption)
                .foregroundStyle(Color.appTextTertiary)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showingEditor) {
            RecipeEditorView(recipe: nil) { newRecipe in
                recipes.append(newRecipe)
            }
            .environment(appState)
        }
        .task {
            await loadRecipes()
        }
    }

    private func recipeCard(_ recipe: Recipe) -> some View {
        HStack(spacing: 12) {
            Image(systemName: recipe.category.icon)
                .font(.title3)
                .foregroundStyle(Color.appAccent)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(recipe.name)
                    .font(.headline)
                    .foregroundStyle(Color.appTextPrimary)

                Text(recipe.description)
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)
                    .lineLimit(2)
            }

            Spacer()

            Image(systemName: recipe.isBuiltIn ? "checkmark.circle.fill" : "star.fill")
                .font(.title3)
                .foregroundStyle(recipe.isBuiltIn ? Color.appSuccess : Color.appAccent)
        }
        .padding(12)
        .background(Color.appSurface)
        .cornerRadius(10)
    }

    private func loadRecipes() async {
        isLoading = true
        defer { isLoading = false }
        recipes = (try? await recipeRepo.allRecipes()) ?? []
    }
}

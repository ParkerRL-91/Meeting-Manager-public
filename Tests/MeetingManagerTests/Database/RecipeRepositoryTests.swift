import XCTest
import GRDB
@testable import MeetingManager

final class RecipeRepositoryTests: XCTestCase {

    private var db: AppDatabase!
    private var repo: RecipeRepository!

    override func setUpWithError() throws {
        db = try TestDatabase.create()
        repo = RecipeRepository(database: db)
    }

    // MARK: - Save

    func testSave() async throws {
        var recipe = SampleData.makeRecipe(id: "r1", name: "My Recipe")
        try await repo.save(&recipe)

        let found = try await repo.find(id: "r1")
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.name, "My Recipe")
    }

    // MARK: - All Recipes

    func testAllRecipesIncludesBuiltIn() async throws {
        // Built-in recipes are seeded by migration
        let all = try await repo.allRecipes()
        XCTAssertTrue(all.count >= 6, "Should include at least the 6 built-in recipes")
    }

    func testAllRecipesIncludesCustom() async throws {
        var custom = SampleData.makeRecipe(id: "custom-1", name: "Custom")
        try await repo.save(&custom)

        let all = try await repo.allRecipes()
        let customRecipe = all.first { $0.id == "custom-1" }
        XCTAssertNotNil(customRecipe)
    }

    // MARK: - Recipes By Category

    func testRecipesByCategory() async throws {
        // Built-in recipes include email category
        let emailRecipes = try await repo.recipesByCategory(.email)
        XCTAssertTrue(emailRecipes.count >= 1)
        XCTAssertTrue(emailRecipes.allSatisfy { $0.category == .email })
    }

    func testRecipesByCategoryCustom() async throws {
        var r1 = SampleData.makeRecipe(id: "c1", name: "Custom A", category: .custom)
        var r2 = SampleData.makeRecipe(id: "c2", name: "Custom B", category: .custom)
        try await repo.save(&r1)
        try await repo.save(&r2)

        let customs = try await repo.recipesByCategory(.custom)
        // Use >= 2 so the assertion stays valid if built-in custom recipes are
        // ever added, and verify the specific records we inserted are present.
        XCTAssertGreaterThanOrEqual(customs.count, 2)
        XCTAssertTrue(customs.contains { $0.id == "c1" })
        XCTAssertTrue(customs.contains { $0.id == "c2" })
    }

    func testRecipesByCategoryEmpty() async throws {
        // Custom category should be empty before adding any custom recipes
        // (built-in recipes do not use custom category)
        let customs = try await repo.recipesByCategory(.custom)
        XCTAssertTrue(customs.isEmpty)
    }

    // MARK: - Delete

    func testDelete() async throws {
        var recipe = SampleData.makeRecipe(id: "del-1")
        try await repo.save(&recipe)

        try await repo.delete(recipe)

        let found = try await repo.find(id: "del-1")
        XCTAssertNil(found)
    }

    // MARK: - Custom Recipes

    func testCustomRecipesExcludesBuiltIn() async throws {
        var custom = SampleData.makeRecipe(id: "custom-only", name: "Custom Only", isBuiltIn: false)
        try await repo.save(&custom)

        let customs = try await repo.customRecipes()
        XCTAssertTrue(customs.allSatisfy { !$0.isBuiltIn })
        XCTAssertTrue(customs.contains { $0.id == "custom-only" })
    }

    func testCustomRecipesEmptyInitially() async throws {
        let customs = try await repo.customRecipes()
        XCTAssertTrue(customs.isEmpty)
    }

    // MARK: - Find

    func testFindExisting() async throws {
        // Built-in recipe from migration
        let found = try await repo.find(id: "builtin-follow-up-email")
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.name, "Follow-Up Email")
    }

    func testFindNonExistent() async throws {
        let found = try await repo.find(id: "does-not-exist")
        XCTAssertNil(found)
    }
}

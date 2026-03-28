import Foundation
import GRDB

final class RecipeRepository {
    private let database: AppDatabase

    init(database: AppDatabase) {
        self.database = database
    }

    func save(_ recipe: inout Recipe) async throws {
        var copy = recipe
        try await database.writer.write { db in
            try copy.save(db)
        }
        recipe = copy
    }

    func allRecipes() async throws -> [Recipe] {
        try await database.writer.read { db in
            try Recipe
                .order(Recipe.Columns.category.asc, Recipe.Columns.name.asc)
                .fetchAll(db)
        }
    }

    func recipesByCategory(_ category: RecipeCategory) async throws -> [Recipe] {
        try await database.writer.read { db in
            try Recipe
                .filter(Recipe.Columns.category == category.rawValue)
                .order(Recipe.Columns.name.asc)
                .fetchAll(db)
        }
    }

    func find(id: String) async throws -> Recipe? {
        try await database.writer.read { db in
            try Recipe.fetchOne(db, key: id)
        }
    }

    func delete(_ recipe: Recipe) async throws {
        try await database.writer.write { db in
            _ = try recipe.delete(db)
        }
    }

    func customRecipes() async throws -> [Recipe] {
        try await database.writer.read { db in
            try Recipe
                .filter(Recipe.Columns.isBuiltIn == false)
                .order(Recipe.Columns.name.asc)
                .fetchAll(db)
        }
    }
}

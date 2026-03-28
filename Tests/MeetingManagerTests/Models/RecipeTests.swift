import XCTest
import GRDB
@testable import MeetingManager

final class RecipeTests: XCTestCase {

    // MARK: - Table Name

    func testDatabaseTableName() {
        XCTAssertEqual(Recipe.databaseTableName, "recipe")
    }

    // MARK: - RecipeCategory

    func testAllCategoriesExist() {
        let expected: [RecipeCategory] = [.email, .summary, .planning, .feedback, .custom]
        XCTAssertEqual(RecipeCategory.allCases, expected)
    }

    func testCategoryDisplayNames() {
        XCTAssertEqual(RecipeCategory.email.displayName, "Email")
        XCTAssertEqual(RecipeCategory.summary.displayName, "Summary")
        XCTAssertEqual(RecipeCategory.planning.displayName, "Planning")
        XCTAssertEqual(RecipeCategory.feedback.displayName, "Feedback")
        XCTAssertEqual(RecipeCategory.custom.displayName, "Custom")
    }

    func testCategoryIcons() {
        XCTAssertEqual(RecipeCategory.email.icon, "envelope")
        XCTAssertEqual(RecipeCategory.summary.icon, "doc.text")
        XCTAssertEqual(RecipeCategory.planning.icon, "list.clipboard")
        XCTAssertEqual(RecipeCategory.feedback.icon, "bubble.left.and.text.bubble.right")
        XCTAssertEqual(RecipeCategory.custom.icon, "star")
    }

    func testCategoryRawValues() {
        XCTAssertEqual(RecipeCategory.email.rawValue, "email")
        XCTAssertEqual(RecipeCategory.summary.rawValue, "summary")
        XCTAssertEqual(RecipeCategory.planning.rawValue, "planning")
        XCTAssertEqual(RecipeCategory.feedback.rawValue, "feedback")
        XCTAssertEqual(RecipeCategory.custom.rawValue, "custom")
    }

    func testCategoryCodableRoundtrip() throws {
        for category in RecipeCategory.allCases {
            let data = try JSONEncoder().encode(category)
            let decoded = try JSONDecoder().decode(RecipeCategory.self, from: data)
            XCTAssertEqual(decoded, category)
        }
    }

    // MARK: - Recipe Init

    func testDefaultIsBuiltInFalse() {
        let recipe = Recipe(
            name: "My Recipe",
            description: "Desc",
            promptTemplate: "Template",
            category: .custom
        )
        XCTAssertFalse(recipe.isBuiltIn)
    }

    // MARK: - GRDB Roundtrip

    func testSaveAndFetch() throws {
        let db = try TestDatabase.create()

        var recipe = SampleData.makeRecipe(id: "custom-1", name: "Custom Recipe", isBuiltIn: false)
        try db.writer.write { dbConn in try recipe.save(dbConn) }

        let fetched = try db.writer.read { dbConn in
            try Recipe.fetchOne(dbConn, key: "custom-1")
        }

        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.name, "Custom Recipe")
        XCTAssertEqual(fetched?.category, .summary)
        XCTAssertFalse(fetched!.isBuiltIn)
    }

    func testBuiltInRecipe() throws {
        let db = try TestDatabase.create()

        var recipe = SampleData.makeRecipe(
            id: "builtin-test",
            name: "Built-in Recipe",
            isBuiltIn: true
        )
        try db.writer.write { dbConn in try recipe.save(dbConn) }

        let fetched = try db.writer.read { dbConn in
            try Recipe.fetchOne(dbConn, key: "builtin-test")
        }

        XCTAssertNotNil(fetched)
        XCTAssertTrue(fetched!.isBuiltIn)
    }

    // MARK: - Codable Roundtrip

    func testCodableRoundtrip() throws {
        let original = SampleData.makeRecipe(
            category: .feedback,
            isBuiltIn: true
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSinceReferenceDate
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSinceReferenceDate
        let decoded = try decoder.decode(Recipe.self, from: data)

        XCTAssertEqual(original, decoded)
    }
}

import XCTest
import GRDB
@testable import MeetingManager

final class MigrationsTests: XCTestCase {

    // MARK: - Migrations Run Without Error

    func testAllMigrationsRunSuccessfully() throws {
        // AppDatabase.empty() applies all migrations, so this verifies they work.
        let db = try AppDatabase.empty()
        XCTAssertNotNil(db)
    }

    // MARK: - Table Existence

    func testMeetingTableExists() throws {
        let db = try TestDatabase.create()
        let exists = try db.writer.read { dbConn in
            try dbConn.tableExists("meeting")
        }
        XCTAssertTrue(exists)
    }

    func testTranscriptTableExists() throws {
        let db = try TestDatabase.create()
        let exists = try db.writer.read { dbConn in
            try dbConn.tableExists("transcript")
        }
        XCTAssertTrue(exists)
    }

    func testMeetingNoteTableExists() throws {
        let db = try TestDatabase.create()
        let exists = try db.writer.read { dbConn in
            try dbConn.tableExists("meetingNote")
        }
        XCTAssertTrue(exists)
    }

    func testMeetingSummaryTableExists() throws {
        let db = try TestDatabase.create()
        let exists = try db.writer.read { dbConn in
            try dbConn.tableExists("meetingSummary")
        }
        XCTAssertTrue(exists)
    }

    func testAppSettingsTableExists() throws {
        let db = try TestDatabase.create()
        let exists = try db.writer.read { dbConn in
            try dbConn.tableExists("appSettings")
        }
        XCTAssertTrue(exists)
    }

    func testChatMessageTableExists() throws {
        let db = try TestDatabase.create()
        let exists = try db.writer.read { dbConn in
            try dbConn.tableExists("chatMessage")
        }
        XCTAssertTrue(exists)
    }

    func testActionItemTableExists() throws {
        let db = try TestDatabase.create()
        let exists = try db.writer.read { dbConn in
            try dbConn.tableExists("actionItem")
        }
        XCTAssertTrue(exists)
    }

    func testRecipeTableExists() throws {
        let db = try TestDatabase.create()
        let exists = try db.writer.read { dbConn in
            try dbConn.tableExists("recipe")
        }
        XCTAssertTrue(exists)
    }

    func testRecipeResultTableExists() throws {
        let db = try TestDatabase.create()
        let exists = try db.writer.read { dbConn in
            try dbConn.tableExists("recipeResult")
        }
        XCTAssertTrue(exists)
    }

    // MARK: - Built-In Recipes Seeded

    func testBuiltInRecipesSeeded() throws {
        let db = try TestDatabase.create()

        let count = try db.writer.read { dbConn in
            try Recipe.filter(Recipe.Columns.isBuiltIn == true).fetchCount(dbConn)
        }

        XCTAssertEqual(count, 6, "Expected 6 built-in recipes to be seeded by migration")
    }

    func testBuiltInRecipeIds() throws {
        let db = try TestDatabase.create()

        let recipes = try db.writer.read { dbConn in
            try Recipe.filter(Recipe.Columns.isBuiltIn == true).fetchAll(dbConn)
        }

        let ids = Set(recipes.map(\.id))
        let expectedIds: Set<String> = [
            "builtin-follow-up-email",
            "builtin-action-items",
            "builtin-decisions-summary",
            "builtin-meeting-brief",
            "builtin-prd-brainstorm",
            "builtin-coaching-feedback",
        ]

        XCTAssertEqual(ids, expectedIds)
    }

    func testBuiltInRecipeCategories() throws {
        let db = try TestDatabase.create()

        let recipes = try db.writer.read { dbConn in
            try Recipe.filter(Recipe.Columns.isBuiltIn == true).fetchAll(dbConn)
        }

        let categoryMap = Dictionary(uniqueKeysWithValues: recipes.map { ($0.id, $0.category) })

        XCTAssertEqual(categoryMap["builtin-follow-up-email"], .email)
        XCTAssertEqual(categoryMap["builtin-action-items"], .summary)
        XCTAssertEqual(categoryMap["builtin-decisions-summary"], .summary)
        XCTAssertEqual(categoryMap["builtin-meeting-brief"], .summary)
        XCTAssertEqual(categoryMap["builtin-prd-brainstorm"], .planning)
        XCTAssertEqual(categoryMap["builtin-coaching-feedback"], .feedback)
    }

    // MARK: - Default App Settings Inserted

    func testDefaultAppSettingsInserted() throws {
        let db = try TestDatabase.create()

        let settings = try db.writer.read { dbConn in
            try AppSettings.fetchOne(dbConn)
        }

        XCTAssertNotNil(settings)
        XCTAssertEqual(settings?.id, 1)
        XCTAssertFalse(settings!.summaryPromptTemplate.isEmpty)
    }
}

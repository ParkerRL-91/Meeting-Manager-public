import XCTest
import GRDB
@testable import MeetingManager

final class AppSettingsTests: XCTestCase {

    // MARK: - Table Name

    func testDatabaseTableName() {
        XCTAssertEqual(AppSettings.databaseTableName, "appSettings")
    }

    // MARK: - Default Values

    func testDefaultWhisperModel() {
        // Default moved to Large v3 Turbo in the v17 migration; assert against the
        // enum rawValue (the source of truth) rather than a hard-coded legacy string.
        XCTAssertEqual(AppSettings.default.whisperModel, WhisperModel.largev3turbo.rawValue)
    }

    func testDefaultClaudeModel() {
        XCTAssertEqual(AppSettings.default.claudeModel, "claude-sonnet-4-6")
    }

    func testDefaultCalendarSyncInterval() {
        XCTAssertEqual(AppSettings.default.calendarSyncIntervalMinutes, 15)
    }

    func testDefaultNotificationLeadTime() {
        XCTAssertEqual(AppSettings.default.notificationLeadTimeMinutes, 5)
    }

    func testDefaultLaunchAtLogin() {
        XCTAssertFalse(AppSettings.default.launchAtLogin)
    }

    func testDefaultTheme() {
        XCTAssertEqual(AppSettings.default.theme, "dark")
    }

    func testDefaultSummaryPromptTemplateIsNotEmpty() {
        XCTAssertFalse(AppSettings.default.summaryPromptTemplate.isEmpty)
    }

    func testDefaultIdIsOne() {
        XCTAssertEqual(AppSettings.default.id, 1)
    }

    // MARK: - Singleton Constraint

    func testSingletonRowInsertedByMigration() throws {
        let db = try TestDatabase.create()

        let settings = try db.writer.read { dbConn in
            try AppSettings.fetchOne(dbConn)
        }

        XCTAssertNotNil(settings, "Default settings should be inserted by migration")
        XCTAssertEqual(settings?.id, 1)
    }

    func testCannotInsertSecondRow() throws {
        let db = try TestDatabase.create()

        // The id column has a CHECK constraint (id == 1),
        // so inserting with id = 2 should fail.
        XCTAssertThrowsError(try db.writer.write { dbConn in
            try dbConn.execute(
                sql: """
                    INSERT INTO appSettings (id, whisperModel, summaryPromptTemplate, claudeModel,
                        calendarSyncIntervalMinutes, notificationLeadTimeMinutes, launchAtLogin, theme)
                    VALUES (2, 'tiny-en', 'prompt', 'claude', 15, 2, 0, 'dark')
                    """
            )
        })
    }

    // MARK: - GRDB Roundtrip

    func testUpdateAndFetch() throws {
        let db = try TestDatabase.create()

        try db.writer.write { dbConn in
            if var settings = try AppSettings.fetchOne(dbConn) {
                settings.whisperModel = "large-v3"
                settings.theme = "light"
                try settings.update(dbConn)
            }
        }

        let fetched = try db.writer.read { dbConn in
            try AppSettings.fetchOne(dbConn)
        }

        XCTAssertEqual(fetched?.whisperModel, "large-v3")
        XCTAssertEqual(fetched?.theme, "light")
    }

    // MARK: - Codable Roundtrip

    func testCodableRoundtrip() throws {
        let original = AppSettings.default

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(original, decoded)
    }
}

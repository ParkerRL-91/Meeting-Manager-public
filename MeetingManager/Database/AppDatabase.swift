import Foundation
import GRDB
import os

private let logger = Logger(subsystem: "com.meetingmanager.app", category: "database")

final class AppDatabase {
    let writer: DatabaseWriter

    /// The live on-disk database. If initialization failed, this is an in-memory
    /// fallback; check `initializationError` and surface a banner to the user.
    static let shared: AppDatabase = {
        do {
            return try AppDatabase._makeShared()
        } catch {
            logger.critical("Database initialization failed: \(error)")
            AppDatabase.initializationError = error
            // Return an in-memory fallback so the process can continue to show
            // the error banner. All writes to this instance are transient.
            return try! AppDatabase.empty()
        }
    }()

    /// Non-nil if the on-disk database could not be opened at launch.
    /// AppState reads this and surfaces a user-facing banner.
    static private(set) var initializationError: Error?

    private init(writer: DatabaseWriter) throws {
        self.writer = writer
        try migrator.migrate(writer)
    }

    private static func _makeShared() throws -> AppDatabase {
        let url = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("MeetingManager", isDirectory: true)

        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        let dbPath = url.appendingPathComponent("db.sqlite").path
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode=WAL")
            try db.execute(sql: "PRAGMA synchronous=NORMAL")
            try db.execute(sql: "PRAGMA cache_size=-8000")
        }
        config.maximumReaderCount = 5
        let dbPool = try DatabasePool(path: dbPath, configuration: config)

        return try AppDatabase(writer: dbPool)
    }

    /// In-memory database for previews and tests
    static func empty() throws -> AppDatabase {
        let dbQueue = try DatabaseQueue(configuration: Configuration())
        return try AppDatabase(writer: dbQueue)
    }

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        Migrations.registerAll(&migrator)
        return migrator
    }
}

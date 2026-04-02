import Foundation
import GRDB

final class AppDatabase {
    let writer: DatabaseWriter

    static let shared = makeShared()

    private init(writer: DatabaseWriter) throws {
        self.writer = writer
        try migrator.migrate(writer)
    }

    private static func makeShared() -> AppDatabase {
        do {
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
        } catch {
            fatalError("Failed to initialize database: \(error)")
        }
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

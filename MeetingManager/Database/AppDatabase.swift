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

        let db = try AppDatabase(writer: dbPool)
        db.checkFTSConsistency()
        return db
    }

    /// Logs a warning if transcript_fts is out of sync with the transcript table.
    /// Inconsistency can occur if a migration ran partially or triggers were bypassed.
    /// A mismatch here is non-fatal — search may return stale results until the next
    /// v22-fts-rebuild migration runs (or the user rebuilds manually).
    private func checkFTSConsistency() {
        Task.detached(priority: .utility) { [writer] in
            do {
                let (transcriptCount, ftsCount) = try await writer.read { db -> (Int, Int) in
                    let tc = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcript") ?? 0
                    let fc = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcript_fts") ?? 0
                    return (tc, fc)
                }
                if transcriptCount != ftsCount {
                    logger.warning("FTS inconsistency: transcript=\(transcriptCount) fts=\(ftsCount) — search results may be stale")
                } else {
                    logger.info("FTS consistency check: \(transcriptCount) rows — OK")
                }
            } catch {
                logger.error("FTS consistency check failed: \(error)")
            }
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

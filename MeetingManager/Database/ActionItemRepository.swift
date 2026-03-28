import Foundation
import GRDB

final class ActionItemRepository {
    private let database: AppDatabase

    init(database: AppDatabase = .shared) {
        self.database = database
    }

    func save(_ item: inout ActionItem) async throws {
        try await database.writer.write { db in
            try item.save(db)
        }
    }

    func saveBatch(_ items: [ActionItem]) async throws {
        try await database.writer.write { db in
            for var item in items {
                try item.save(db)
            }
        }
    }

    func itemsForMeeting(_ meetingId: String) async throws -> [ActionItem] {
        try await database.writer.read { db in
            try ActionItem
                .filter(ActionItem.Columns.meetingId == meetingId)
                .order(ActionItem.Columns.extractedAt.asc)
                .fetchAll(db)
        }
    }

    func allOpenItems() async throws -> [ActionItem] {
        try await database.writer.read { db in
            try ActionItem
                .filter(ActionItem.Columns.isCompleted == false)
                .order(ActionItem.Columns.extractedAt.asc)
                .fetchAll(db)
        }
    }

    func toggleComplete(id: Int64) async throws {
        try await database.writer.write { db in
            guard var item = try ActionItem.fetchOne(db, key: id) else { return }
            item.isCompleted.toggle()
            try item.update(db)
        }
    }

    func delete(_ item: ActionItem) async throws {
        try await database.writer.write { db in
            _ = try item.delete(db)
        }
    }
}

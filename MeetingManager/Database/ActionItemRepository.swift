import Foundation
import GRDB

final class ActionItemRepository {
    private let database: AppDatabase

    init(database: AppDatabase = .shared) {
        self.database = database
    }

    func save(_ item: inout ActionItem) async throws {
        var copy = item
        try await database.writer.write { db in
            try copy.save(db)
        }
        item = copy
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

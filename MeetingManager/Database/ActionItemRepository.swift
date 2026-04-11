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

    func allOpenItems(limit: Int = 100) async throws -> [ActionItem] {
        try await database.writer.read { db in
            try ActionItem
                .filter(ActionItem.Columns.isCompleted == false)
                .order(ActionItem.Columns.extractedAt.asc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// Returns open action items where the assignee fuzzy-matches any name in the
    /// participant list. Matching is case-insensitive and supports first-name-only
    /// matches (e.g., participant "Sarah Chen" matches assignee "Sarah").
    func openItemsForParticipants(_ participants: [String]) async throws -> [ActionItem] {
        guard !participants.isEmpty else { return [] }

        let allOpen = try await allOpenItems(limit: 500)

        // Build a set of lowercased full names and first names for matching
        let fullNames = Set(participants.map { $0.lowercased().trimmingCharacters(in: .whitespaces) })
        let firstNames = Set(participants.compactMap { name -> String? in
            let first = name.components(separatedBy: .whitespaces).first?.lowercased()
            // Only use first names that are at least 2 characters to avoid false positives
            guard let first, first.count >= 2 else { return nil }
            return first
        })

        return allOpen.filter { item in
            guard let assignee = item.assignee?.lowercased().trimmingCharacters(in: .whitespaces),
                  !assignee.isEmpty else { return false }
            // Check full name match
            if fullNames.contains(assignee) { return true }
            // Check if assignee matches any participant's first name
            if firstNames.contains(assignee) { return true }
            // Check if any participant's full name starts with the assignee text
            if fullNames.contains(where: { $0.hasPrefix(assignee) }) { return true }
            // Check if assignee contains any participant's first name as a whole word
            let assigneeFirst = assignee.components(separatedBy: .whitespaces).first ?? assignee
            if assigneeFirst.count >= 2 && firstNames.contains(assigneeFirst) { return true }
            return false
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

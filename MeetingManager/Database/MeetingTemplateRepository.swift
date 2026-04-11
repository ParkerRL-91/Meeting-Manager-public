import Foundation
import GRDB

final class MeetingTemplateRepository {
    private let database: AppDatabase

    init(database: AppDatabase = .shared) {
        self.database = database
    }

    func all() async throws -> [MeetingTemplate] {
        try await database.writer.read { db in
            try MeetingTemplate
                .order(MeetingTemplate.Columns.name.asc)
                .fetchAll(db)
        }
    }

    func find(id: String) async throws -> MeetingTemplate? {
        try await database.writer.read { db in
            try MeetingTemplate.fetchOne(db, key: id)
        }
    }

    func save(_ template: inout MeetingTemplate) async throws {
        var copy = template
        try await database.writer.write { db in
            try copy.save(db)
        }
        template = copy
    }

    func delete(_ template: MeetingTemplate) async throws {
        try await database.writer.write { db in
            _ = try template.delete(db)
        }
    }
}

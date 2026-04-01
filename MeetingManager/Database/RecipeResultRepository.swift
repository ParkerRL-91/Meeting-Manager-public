import Foundation
import GRDB

final class RecipeResultRepository {
    private let database: AppDatabase

    init(database: AppDatabase) {
        self.database = database
    }

    func save(_ result: inout RecipeResult) async throws {
        var copy = result
        try await database.writer.write { db in
            try copy.save(db)
        }
        result = copy
    }

    func resultsForMeeting(_ meetingId: String, limit: Int = 50) async throws -> [RecipeResult] {
        try await database.writer.read { db in
            try RecipeResult
                .filter(RecipeResult.Columns.meetingId == meetingId)
                .order(RecipeResult.Columns.generatedAt.desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    func latestResult(meetingId: String, recipeId: String) async throws -> RecipeResult? {
        try await database.writer.read { db in
            try RecipeResult
                .filter(RecipeResult.Columns.meetingId == meetingId)
                .filter(RecipeResult.Columns.recipeId == recipeId)
                .order(RecipeResult.Columns.generatedAt.desc)
                .fetchOne(db)
        }
    }

    func delete(_ result: RecipeResult) async throws {
        try await database.writer.write { db in
            _ = try result.delete(db)
        }
    }
}

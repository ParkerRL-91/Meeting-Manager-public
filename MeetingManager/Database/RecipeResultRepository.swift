import Foundation
import GRDB

final class RecipeResultRepository {
    private let database: AppDatabase

    init(database: AppDatabase) {
        self.database = database
    }

    func save(_ result: inout RecipeResult) async throws {
        // Return the saved record so the auto-assigned rowid propagates back
        // (see TaskRepository.save).
        let input = result
        result = try await database.writer.write { db in
            var copy = input
            try copy.save(db)
            return copy
        }
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

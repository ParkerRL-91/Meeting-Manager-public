import Foundation
import GRDB

// MARK: - RecipeCategory

enum RecipeCategory: String, Codable, CaseIterable {
    case email
    case summary
    case planning
    case feedback
    case custom

    var displayName: String {
        switch self {
        case .email: return "Email"
        case .summary: return "Summary"
        case .planning: return "Planning"
        case .feedback: return "Feedback"
        case .custom: return "Custom"
        }
    }

    var icon: String {
        switch self {
        case .email: return "envelope"
        case .summary: return "doc.text"
        case .planning: return "list.clipboard"
        case .feedback: return "bubble.left.and.text.bubble.right"
        case .custom: return "star"
        }
    }
}

// MARK: - Recipe

struct Recipe: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var description: String
    var promptTemplate: String
    var category: RecipeCategory
    var isBuiltIn: Bool
    var createdAt: Date

    init(
        id: String = UUID().uuidString,
        name: String,
        description: String,
        promptTemplate: String,
        category: RecipeCategory,
        isBuiltIn: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.promptTemplate = promptTemplate
        self.category = category
        self.isBuiltIn = isBuiltIn
        self.createdAt = createdAt
    }
}

// MARK: - GRDB

extension Recipe: FetchableRecord, PersistableRecord {
    static let databaseTableName = "recipe"

    enum Columns: String, ColumnExpression {
        case id, name, description, promptTemplate, category, isBuiltIn, createdAt
    }
}

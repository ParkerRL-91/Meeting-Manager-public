import Foundation
import GRDB

/// A persistent task in the background processing queue.
/// Tasks survive app restarts — they're stored in SQLite, not memory.
struct TaskQueueItem: Codable, Identifiable, Equatable, Hashable {
    var id: String
    var type: TaskType
    var meetingId: String
    var status: TaskStatus
    var priority: Int
    var retryCount: Int
    var maxRetries: Int
    var error: String?
    var createdAt: Date
    var startedAt: Date?
    var completedAt: Date?
    var metadata: String?  // JSON blob for task-specific data

    enum TaskType: String, Codable, CaseIterable {
        case transcription
        case summary
        case enrichment
        case regeneration
        case contextEnrichment
    }

    enum TaskStatus: String, Codable, CaseIterable {
        case pending
        case running
        case completed
        case failed
    }

    /// Human-readable description of what this task does.
    var displayName: String {
        switch type {
        case .transcription: return "Transcribe"
        case .summary:       return "Summarize"
        case .enrichment:    return "Enrich"
        case .regeneration:        return "Regenerate Summary"
        case .contextEnrichment:   return "Finding Related Meetings"
        }
    }

    var isTerminal: Bool {
        status == .completed || status == .failed
    }

    var canRetry: Bool {
        status == .failed && retryCount < maxRetries
    }

    /// Create a new task with sensible defaults.
    static func create(
        type: TaskType,
        meetingId: String,
        priority: Int,
        maxRetries: Int = 3,
        metadata: String? = nil
    ) -> TaskQueueItem {
        TaskQueueItem(
            id: UUID().uuidString,
            type: type,
            meetingId: meetingId,
            status: .pending,
            priority: priority,
            retryCount: 0,
            maxRetries: maxRetries,
            error: nil,
            createdAt: Date(),
            startedAt: nil,
            completedAt: nil,
            metadata: metadata
        )
    }
}

// MARK: - GRDB

extension TaskQueueItem: FetchableRecord, PersistableRecord {
    static let databaseTableName = "taskQueue"

    enum Columns: String, ColumnExpression {
        case id, type, meetingId, status, priority
        case retryCount, maxRetries, error
        case createdAt, startedAt, completedAt, metadata
    }
}

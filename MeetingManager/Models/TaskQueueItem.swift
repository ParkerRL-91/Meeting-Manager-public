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
        case diarization
        case summary
        case enrichment
        case regeneration
        case contextEnrichment
        case knowledgeBaseIndex
        case transcriptCleanup
        /// v3.10 #7: re-run speaker attribution after transcript cleanup
        /// completes, using the full transcript (not just the first 20 turns).
        /// Triggered automatically when speakerMap still has unresolved
        /// "Speaker N" clusters after diarization. One retry max.
        case retryAttribution
        /// v3.10.3+: detailed time-stamped topic outline. Auto-enqueued
        /// after summary completes; can be re-run on demand from the
        /// Outline tab. See `Services/AI/DetailedOutlineService.swift`.
        case detailedOutline
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
        case .transcription:      return "Transcribe"
        case .diarization:        return "Identify Speakers"
        case .summary:            return "Summarize"
        case .enrichment:         return "Enrich"
        case .regeneration:       return "Regenerate Summary"
        case .contextEnrichment:  return "Finding Related Meetings"
        case .knowledgeBaseIndex: return "Index Knowledge Base"
        case .transcriptCleanup:  return "Cleaning Transcript"
        case .retryAttribution:   return "Re-checking Speakers"
        case .detailedOutline:    return "Generating Outline"
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

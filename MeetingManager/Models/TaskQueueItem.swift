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
    /// Governor (TASK-055): rows with a future runAfter are invisible to
    /// the pop query — deferred until a quiet moment. NULL = run normally.
    var runAfter: Date? = nil

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
        /// PRJ-007: "Enhance Notes" — rewrites the user's raw notes into a
        /// polished version in their own structure. User-initiated only
        /// (never auto-enqueued): the Notes tab and the live notepad button
        /// enqueue it. See `AppState.generateEnhancedNotesForTask`.
        case enhanceNotes
        /// PRJ-009 TASK-045: embed a meeting's transcript + summary for
        /// semantic retrieval. Sentinel meetingId "__embed_backfill__"
        /// walks every un-embedded meeting (one queue row, cancellable).
        case embedIndex
        /// PRJ-009 TASK-051: generate the previous ISO week's digest.
        /// Sentinel meetingId "__weekly_digest__" (no real meeting).
        case weeklyDigest
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
        case .enhanceNotes:       return "Enhance Notes"
        case .embedIndex:         return "Index for Search"
        case .weeklyDigest:       return "Weekly Digest"
        }
    }

    /// Background-class work is governed by BackgroundWorkPolicy
    /// (deferrable to quiet gaps). Per-ITEM, not per-type (review M1): a
    /// fresh meeting's embedIndex must run promptly; only the batch
    /// sentinels are background.
    static func isBackgroundItem(type: TaskType, meetingId: String) -> Bool {
        switch type {
        case .embedIndex:   return meetingId == "__embed_backfill__"
        case .weeklyDigest: return true
        default:            return false
        }
    }

    /// Types whose handler makes local-LLM calls — the governor's
    /// classification input (NOT the busy detector; that's the
    /// OllamaService in-flight counter, review B2).
    var isLLMClass: Bool {
        switch type {
        case .summary, .regeneration, .transcriptCleanup, .detailedOutline,
             .enhanceNotes, .weeklyDigest, .retryAttribution, .contextEnrichment,
             .enrichment:
            return true
        case .transcription, .diarization, .knowledgeBaseIndex, .embedIndex:
            return false
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

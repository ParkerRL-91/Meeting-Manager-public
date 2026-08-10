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
    /// Governor (TASK-093): wall-clock time this row was FIRST deferred.
    /// Set once on the first defer (COALESCE-preserved across subsequent
    /// defers), cleared when the row actually runs. This anchors the
    /// starvation clock to continuous-deferral age rather than row-creation
    /// time (createdAt). NULL = never deferred.
    var firstDeferredAt: Date? = nil

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
        /// PRJ-010 TASK-056: nightly knowledge gardener — links duplicate/
        /// superseded/contradicted facts across meetings. Sentinel
        /// meetingId "__gardener__" (no real meeting); background-class.
        case gardener
        /// PRJ-010 TASK-063: backfill insight extraction over historical
        /// meetings that have a summary but no facts. Sentinel meetingId
        /// "__fact_backfill__"; background-class; full extraction per
        /// meeting (anchors included — review M7).
        case factBackfill
        /// PRJ-010 TASK-064: nightly glossary miner — recurring jargon
        /// tokens (≥3 meetings) defined from usage with one schema call.
        /// Sentinel meetingId "__glossary__"; background-class.
        case glossary
        /// PRJ-010 TASK-059: backfill speaking stats over history. Pure
        /// math, no LLM. Sentinel meetingId "__speech_stats__".
        case speechStats
        /// PRJ-011 TASK-079: backfill coarse lexicon sentiment over history.
        /// Pure, no LLM. Sentinel meetingId "__sentiment_backfill__".
        case sentimentBackfill
        /// PRJ-011 TASK-081: scan history for user topic trackers. Pure
        /// keyword match. Sentinel meetingId "__topic_backfill__".
        case topicBackfill
        /// PRJ-016 TASK-135: compress a finished meeting's WAV recordings to
        /// Apple Lossless `.m4a` (~5.5× smaller) once the post-meeting pipeline
        /// is done with them. Pure local file work, no LLM. Enqueued at the
        /// lowest pipeline priority so every audio-reading task runs first, and
        /// idempotent — an already-archived session is skipped, never
        /// re-encoded. See `Services/Audio/AudioArchiveService.swift`.
        case audioArchive
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
        case .gardener:           return "Tidy Knowledge"
        case .factBackfill:       return "Extract Insights (History)"
        case .glossary:           return "Update Glossary"
        case .speechStats:        return "Compute Speaking Stats"
        case .sentimentBackfill:  return "Read Tone (History)"
        case .topicBackfill:      return "Scan Topics (History)"
        case .audioArchive:       return "Compress Audio"
        }
    }

    /// True when this row was enqueued by an explicit user request. Read from
    /// the `metadata` JSON blob (a JSON String?, not a dictionary column) —
    /// mirrors the recipeId parse in `TaskQueueManager.execute`. (TASK-122)
    static func isUserInitiated(metadata: String?) -> Bool {
        guard let metadata,
              let data = metadata.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return (json["userInitiated"] as? Bool) == true
    }

    var isUserInitiated: Bool { Self.isUserInitiated(metadata: metadata) }

    /// Background-class work is governed by BackgroundWorkPolicy
    /// (deferrable to quiet gaps). Per-ITEM, not per-type (review M1): a
    /// fresh meeting's embedIndex must run promptly; only the batch
    /// sentinels are background.
    ///
    /// User-initiated rows are NEVER background-class regardless of type
    /// (TASK-122): the user asked for it now, so it skips quiet-gap deferral.
    /// The serial queue (one processLoop, one currentTask) is what prevents
    /// LLM contention — there is no concurrency limiter this bypass violates.
    static func isBackgroundItem(type: TaskType, meetingId: String, metadata: String? = nil) -> Bool {
        if isUserInitiated(metadata: metadata) { return false }
        switch type {
        case .embedIndex:   return meetingId == "__embed_backfill__"
        case .weeklyDigest: return true
        case .gardener:     return true
        case .factBackfill: return true
        case .glossary:     return true
        case .speechStats:  return true
        case .sentimentBackfill: return true
        case .topicBackfill: return true
        default:            return false
        }
    }

    /// Starvation-cap clock (TASK-093): the continuous-deferral age, in
    /// hours, of the longest-waiting still-pending background obligation —
    /// the input the governor compares against `maxDeferHorizonHours`.
    /// Anchored to `firstDeferredAt` (the first defer), NOT `createdAt`, so it
    /// reflects how long a row has actually sat deferred-without-running
    /// rather than how long ago its row was created — `createdAt` drifts as
    /// polls re-create terminal sentinel rows. Only pending background rows
    /// that have actually been deferred count; never-deferred rows
    /// (`firstDeferredAt == nil`), running/terminal rows, and non-background
    /// rows are ignored. Returns 0 when nothing qualifies.
    static func backgroundDeferralAgeHours(_ items: [TaskQueueItem], now: Date) -> Double {
        let oldest = items
            .filter { $0.status == .pending && isBackgroundItem(type: $0.type, meetingId: $0.meetingId, metadata: $0.metadata) }
            .compactMap(\.firstDeferredAt)
            .min()
        guard let oldest else { return 0 }
        return max(0, now.timeIntervalSince(oldest) / 3600)
    }

    /// Types whose handler makes local-LLM calls — the governor's
    /// classification input (NOT the busy detector; that's the
    /// OllamaService in-flight counter, review B2).
    var isLLMClass: Bool {
        switch type {
        case .summary, .regeneration, .transcriptCleanup, .detailedOutline,
             .enhanceNotes, .weeklyDigest, .retryAttribution, .contextEnrichment,
             .enrichment, .gardener, .factBackfill, .glossary:
            return true
        case .transcription, .diarization, .knowledgeBaseIndex, .embedIndex,
             .speechStats, .sentimentBackfill, .topicBackfill, .audioArchive:
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

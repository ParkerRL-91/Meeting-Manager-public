import Foundation
import GRDB
import os

/// Persistent task queue that processes transcription, summarization, and enrichment
/// jobs serially in the background. Tasks survive app restarts via SQLite persistence.
@Observable
@MainActor
final class TaskQueueManager {

    // MARK: - Public State

    private(set) var currentTask: TaskQueueItem?
    private(set) var allTasks: [TaskQueueItem] = []
    var pendingCount: Int { allTasks.filter { $0.status == .pending }.count }
    var isProcessing: Bool { currentTask != nil }

    // MARK: - Dependencies

    private let database: AppDatabase
    private var processorTask: Task<Void, Never>?
    private var calendarPollTimer: Timer?

    /// Closures injected by AppState to execute actual work.
    var transcriptionHandler: ((String, URL?) async throws -> Void)?
    /// Speaker diarization handler — meetingId, system audio URL (may be nil if not recorded).
    var diarizationHandler: ((String, URL?) async throws -> Void)?
    var summaryHandler: ((String) async throws -> Void)?
    var enrichmentHandler: ((String) async throws -> Void)?
    /// Regeneration handler — meetingId + optional recipeId from task metadata.
    var regenerationHandler: ((String, String?) async throws -> Void)?
    /// Context enrichment handler — finds related past meetings for a meeting.
    var contextEnrichmentHandler: ((String) async throws -> Void)?
    /// Called after a summary task completes — meetingId is passed so a notification can be sent.
    var summaryCompletedHandler: ((String) async -> Void)?

    init(database: AppDatabase = .shared) {
        self.database = database
    }

    // MARK: - Lifecycle

    func startUp() async {
        Logger.general.info("TaskQueue: starting up")
        await recoverStuckTasks()
        await enqueueOrphanedMeetings()
        await refreshTaskList()
        startProcessor()
        startCalendarPoll()
    }

    func shutdown() {
        processorTask?.cancel()
        processorTask = nil
        calendarPollTimer?.invalidate()
        calendarPollTimer = nil
    }

    // MARK: - Enqueue

    @discardableResult
    func enqueue(type: TaskQueueItem.TaskType, meetingId: String, priority: Int, metadata: String? = nil) async -> TaskQueueItem? {
        do {
            let exists = try await database.writer.read { db in
                try TaskQueueItem
                    .filter(TaskQueueItem.Columns.type == type.rawValue)
                    .filter(TaskQueueItem.Columns.meetingId == meetingId)
                    .filter(TaskQueueItem.Columns.status == TaskQueueItem.TaskStatus.pending.rawValue
                         || TaskQueueItem.Columns.status == TaskQueueItem.TaskStatus.running.rawValue)
                    .fetchCount(db) > 0
            }
            if exists {
                Logger.general.info("TaskQueue: skipping duplicate \(type.rawValue) for \(meetingId)")
                return nil
            }
        } catch {
            Logger.general.error("TaskQueue: dedup check failed: \(error.localizedDescription)")
        }

        let item = TaskQueueItem.create(
            type: type,
            meetingId: meetingId,
            priority: priority,
            maxRetries: type == .summary ? 2 : 3,
            metadata: metadata
        )

        do {
            try await database.writer.write { db in
                try item.insert(db)
            }
            Logger.general.info("TaskQueue: enqueued \(type.rawValue) for meeting \(meetingId) (priority \(priority))")
            await refreshTaskList()
            kickProcessor()
            return item
        } catch {
            Logger.general.error("TaskQueue: failed to enqueue: \(error.localizedDescription)")
            return nil
        }
    }

    func retry(taskId: String) async {
        do {
            try await database.writer.write { db in
                if var task = try TaskQueueItem.fetchOne(db, key: taskId) {
                    task.status = .pending
                    task.error = nil
                    task.startedAt = nil
                    try task.update(db)
                }
            }
            await refreshTaskList()
            kickProcessor()
        } catch {
            Logger.general.error("TaskQueue: retry failed: \(error.localizedDescription)")
        }
    }

    func cancel(taskId: String) async {
        do {
            try await database.writer.write { db in
                try TaskQueueItem.deleteOne(db, key: taskId)
            }
            await refreshTaskList()
        } catch {
            Logger.general.error("TaskQueue: cancel failed: \(error.localizedDescription)")
        }
    }

    func clearCompleted() async {
        do {
            try await database.writer.write { db in
                try TaskQueueItem
                    .filter(TaskQueueItem.Columns.status == TaskQueueItem.TaskStatus.completed.rawValue
                         || TaskQueueItem.Columns.status == TaskQueueItem.TaskStatus.failed.rawValue)
                    .deleteAll(db)
            }
            await refreshTaskList()
        } catch {
            Logger.general.error("TaskQueue: clearCompleted failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Task List

    func refreshTaskList() async {
        do {
            allTasks = try await database.writer.read { db in
                try TaskQueueItem
                    .order(
                        sql: """
                        CASE status
                            WHEN 'running' THEN 0
                            WHEN 'pending' THEN 1
                            WHEN 'failed' THEN 2
                            WHEN 'completed' THEN 3
                        END ASC,
                        priority ASC,
                        createdAt ASC
                        """
                    )
                    .limit(100)
                    .fetchAll(db)
            }
        } catch {
            Logger.general.error("TaskQueue: refreshTaskList failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Startup Recovery

    private func recoverStuckTasks() async {
        do {
            let recovered = try await database.writer.write { db -> Int in
                let stuck = try TaskQueueItem
                    .filter(TaskQueueItem.Columns.status == TaskQueueItem.TaskStatus.running.rawValue)
                    .fetchAll(db)
                for var task in stuck {
                    task.status = .pending
                    task.startedAt = nil
                    try task.update(db)
                }
                return stuck.count
            }
            if recovered > 0 {
                Logger.general.info("TaskQueue: recovered \(recovered) stuck task(s)")
            }
        } catch {
            Logger.general.error("TaskQueue: recoverStuckTasks failed: \(error.localizedDescription)")
        }
    }

    private func enqueueOrphanedMeetings() async {
        do {
            let needTranscription: [Meeting] = try await database.writer.read { db in
                try Meeting.fetchAll(db, sql: """
                    SELECT m.* FROM meeting m
                    WHERE m.audioFilePath IS NOT NULL
                      AND m.audioFilePath != ''
                      AND m.status IN ('transcribing', 'complete')
                      AND NOT EXISTS (SELECT 1 FROM transcript t WHERE t.meetingId = m.id)
                    LIMIT 20
                """)
            }

            for meeting in needTranscription {
                await enqueue(type: .transcription, meetingId: meeting.id, priority: 2)
            }

            let needSummary: [Meeting] = try await database.writer.read { db in
                try Meeting.fetchAll(db, sql: """
                    SELECT m.* FROM meeting m
                    WHERE m.status IN ('transcribing', 'complete')
                      AND EXISTS (SELECT 1 FROM transcript t WHERE t.meetingId = m.id)
                      AND NOT EXISTS (SELECT 1 FROM meetingSummary s WHERE s.meetingId = m.id)
                    LIMIT 20
                """)
            }

            for meeting in needSummary {
                await enqueue(type: .summary, meetingId: meeting.id, priority: 6)
            }

            let total = needTranscription.count + needSummary.count
            if total > 0 {
                Logger.general.info("TaskQueue: enqueued \(needTranscription.count) transcription + \(needSummary.count) summary orphaned tasks")
            }
        } catch {
            Logger.general.error("TaskQueue: enqueueOrphanedMeetings failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Processor

    private func startProcessor() {
        guard processorTask == nil else { return }
        processorTask = Task { [weak self] in
            await self?.processLoop()
        }
    }

    private func kickProcessor() {
        if processorTask == nil { startProcessor() }
    }

    private func processLoop() async {
        while !Task.isCancelled {
            guard let next = await fetchNextPending() else {
                try? await Task.sleep(for: .seconds(5))
                continue
            }

            await markRunning(next)
            currentTask = next
            await refreshTaskList()

            do {
                try await execute(next)
                await markCompleted(next)
                Logger.general.info("TaskQueue: completed \(next.type.rawValue) for \(next.meetingId)")

                // Post-summary follow-up: send notification and optionally enqueue follow-up email
                if next.type == .summary {
                    if let handler = summaryCompletedHandler {
                        await handler(next.meetingId)
                    }
                }

                // Auto-enqueue diarization + summary after transcription — but only if segments exist
                if next.type == .transcription {
                    let hasSegments = (try? await database.writer.read { db in
                        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcript WHERE meetingId = ?", arguments: [next.meetingId])
                    } ?? 0) ?? 0
                    if hasSegments > 0 {
                        // Diarization runs before summary so speaker names are in the transcript
                        // when the summarizer prompt is built.
                        await enqueue(type: .diarization, meetingId: next.meetingId, priority: 4)
                        await enqueue(type: .summary, meetingId: next.meetingId, priority: 5)
                    } else {
                        Logger.general.info("TaskQueue: transcription produced 0 segments for \(next.meetingId) — skipping diarization + summary")
                    }
                }
            } catch {
                let shouldRetry = next.retryCount + 1 < next.maxRetries
                await markFailed(next, error: error.localizedDescription, willRetry: shouldRetry)
                Logger.general.error("TaskQueue: \(next.type.rawValue) failed: \(error.localizedDescription) (retry: \(shouldRetry))")

                if shouldRetry {
                    let delay = Double((next.retryCount + 1) * (next.retryCount + 1)) * 10
                    try? await Task.sleep(for: .seconds(delay))
                }
            }

            currentTask = nil
            await refreshTaskList()
        }
    }

    private func fetchNextPending() async -> TaskQueueItem? {
        try? await database.writer.read { db in
            try TaskQueueItem
                .filter(TaskQueueItem.Columns.status == TaskQueueItem.TaskStatus.pending.rawValue)
                .order(TaskQueueItem.Columns.priority.asc, TaskQueueItem.Columns.createdAt.asc)
                .fetchOne(db)
        }
    }

    private func execute(_ task: TaskQueueItem) async throws {
        switch task.type {
        case .transcription:
            guard let handler = transcriptionHandler else {
                throw TaskQueueError.noHandler("transcription")
            }
            let audioURL: URL? = try? await database.writer.read { db in
                guard let meeting = try Meeting.fetchOne(db, key: task.meetingId),
                      let path = meeting.audioFilePath else { return nil }
                return URL(fileURLWithPath: path)
            }
            try await handler(task.meetingId, audioURL)

        case .diarization:
            guard let handler = diarizationHandler else {
                throw TaskQueueError.noHandler("diarization")
            }
            let systemAudioURL: URL? = try? await database.writer.read { db in
                guard let meeting = try Meeting.fetchOne(db, key: task.meetingId),
                      let path = meeting.audioFilePath else { return nil }
                let mixedURL = URL(fileURLWithPath: path)
                return AudioBufferManager.systemAudioURL(for: mixedURL)
            }
            try await handler(task.meetingId, systemAudioURL)

        case .summary:
            guard let handler = summaryHandler else {
                throw TaskQueueError.noHandler("summary")
            }
            try await handler(task.meetingId)

        case .enrichment:
            guard let handler = enrichmentHandler else {
                throw TaskQueueError.noHandler("enrichment")
            }
            try await handler(task.meetingId)

        case .regeneration:
            guard let handler = regenerationHandler else {
                throw TaskQueueError.noHandler("regeneration")
            }
            // Extract optional recipeId from metadata JSON blob.
            var recipeId: String? = nil
            if let meta = task.metadata,
               let data = meta.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
                recipeId = json["recipeId"]
            }
            try await handler(task.meetingId, recipeId)

        case .contextEnrichment:
            guard let handler = contextEnrichmentHandler else {
                throw TaskQueueError.noHandler("contextEnrichment")
            }
            try await handler(task.meetingId)
        }
    }

    // MARK: - Status Updates

    private func markRunning(_ task: TaskQueueItem) async {
        do {
            try await database.writer.write { db in
                var t = task
                t.status = .running
                t.startedAt = Date()
                try t.update(db)
            }
        } catch {
            Logger.general.error("TaskQueue: markRunning failed: \(error.localizedDescription)")
        }
    }

    private func markCompleted(_ task: TaskQueueItem) async {
        do {
            try await database.writer.write { db in
                var t = task
                t.status = .completed
                t.completedAt = Date()
                try t.update(db)
            }
        } catch {
            Logger.general.error("TaskQueue: markCompleted failed: \(error.localizedDescription)")
        }
    }

    private func markFailed(_ task: TaskQueueItem, error: String, willRetry: Bool) async {
        do {
            try await database.writer.write { db in
                var t = task
                t.retryCount += 1
                t.error = error
                if willRetry {
                    t.status = .pending
                    t.startedAt = nil
                } else {
                    t.status = .failed
                    t.completedAt = Date()
                }
                try t.update(db)
            }
        } catch {
            Logger.general.error("TaskQueue: markFailed DB write failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Calendar Poll

    private func startCalendarPoll() {
        calendarPollTimer?.invalidate()
        calendarPollTimer = Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.pollForNewMeetings()
            }
        }
    }

    private func pollForNewMeetings() async {
        Logger.general.info("TaskQueue: polling for meetings needing summaries")
        do {
            let needSummary: [Meeting] = try await database.writer.read { db in
                try Meeting.fetchAll(db, sql: """
                    SELECT m.* FROM meeting m
                    WHERE m.status = 'complete'
                      AND EXISTS (SELECT 1 FROM transcript t WHERE t.meetingId = m.id)
                      AND NOT EXISTS (SELECT 1 FROM meetingSummary s WHERE s.meetingId = m.id)
                    LIMIT 10
                """)
            }
            for meeting in needSummary {
                await enqueue(type: .summary, meetingId: meeting.id, priority: 8)
            }
            if !needSummary.isEmpty {
                Logger.general.info("TaskQueue: poll found \(needSummary.count) meeting(s) needing summaries")
            }
        } catch {
            Logger.general.error("TaskQueue: poll failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Errors

enum TaskQueueError: LocalizedError {
    case noHandler(String)

    var errorDescription: String? {
        switch self {
        case .noHandler(let type):
            return "No handler registered for task type: \(type)"
        }
    }
}

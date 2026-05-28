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

    /// Live, in-memory progress for whichever task is currently running.
    /// Cleared when the task finishes or fails. Handlers update this
    /// through `reportCurrentProgress(stage:fraction:)` between stages.
    ///
    /// `fraction` is `nil` when the work isn't chunk-able (one big LLM call)
    /// — in that case only the `stage` label is meaningful. Where the work
    /// genuinely proceeds in measurable chunks (KB indexing), `fraction` is
    /// a real 0…1 value derived from items processed / total.
    private(set) var currentProgress: TaskProgress?

    struct TaskProgress: Sendable, Equatable {
        let stage: String
        let fraction: Double?
        let updatedAt: Date
    }

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
    /// Knowledge Base index handler — no meeting context needed.
    var knowledgeBaseIndexHandler: (() async throws -> Void)?
    /// Transcript cleanup handler — runs stitch + AI pass for one meeting.
    var transcriptCleanupHandler: ((String) async throws -> Void)?
    /// v3.10 #7: second-pass speaker attribution handler. Triggered when
    /// transcript cleanup completes and the meeting still has unresolved
    /// "Speaker N" clusters. Runs against the full transcript with whatever
    /// signals are now available.
    var retryAttributionHandler: ((String) async throws -> Void)?
    /// v3.10.3+: detailed-outline generation. Auto-enqueued after a summary
    /// task completes; can be enqueued manually by the user via the Outline
    /// tab's Regenerate button.
    var detailedOutlineHandler: ((String) async throws -> Void)?

    init(database: AppDatabase = .shared) {
        self.database = database
    }

    // MARK: - Lifecycle

    func startUp() async {
        Logger.general.info("TaskQueue: starting up")
        await recoverStuckTasks()
        await reconcileOrphanAudioFiles()
        await enqueueOrphanedMeetings()
        await refreshTaskList()
        startProcessor()
        startCalendarPoll()
    }

    // MARK: - Filesystem Orphan Reconciliation

    /// Walks `~/Library/Application Support/MeetingManager/Audio/*.wav` and
    /// re-attaches WAV files to their meeting rows when the row exists but
    /// `audioFilePath` is empty (which happens when the app was force-killed
    /// before the row could persist the path, e.g. during an in-flight reinstall).
    ///
    /// Also repairs in place WAV headers whose `data` chunk size is zero —
    /// the canonical signature of an `AVAudioFile` that never reached its
    /// `close`. Without this repair, AVAudioFile refuses to read the file
    /// and transcription would silently produce zero segments.
    private func reconcileOrphanAudioFiles() async {
        let fm = FileManager.default
        let audioDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MeetingManager", isDirectory: true)
            .appendingPathComponent("Audio", isDirectory: true)
        guard fm.fileExists(atPath: audioDir.path) else { return }
        guard let entries = try? fm.contentsOfDirectory(at: audioDir, includingPropertiesForKeys: nil) else { return }

        // Map: meetingId UUID → main wav URL (skip _system.wav siblings)
        var byMeeting: [String: URL] = [:]
        for url in entries {
            let name = url.lastPathComponent
            guard name.hasSuffix(".wav"), !name.hasSuffix("_system.wav") else { continue }
            let meetingId = url.deletingPathExtension().lastPathComponent
            // Skip ones that don't look like a UUID
            if meetingId.count != 36 { continue }
            byMeeting[meetingId] = url
        }
        guard !byMeeting.isEmpty else { return }

        var repaired = 0
        var reattached = 0
        for (meetingId, url) in byMeeting {
            // Repair zero-data WAV header in place if needed.
            if Self.repairWavHeaderIfNeeded(at: url) {
                repaired += 1
                let systemURL = url.deletingLastPathComponent().appendingPathComponent("\(meetingId)_system.wav")
                _ = Self.repairWavHeaderIfNeeded(at: systemURL)
            }

            // Re-attach when the meeting row exists but has no audio path.
            do {
                let needsAttach = try await database.writer.read { db -> Bool in
                    guard let m = try Meeting.fetchOne(db, key: meetingId) else { return false }
                    let hasPath = (m.audioFilePath ?? "").isEmpty == false
                    return !hasPath
                }
                guard needsAttach else { continue }

                try await database.writer.write { db in
                    try db.execute(
                        sql: "UPDATE meeting SET audioFilePath = ?, status = CASE WHEN status = 'scheduled' THEN 'transcribing' ELSE status END WHERE id = ?",
                        arguments: [url.path, meetingId]
                    )
                }
                reattached += 1
                Logger.general.info("TaskQueue: re-attached orphan audio \(url.lastPathComponent, privacy: .public) to meeting \(meetingId, privacy: .public)")
            } catch {
                Logger.general.warning("TaskQueue: reattach failed for \(meetingId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        if repaired > 0 || reattached > 0 {
            Logger.general.info("TaskQueue: orphan-audio reconciliation — repaired \(repaired), re-attached \(reattached) file(s)")
        }
    }

    /// Patch the RIFF size + data chunk size of a WAV file that was killed
    /// before `AVAudioFile.close` ran. Returns true if the file was modified.
    /// Safe to call on healthy files (early-exits when the data chunk size
    /// already matches reality).
    ///
    /// WAV layout written by AVAudioFile (Float32 mono 16k):
    ///   0..3   "RIFF"
    ///   4..7   RIFF size (file_size - 8)
    ///   8..11  "WAVE"
    ///   12..43 JUNK (28) + fmt (16) + ...
    ///   4088   "data"
    ///   4092   data size  ← zero on a force-killed file
    ///   4096   audio samples
    private static func repairWavHeaderIfNeeded(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forUpdating: url) else { return false }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: 0)
            guard let riffTag = try handle.read(upToCount: 4), riffTag == Data("RIFF".utf8) else { return false }
            try handle.seek(toOffset: 4088)
            guard let dataTag = try handle.read(upToCount: 4), dataTag == Data("data".utf8) else { return false }
            try handle.seek(toOffset: 4092)
            guard let sizeBytes = try handle.read(upToCount: 4), sizeBytes.count == 4 else { return false }

            // File size — seek to end and read offset.
            let endOffset = try handle.seekToEnd()
            let fileSize = UInt32(endOffset)
            let newDataSize = fileSize &- 4096
            let existing = sizeBytes.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }

            if existing == newDataSize { return false }

            // Patch RIFF size (offset 4) and data size (offset 4092).
            let newRiffSize = fileSize &- 8
            var riffLE = newRiffSize.littleEndian
            var dataLE = newDataSize.littleEndian
            try handle.seek(toOffset: 4)
            try handle.write(contentsOf: Data(bytes: &riffLE, count: 4))
            try handle.seek(toOffset: 4092)
            try handle.write(contentsOf: Data(bytes: &dataLE, count: 4))
            Logger.general.info("WAV header repaired for \(url.lastPathComponent, privacy: .public) (data=\(newDataSize, privacy: .public) bytes)")
            return true
        } catch {
            Logger.general.warning("WAV header repair failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
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
            // Pull candidate meetings: completed/transcribing AND have an
            // audio reference somewhere AND don't have any transcript rows.
            // Note: we check BOTH `audioFilePath` (legacy single-path column,
            // still populated for old meetings) and `audioFilePaths` (current
            // JSON-array column). Without the second check, the orphan scan
            // misses meetings recorded after the v6-ish schema change.
            let candidates: [Meeting] = try await database.writer.read { db in
                try Meeting.fetchAll(db, sql: """
                    SELECT m.* FROM meeting m
                    WHERE (
                            (m.audioFilePath IS NOT NULL AND m.audioFilePath != '')
                            OR (m.audioFilePaths IS NOT NULL
                                AND m.audioFilePaths != ''
                                AND m.audioFilePaths != '[]')
                          )
                      AND m.status IN ('transcribing', 'complete')
                      AND NOT EXISTS (SELECT 1 FROM transcript t WHERE t.meetingId = m.id)
                      AND m.transcriptionAttemptedAt IS NULL
                    LIMIT 50
                """)
            }

            // Filter out:
            //   1. Meetings whose audio files no longer exist on disk —
            //      otherwise we re-enqueue forever (transcription completes
            //      with zero rows, orphan scan re-fires on next launch). The
            //      proper fix is to also clear the missing path so the row
            //      stops matching the candidate query.
            //   2. Meetings that already have a recent transcription task —
            //      whether running, pending, completed, or failed-with-max-
            //      retries. The `enqueue` call itself dedups pending+running,
            //      but it does NOT dedup against `completed` or `failed`,
            //      which is exactly what causes the user-visible "the same
            //      tasks every launch" loop.
            var needTranscription: [Meeting] = []
            for meeting in candidates {
                if !meetingHasReachableAudio(meeting) {
                    Logger.general.info("TaskQueue: clearing audio paths for \(meeting.id, privacy: .public) (\(meeting.title, privacy: .public)) — files missing on disk")
                    try? await clearMissingAudioPaths(for: meeting)
                    continue
                }
                if try await meetingHasRecentTranscriptionAttempt(meeting) {
                    continue
                }
                needTranscription.append(meeting)
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

    // MARK: - Orphan-scan helpers

    /// True when at least one of the meeting's audio file references points
    /// at an actual file on disk. Otherwise the orphan scan would re-enqueue
    /// transcription forever for meetings whose audio was deleted.
    private func meetingHasReachableAudio(_ meeting: Meeting) -> Bool {
        let fm = FileManager.default
        for path in meeting.audioFilePaths where !path.isEmpty {
            if fm.fileExists(atPath: path) { return true }
        }
        // Legacy single-path column — last-resort check.
        // (Meeting.audioFilePath is computed from audioFilePaths.first; this
        // path covers rows where only the legacy column was populated and
        // never migrated into the JSON array.)
        return false
    }

    /// True when this meeting has had a transcription task attempted
    /// recently — pending, running, completed, OR failed-with-max-retries.
    /// Without this gate, every app launch re-enqueues a fresh task for
    /// meetings whose previous transcription completed with no transcript
    /// rows (e.g. the audio file existed but produced no segments). That's
    /// the loop the user-facing "same set of meetings transcribing every
    /// update" complaint comes from.
    private func meetingHasRecentTranscriptionAttempt(_ meeting: Meeting) async throws -> Bool {
        try await database.writer.read { db in
            let count = try TaskQueueItem
                .filter(TaskQueueItem.Columns.meetingId == meeting.id)
                .filter(TaskQueueItem.Columns.type == TaskQueueItem.TaskType.transcription.rawValue)
                .fetchCount(db)
            return count > 0
        }
    }

    /// Clear stale audio path references on a meeting whose files are gone.
    /// Empties both the legacy single-path column and the JSON array so the
    /// orphan scan stops matching this row. Doesn't change meeting status —
    /// the row stays as `.complete` so it still appears in history; it just
    /// no longer claims to have audio.
    private func clearMissingAudioPaths(for meeting: Meeting) async throws {
        try await database.writer.write { db in
            try db.execute(
                sql: "UPDATE meeting SET audioFilePath = NULL, audioFilePaths = '[]' WHERE id = ?",
                arguments: [meeting.id]
            )
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
            currentProgress = Self.initialProgress(for: next.type)
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

                // Auto-enqueue diarization + summary + cleanup after transcription —
                // but only if segments exist
                if next.type == .transcription {
                    let hasSegments = (try? await database.writer.read { db in
                        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcript WHERE meetingId = ?", arguments: [next.meetingId])
                    } ?? 0) ?? 0
                    if hasSegments > 0 {
                        // Diarization runs before summary so speaker names are in the transcript
                        // when the summarizer prompt is built.
                        await enqueue(type: .diarization, meetingId: next.meetingId, priority: 4)
                        await enqueue(type: .summary, meetingId: next.meetingId, priority: 5)
                        // Transcript cleanup runs after summary — by then speaker
                        // names are mostly resolved, so the cleaned blob shows
                        // real names instead of "Speaker 1". Lower priority so
                        // it doesn't gate the user-facing summary.
                        await enqueue(type: .transcriptCleanup, meetingId: next.meetingId, priority: 3)
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
            currentProgress = nil
            await refreshTaskList()
        }
    }

    // MARK: - Progress reporting

    /// Handlers call this between stages to surface what they're doing.
    /// `fraction` is optional; pass it only when work proceeds in genuinely
    /// measurable chunks (KB indexing, batch enrichment). For single-shot
    /// LLM calls leave `fraction` nil — the stage label is honest enough,
    /// a fabricated percentage isn't.
    func reportCurrentProgress(stage: String, fraction: Double? = nil) {
        let clamped: Double? = fraction.map { max(0, min(1, $0)) }
        currentProgress = TaskProgress(stage: stage, fraction: clamped, updatedAt: Date())
    }

    /// Initial stage label shown the instant a task starts running, before
    /// the handler reports anything. Keeps the UI from flashing "Running"
    /// with no detail.
    private static func initialProgress(for type: TaskQueueItem.TaskType) -> TaskProgress {
        let stage: String
        switch type {
        case .transcription:      stage = "Loading audio"
        case .diarization:        stage = "Preparing diarization"
        case .summary:            stage = "Drafting summary"
        case .enrichment:         stage = "Enriching"
        case .regeneration:       stage = "Regenerating"
        case .contextEnrichment:  stage = "Finding related meetings"
        case .knowledgeBaseIndex: stage = "Indexing"
        case .transcriptCleanup:  stage = "Cleaning transcript"
        case .retryAttribution:   stage = "Re-checking speakers"
        case .detailedOutline:    stage = "Generating outline"
        }
        return TaskProgress(stage: stage, fraction: nil, updatedAt: Date())
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

        case .knowledgeBaseIndex:
            guard let handler = knowledgeBaseIndexHandler else {
                throw TaskQueueError.noHandler("knowledgeBaseIndex")
            }
            try await handler()

        case .transcriptCleanup:
            guard let handler = transcriptCleanupHandler else {
                throw TaskQueueError.noHandler("transcriptCleanup")
            }
            try await handler(task.meetingId)

        case .retryAttribution:
            guard let handler = retryAttributionHandler else {
                throw TaskQueueError.noHandler("retryAttribution")
            }
            try await handler(task.meetingId)

        case .detailedOutline:
            guard let handler = detailedOutlineHandler else {
                throw TaskQueueError.noHandler("detailedOutline")
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

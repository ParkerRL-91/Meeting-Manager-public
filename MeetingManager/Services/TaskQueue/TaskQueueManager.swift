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
    var transcriptionHandler: ((String, URL?, String?) async throws -> Void)?

    /// Fired once each time the queue transitions from busy to idle (no pending
    /// or running tasks). Lets callers run deferred work that needs the AI
    /// backend free — e.g. regenerating a daily brief that was queued while a
    /// bulk re-transcription saturated the local model.
    var onQueueIdle: (() async -> Void)?
    private var idleNotified = false
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
    /// PRJ-007: "Enhance Notes" — rewrites the user's raw notes into a polished
    /// version in their own structure. Never auto-enqueued; the user triggers
    /// it from the Notes tab or the live notepad button.
    var enhanceNotesHandler: ((String) async throws -> Void)?

    /// PRJ-009 TASK-045: semantic-index a meeting (or run the backfill
    /// sentinel). Wired by AppState like every other handler.
    var embedIndexHandler: ((String) async throws -> Void)?

    /// PRJ-009 TASK-051: weekly digest generation (sentinel meetingId).
    var weeklyDigestHandler: (() async throws -> Void)?
    var gardenerHandler: (() async throws -> Void)?
    var factBackfillHandler: (() async throws -> Void)?
    var glossaryHandler: (() async throws -> Void)?
    var speechStatsHandler: (() async throws -> Void)?
    var sentimentBackfillHandler: (() async throws -> Void)?
    var topicBackfillHandler: (() async throws -> Void)?

    /// Returns true when an AI backend (Claude key or Ollama) is configured.
    /// Set by AppState. AI-dependent tasks (summary) are only auto-enqueued
    /// when this is true, so a user with no AI configured doesn't get a failed
    /// summary task — and a red error banner — after every meeting. Defaults
    /// to permissive (true) when unset so behaviour is unchanged if not wired.
    var isAIWorkConfigured: (() -> Bool)?

    /// Whether AI-dependent work should be auto-enqueued right now.
    private var shouldEnqueueAIWork: Bool { isAIWorkConfigured?() ?? true }

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
        // Scan every known recording location (custom override, if set, plus the
        // default), so orphaned WAVs are recovered wherever storage was configured.
        let entries: [URL] = RecordingStorage.knownAudioDirectories().flatMap { dir -> [URL] in
            guard fm.fileExists(atPath: dir.path),
                  let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
            return contents
        }
        guard !entries.isEmpty else { return }

        // Map: meetingId UUID → main wav URLs (skip _system.wav siblings).
        // A meeting can have several main WAVs: the canonical <uuid>.wav plus
        // <uuid>-<stamp>.wav files from reopen/resume sessions.
        var byMeeting: [String: [URL]] = [:]
        for url in entries {
            let name = url.lastPathComponent
            guard name.hasSuffix(".wav"), !name.hasSuffix("_system.wav") else { continue }
            let base = url.deletingPathExtension().lastPathComponent
            let meetingId = String(base.prefix(36))
            guard UUID(uuidString: meetingId) != nil else { continue }
            byMeeting[meetingId, default: []].append(url)
        }
        guard !byMeeting.isEmpty else { return }

        var repaired = 0
        var reattached = 0
        for (meetingId, urls) in byMeeting {
            // Repair zero-data WAV headers in place if needed (main + system).
            for url in urls where Self.repairWavHeaderIfNeeded(at: url) {
                repaired += 1
                _ = Self.repairWavHeaderIfNeeded(at: AudioBufferManager.systemAudioURL(for: url))
            }

            // Re-attach when the meeting row exists but has no audio path.
            // Writes the JSON `audioFilePaths` column via the model — the
            // legacy `audioFilePath` column is computed-only and never read,
            // so a raw UPDATE against it re-attaches nothing.
            let attachURL = urls.first { $0.lastPathComponent == "\(meetingId).wav" } ?? urls.sorted { $0.lastPathComponent < $1.lastPathComponent }[0]
            do {
                let didAttach = try await database.writer.write { db -> Bool in
                    guard var m = try Meeting.fetchOne(db, key: meetingId) else { return false }
                    guard m.audioFilePaths.isEmpty else { return false }
                    m.audioFilePaths.append(attachURL.path)
                    if m.status == .scheduled { m.status = .transcribing }
                    try m.update(db)
                    return true
                }
                guard didAttach else { continue }
                reattached += 1
                Logger.general.info("TaskQueue: re-attached orphan audio \(attachURL.lastPathComponent, privacy: .public) to meeting \(meetingId, privacy: .public)")
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
        AppFileLogger.shared.log("TaskQueue: enqueue requested — \(type.rawValue)/\(meetingId)")
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
                AppFileLogger.shared.log("TaskQueue: skipped duplicate \(type.rawValue)/\(meetingId)")
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
            AppFileLogger.shared.log("TaskQueue: enqueued \(type.rawValue)/\(meetingId) prio \(priority)")
            await refreshTaskList()
            kickProcessor()
            return item
        } catch {
            Logger.general.error("TaskQueue: failed to enqueue: \(error.localizedDescription)")
            // TASK-073: enqueue failures were invisible (os_log only) — the
            // 2026-06-11 embed-backfill vanishing act proved that's a trap.
            AppFileLogger.shared.log("TaskQueue: ENQUEUE FAILED for \(type.rawValue)/\(meetingId): \(error.localizedDescription)")
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

    /// User escape hatch: wipe the ENTIRE queue — pending, running, completed,
    /// and failed — and stop the in-flight task. This is the "a task is wedged,
    /// just reset everything" button, deliberately blunt rather than a graceful
    /// per-task cancel: we cancel the processor (which cooperatively cancels the
    /// running `execute()`), delete every row, and reset live state so the queue
    /// returns to empty. A re-enqueue (or app restart) restarts the processor.
    func clearAll() async {
        // Stop the processor first so the in-flight task is cancelled and the
        // loop can neither pop more work nor re-mark a row we're about to delete.
        processorTask?.cancel()
        processorTask = nil
        currentTask = nil
        currentProgress = nil
        idleNotified = false
        do {
            try await database.writer.write { db in
                _ = try TaskQueueItem.deleteAll(db)
            }
            Logger.general.info("TaskQueue: clearAll — queue wiped by user")
            AppFileLogger.shared.log("TaskQueue: clearAll — queue wiped by user")
        } catch {
            Logger.general.error("TaskQueue: clearAll failed: \(error.localizedDescription)")
        }
        await refreshTaskList()
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
            for candidate in candidates {
                let meeting = await promoteLegacyAudioPathIfNeeded(candidate)
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

            var enqueuedSummaries = 0
            if shouldEnqueueAIWork {
                for meeting in needSummary where try await !meetingHasRecentSummaryAttempt(meeting) {
                    await enqueue(type: .summary, meetingId: meeting.id, priority: 6)
                    enqueuedSummaries += 1
                }
            }

            let total = needTranscription.count + enqueuedSummaries
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
        return false
    }

    /// Pre-JSON-array rows may carry their audio only in the legacy
    /// `audioFilePath` DB column, which the model no longer decodes
    /// (`Meeting.audioFilePath` is computed from `audioFilePaths.first`).
    /// Promote a reachable legacy path into `audioFilePaths` so downstream
    /// resolution (task execution, reachability checks) can see it — without
    /// this, the orphan scan wipes the legacy row's only audio reference.
    private func promoteLegacyAudioPathIfNeeded(_ meeting: Meeting) async -> Meeting {
        guard meeting.audioFilePaths.isEmpty else { return meeting }
        let legacy: String? = try? await database.writer.read { db in
            try String.fetchOne(db, sql: "SELECT audioFilePath FROM meeting WHERE id = ?", arguments: [meeting.id])
        }
        guard let legacy, !legacy.isEmpty, FileManager.default.fileExists(atPath: legacy) else { return meeting }
        var promoted = meeting
        promoted.audioFilePaths = [legacy]
        let updated = promoted
        do {
            try await database.writer.write { db in try updated.update(db) }
            Logger.general.info("TaskQueue: promoted legacy audio path into audioFilePaths for \(meeting.id, privacy: .public)")
        } catch {
            Logger.general.warning("TaskQueue: legacy path promotion failed for \(meeting.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        return updated
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

    /// True when this meeting already has a summary task row in ANY state.
    /// `enqueue` only dedups pending+running, so without this gate a meeting
    /// whose summary permanently fails (Ollama stopped, model not pulled,
    /// revoked key) is re-enqueued by the 15-minute poll forever — a fresh
    /// task row plus two LLM attempts per cycle, around the clock. Same
    /// pattern as `meetingHasRecentTranscriptionAttempt`; the user can still
    /// regenerate manually.
    private func meetingHasRecentSummaryAttempt(_ meeting: Meeting) async throws -> Bool {
        try await database.writer.read { db in
            let count = try TaskQueueItem
                .filter(TaskQueueItem.Columns.meetingId == meeting.id)
                .filter(TaskQueueItem.Columns.type == TaskQueueItem.TaskType.summary.rawValue)
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
                // Queue is drained — fire the idle hook once per busy→idle
                // edge, then PARK. enqueue()/retry() restart the processor
                // via kickProcessor(); the old 5-second sleep-and-poll ran
                // ~17K needless DB reads a day in an app meant to idle
                // quietly for hours.
                if !idleNotified {
                    idleNotified = true
                    if let onQueueIdle { await onQueueIdle() }
                }
                // Deferred work exists? Schedule a one-shot wake at the
                // earliest runAfter (review M2 — parked processors never
                // re-poll; the hourly tick is only the backstop).
                if let wake = await earliestDeferredWake() {
                    let delay = max(5, wake.timeIntervalSinceNow)
                    Task { [weak self] in
                        try? await Task.sleep(for: .seconds(delay))
                        await MainActor.run { self?.reevaluate() }
                    }
                }
                processorTask = nil
                // Lost-wakeup guard: an enqueue can land during the drain
                // check above, see processorTask != nil, and skip the kick.
                // One re-check after clearing the handle closes that window
                // (everything here is MainActor-serialized).
                if await fetchNextPending() != nil { kickProcessor() }
                return
            }
            idleNotified = false

            // Governor gate (TASK-055): background-class items consult the
            // policy at pop time. Defer = one bulk UPDATE for all pending
            // background rows, then continue with whatever's runnable.
            // Pipeline tasks never pass through here, and a running task is
            // never preempted.
            if TaskQueueItem.isBackgroundItem(type: next.type, meetingId: next.meetingId),
               let inputs = backgroundPolicyInputs?() {
                if case .deferFor(let minutes) = BackgroundWorkPolicy.decision(inputs) {
                    Logger.general.info("TaskQueue: deferring background work \(next.type.rawValue) for \(minutes)m (recording=\(inputs.isRecording), nextMeeting=\(inputs.minutesToNextMeeting.map(String.init) ?? "none")m, battery=\(inputs.onBattery))")
                    let deferred = await deferPendingBackgroundRows(minutes: minutes)
                    // Backstop: the defer must make `next` non-runnable, or the
                    // loop re-pops the same row at CPU rate — there is no other
                    // suspension on this path. If the write didn't land, back off
                    // so a failed defer can never peg a core.
                    if !deferred { try? await Task.sleep(for: .seconds(1)) }
                    continue
                }
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
                        // Queued diarization is for LEGACY rows only: the batch
                        // transcription path diarizes inline and writes
                        // "Speaker N" labels directly, so re-running the full
                        // diarizer here would double minutes of work per
                        // meeting for an identical result. Only pre-v4 rows
                        // still carry the "system" bucket this task exists for.
                        let hasLegacySystemRows = (try? await database.writer.read { db in
                            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcript WHERE meetingId = ? AND LOWER(speakerLabel) = 'system'", arguments: [next.meetingId])
                        } ?? 0) ?? 0
                        if hasLegacySystemRows > 0 {
                            await enqueue(type: .diarization, meetingId: next.meetingId, priority: 4)
                        }
                        // Only enqueue the AI summary when a backend is configured,
                        // so no-AI users don't get a failed task after every meeting.
                        if shouldEnqueueAIWork {
                            await enqueue(type: .summary, meetingId: next.meetingId, priority: 5)
                        }
                        // Transcript cleanup runs after diarization and summary —
                        // by then speaker names are mostly resolved, so the
                        // cleaned blob shows real names instead of "Speaker 1",
                        // and it doesn't gate the user-facing summary. The queue
                        // pops LOWEST priority number first, so "after" means a
                        // HIGHER number than summary (5) — the old priority 3
                        // ran cleanup first, the exact gating this comment
                        // promises to avoid.
                        await enqueue(type: .transcriptCleanup, meetingId: next.meetingId, priority: 6)
                    } else {
                        Logger.general.info("TaskQueue: transcription produced 0 segments for \(next.meetingId) — skipping diarization + summary")
                    }
                }
            } catch {
                let shouldRetry = next.retryCount + 1 < next.maxRetries
                await markFailed(next, error: Self.humanizedTaskError(error), willRetry: shouldRetry)
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

    /// The failed-task row is read by a person. Raw OS error strings —
    /// "The operation couldn't be completed. (com.apple.coreaudio.avfaudio
    /// error -50.)" — explain nothing and look like a crash (TASK-031).
    /// Translate the codes we actually see; pass through messages that are
    /// already human (LocalizedError descriptions from our own types). The
    /// numeric code stays in parentheses for support/debugging.
    nonisolated static func humanizedTaskError(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSOSStatusErrorDomain
            || ns.domain.lowercased().contains("coreaudio")
            || ns.domain.lowercased().contains("avfaudio") {
            switch ns.code {
            case -50:
                return "This recording's audio file couldn't be read — it may be incomplete or damaged. (CoreAudio -50)"
            case -10868:
                return "The audio device didn't accept the requested format. Retrying usually succeeds once the device settles. (CoreAudio -10868)"
            default:
                return "An audio system error interrupted this task. Retry usually succeeds. (CoreAudio \(ns.code))"
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return "No internet connection — this task will succeed when you're back online."
            case .timedOut:
                return "The network request timed out. Retry when your connection is stable."
            default:
                break
            }
        }
        return error.localizedDescription
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
        case .enhanceNotes:       stage = "Enhancing notes"
        case .embedIndex:         stage = "Indexing for search"
        case .weeklyDigest:       stage = "Writing weekly digest"
        case .gardener:           stage = "Tidying knowledge"
        case .factBackfill:       stage = "Extracting insights from history"
        case .glossary:           stage = "Updating glossary"
        case .speechStats:        stage = "Computing speaking stats"
        case .sentimentBackfill:  stage = "Reading tone"
        case .topicBackfill:      stage = "Scanning topics"
        }
        return TaskProgress(stage: stage, fraction: nil, updatedAt: Date())
    }

    private func fetchNextPending() async -> TaskQueueItem? {
        try? await database.writer.read { db in
            try TaskQueueItem
                .filter(TaskQueueItem.Columns.status == TaskQueueItem.TaskStatus.pending.rawValue)
                .filter(sql: "runAfter IS NULL OR runAfter <= ?", arguments: [Date()])
                .order(TaskQueueItem.Columns.priority.asc, TaskQueueItem.Columns.createdAt.asc)
                .fetchOne(db)
        }
    }

    /// Earliest future runAfter among pending rows — the park-time wake
    /// target (review M2: a parked processor never re-checks on its own).
    private func earliestDeferredWake() async -> Date? {
        try? await database.writer.read { db in
            try Date.fetchOne(db, sql: """
                SELECT MIN(runAfter) FROM taskQueue
                WHERE status = 'pending' AND runAfter > ?
                """, arguments: [Date()])
        }
    }

    /// Governor inputs, injected by AppState (recording state, meeting
    /// proximity, thermal, battery setting, broker pressure).
    var backgroundPolicyInputs: (() -> BackgroundWorkPolicy.Inputs)?

    /// Public poke: re-evaluate deferred work now (recording stopped,
    /// hourly tick, Ollama became reachable). Safe to call any time.
    func reevaluate() {
        kickProcessor()
    }

    /// Defer ALL currently-pending background rows in one statement
    /// (review M2: per-pop writes are O(n) churn for a fanned-out batch).
    ///
    /// The deferred set MUST equal `isBackgroundItem`'s set: the processLoop
    /// gate fires for every background type, so any row it can pop must get a
    /// runAfter here — otherwise the loop hot-spins re-popping the uncovered
    /// row (it was a hardcoded `embedIndex`/`weeklyDigest` list that silently
    /// fell out of sync as background types were added). Filtering by the same
    /// predicate makes that drift impossible. Returns false if the write fails,
    /// so the caller can back off instead of busy-looping.
    private func deferPendingBackgroundRows(minutes: Int) async -> Bool {
        let now = Date()
        let until = now.addingTimeInterval(Double(minutes) * 60)
        let ok: Bool
        do {
            try await database.writer.write { db in
                let pending = try TaskQueueItem
                    .filter(TaskQueueItem.Columns.status == TaskQueueItem.TaskStatus.pending.rawValue)
                    .fetchAll(db)
                let ids = pending
                    .filter { TaskQueueItem.isBackgroundItem(type: $0.type, meetingId: $0.meetingId) }
                    .map(\.id)
                guard !ids.isEmpty else { return }
                let placeholders = ids.map { _ in "?" }.joined(separator: ",")
                // firstDeferredAt is stamped once and preserved via COALESCE so
                // the starvation clock measures continuous-deferral age, not the
                // age of the most recent defer (TASK-093). Cleared in markRunning.
                var arguments: [DatabaseValueConvertible] = [until, now]
                arguments.append(contentsOf: ids)
                try db.execute(
                    sql: "UPDATE taskQueue SET runAfter = ?, firstDeferredAt = COALESCE(firstDeferredAt, ?) WHERE id IN (\(placeholders))",
                    arguments: StatementArguments(arguments)
                )
            }
            ok = true
        } catch {
            AppFileLogger.shared.log("TaskQueue: deferPendingBackgroundRows failed — \(error.localizedDescription)")
            Logger.general.error("TaskQueue: deferPendingBackgroundRows failed: \(error.localizedDescription)")
            ok = false
        }
        await refreshTaskList()
        return ok
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
            try await handler(task.meetingId, audioURL, task.metadata)

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

        case .embedIndex:
            guard let handler = embedIndexHandler else {
                throw TaskQueueError.noHandler("embedIndex")
            }
            try await handler(task.meetingId)

        case .weeklyDigest:
            guard let handler = weeklyDigestHandler else {
                throw TaskQueueError.noHandler("weeklyDigest")
            }
            try await handler()

        case .gardener:
            guard let handler = gardenerHandler else {
                throw TaskQueueError.noHandler("gardener")
            }
            try await handler()

        case .factBackfill:
            guard let handler = factBackfillHandler else {
                throw TaskQueueError.noHandler("factBackfill")
            }
            try await handler()

        case .glossary:
            guard let handler = glossaryHandler else {
                throw TaskQueueError.noHandler("glossary")
            }
            try await handler()

        case .speechStats:
            guard let handler = speechStatsHandler else {
                throw TaskQueueError.noHandler("speechStats")
            }
            try await handler()

        case .sentimentBackfill:
            guard let handler = sentimentBackfillHandler else {
                throw TaskQueueError.noHandler("sentimentBackfill")
            }
            try await handler()

        case .topicBackfill:
            guard let handler = topicBackfillHandler else {
                throw TaskQueueError.noHandler("topicBackfill")
            }
            try await handler()

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

        case .enhanceNotes:
            guard let handler = enhanceNotesHandler else {
                throw TaskQueueError.noHandler("enhanceNotes")
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
                // The row got a turn — reset its starvation clock so a later
                // re-defer (e.g. after a retry) starts fresh (TASK-093).
                t.firstDeferredAt = nil
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
            var enqueued = 0
            if shouldEnqueueAIWork {
                for meeting in needSummary where try await !meetingHasRecentSummaryAttempt(meeting) {
                    await enqueue(type: .summary, meetingId: meeting.id, priority: 8)
                    enqueued += 1
                }
            }
            if enqueued > 0 {
                Logger.general.info("TaskQueue: poll enqueued \(enqueued) meeting(s) needing summaries")
            }
        } catch {
            Logger.general.error("TaskQueue: poll failed: \(error.localizedDescription)")
        }
        // Safety kick regardless of what was enqueued above: the parked
        // processor's drain re-check is a `try?` read — a transient DB error
        // at exactly that instant could strand a pending row, and this
        // 15-minute tick is the only other periodic wake-up.
        kickProcessor()
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

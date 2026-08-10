import Foundation
import AVFoundation
import GRDB
import os

/// Archives a finished meeting's recordings from WAV to Apple Lossless `.m4a`
/// — about 5.5× smaller with a sample-exact, bit-identical round trip
/// (ADR-033 / TASK-135 Phase 0). Every consumer reads audio through
/// `AVAudioFile`, which vends Float32 for ALAC exactly as it does for PCM, so
/// playback, re-transcription, diarization, and voice profiles all keep working
/// against the archived file with no format-specific code.
///
/// The failure mode is lossless by construction: encode to a `.m4a.tmp`
/// sidecar, verify the decoded frame count against the source, swap the
/// verified file in atomically, and only then delete the WAV. Any failure at
/// any step leaves the original WAV in place and removes the temp.
///
/// A capture session's mixed WAV and its `_system` sibling are archived as ONE
/// unit. `AudioBufferManager.systemAudioURL(for:)` derives the sibling from the
/// mixed file's extension, so a half-migrated pair (`<stem>.m4a` next to
/// `<stem>_system.wav`) would silently resolve to a nonexistent sibling and
/// diarization would lose the remote-audio track.
enum AudioArchiveService {

    private static let logger = Logger(subsystem: "com.meetingmanager.app", category: "AudioArchive")

    /// Extension of an archived recording.
    static let archivedExtension = "m4a"

    /// Suffix of an in-progress encode. `AVAudioFile` picks the container from
    /// `AVFormatIDKey`, not from the path extension, so writing MPEG-4 to a
    /// `.tmp` path works — and the distinct suffix keeps a crashed encode from
    /// ever being mistaken for a finished archive.
    static let tempSuffix = "m4a.tmp"

    /// Apple Lossless, 16-bit, 16 kHz mono. The bit-depth hint is what makes
    /// the round trip bit-identical to the Int16 capture format; ALAC at 16
    /// kHz mono decodes to exactly the source frame count, which is what the
    /// verify step asserts.
    static var archiveSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatAppleLossless,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitDepthHintKey: 16
        ]
    }

    private static let expectedSampleRate: Double = 16_000
    private static let encodeBlockFrames: AVAudioFrameCount = 32_000

    // MARK: - Outcomes

    struct MeetingOutcome: Sendable {
        var sessionsArchived = 0
        /// Sessions whose encode/verify/swap genuinely failed. Their WAVs are
        /// untouched and the meeting can be re-archived later.
        var sessionsFailed = 0
        /// Sessions there was nothing to do for: already `.m4a`, a crash husk,
        /// or a file that isn't 16 kHz mono.
        var sessionsSkipped = 0
        /// Sessions whose files were already archived by an interrupted run but
        /// whose meeting row still named the deleted `.wav` — repointed here.
        var sessionsHealed = 0
        var bytesSaved: Int64 = 0
        var pathsChanged = false
    }

    enum ArchiveError: LocalizedError {
        case allSessionsFailed(meetingId: String, count: Int)
        case bufferAllocationFailed

        var errorDescription: String? {
            switch self {
            case .allSessionsFailed(_, let count):
                return "Couldn't compress \(count) recording file(s) — the originals were kept. Check free disk space and try again."
            case .bufferAllocationFailed:
                return "Couldn't allocate an audio buffer for compression."
            }
        }
    }

    // MARK: - Per-meeting archive

    /// Archive every WAV session of one meeting and repoint the meeting's audio
    /// columns at the archived files. Idempotent: sessions already stored as
    /// `.m4a` are skipped, never re-encoded. Partial progress is persisted, so
    /// an interrupted run resumes on the next pass.
    @discardableResult
    static func archiveMeeting(meetingId: String, database: AppDatabase) async throws -> MeetingOutcome {
        let paths: [String] = (try? await database.writer.read { db in
            try Meeting.fetchOne(db, key: meetingId)?.audioFilePaths ?? []
        }) ?? []
        guard !paths.isEmpty else { return MeetingOutcome() }

        // Encoding is CPU + disk bound; keep it off whatever actor called in.
        let result = await Task.detached(priority: .utility) { () -> (replacements: [String: String], outcome: MeetingOutcome) in
            var replacements: [String: String] = [:]
            var outcome = MeetingOutcome()
            for path in paths {
                switch plannedAction(for: path) {
                case .leave:
                    outcome.sessionsSkipped += 1
                case .healRepoint(let archived):
                    // Finish an interrupted run: the encode, verify, swap and
                    // delete all landed, only the row update was lost.
                    replacements[path] = archived
                    outcome.sessionsHealed += 1
                    outcome.pathsChanged = true
                case .archive:
                    let url = URL(fileURLWithPath: path)
                    switch archiveSession(mixedWav: url) {
                    case .archived(let bytesSaved):
                        outcome.sessionsArchived += 1
                        outcome.bytesSaved += bytesSaved
                        outcome.pathsChanged = true
                        replacements[path] = archivedURL(for: url).path
                    case .skipped:
                        outcome.sessionsSkipped += 1
                    case .failed:
                        outcome.sessionsFailed += 1
                    }
                }
            }
            return (replacements, outcome)
        }.value

        if result.outcome.pathsChanged {
            await repoint(meetingId: meetingId, replacing: result.replacements, database: database)
            logger.info("Archived \(result.outcome.sessionsArchived, privacy: .public) session(s) for meeting \(meetingId, privacy: .public), saved \(result.outcome.bytesSaved, privacy: .public) bytes, healed \(result.outcome.sessionsHealed, privacy: .public)")
            AppFileLogger.shared.log("AudioArchive: meeting \(meetingId) — \(result.outcome.sessionsArchived) session(s), saved \(result.outcome.bytesSaved) bytes, healed \(result.outcome.sessionsHealed)")
        }
        if result.outcome.sessionsArchived == 0, result.outcome.sessionsFailed > 0 {
            throw ArchiveError.allSessionsFailed(meetingId: meetingId, count: result.outcome.sessionsFailed)
        }
        return result.outcome
    }

    /// Swap the archived paths into the meeting row. Rewrites only the entries
    /// that were actually archived, re-read inside the transaction — a blind
    /// overwrite of the whole array would drop a session appended between the
    /// read and the write (a meeting reopened mid-archive).
    ///
    /// The JSON array goes through the model; the legacy `audioFilePath` column
    /// needs raw SQL because it is NOT part of the GRDB `Meeting` model (it's a
    /// computed property), so a model update alone would leave it pointing at a
    /// deleted WAV — the same reason `AudioRetention.sweep` clears it that way.
    private static func repoint(meetingId: String, replacing map: [String: String], database: AppDatabase) async {
        do {
            try await database.writer.write { db in
                guard var meeting = try Meeting.fetchOne(db, key: meetingId) else { return }
                meeting.audioFilePaths = meeting.audioFilePaths.map { map[$0] ?? $0 }
                let updated = meeting.audioFilePaths
                try meeting.update(db)
                try db.execute(
                    sql: "UPDATE meeting SET audioFilePath = ? WHERE id = ?",
                    arguments: [updated.first, meetingId])
            }
        } catch {
            // The files are already archived; a failed repoint leaves the row
            // pointing at deleted WAVs, so it must be loud.
            logger.error("Repoint failed for \(meetingId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            AppFileLogger.shared.log("AudioArchive: REPOINT FAILED for \(meetingId): \(error.localizedDescription)")
        }
    }

    // MARK: - Per-session archive (pure filesystem)

    enum SessionResult: Equatable {
        case archived(bytesSaved: Int64)
        case skipped
        case failed
    }

    /// The archived counterpart of a recording URL.
    nonisolated static func archivedURL(for url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension(archivedExtension)
    }

    nonisolated static func tempURL(for url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension(tempSuffix)
    }

    /// What one tracked `audioFilePaths` entry needs. Pure filesystem decision,
    /// separated out so the resume/self-heal rule is testable on its own.
    enum PathAction: Equatable {
        /// A `.wav` session that is present and should be encoded.
        case archive
        /// The `.wav` is gone but its archive is on disk — an earlier run
        /// swapped and deleted, then died before repointing the row. The files
        /// are already correct; only the DB entry is missing.
        case healRepoint(String)
        /// Nothing to do: already archived, not a recording, or gone entirely.
        case leave
    }

    /// Decide what to do with one tracked path.
    ///
    /// The `healRepoint` case is what keeps an interrupted archive from
    /// stranding a meeting forever: without it, the vanished `.wav` is simply
    /// skipped on every later pass, the row keeps naming a deleted file, and
    /// `TaskQueueManager`'s missing-audio reconciliation eventually clears the
    /// meeting's paths outright — discarding a perfectly good `.m4a` that is
    /// sitting right next to them.
    nonisolated static func plannedAction(for path: String) -> PathAction {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: path)
        guard url.pathExtension.lowercased() == "wav" else { return .leave }
        if fm.fileExists(atPath: path) { return .archive }
        let archived = archivedURL(for: url)
        return fm.fileExists(atPath: archived.path) ? .healRepoint(archived.path) : .leave
    }

    /// Positive identification of a recording that holds NO audio and never
    /// will: either a zero-byte file, or a parseable RIFF whose payload is
    /// empty. Deliberately NOT the complement of `containsAudioBytes`, which
    /// also returns false when the header can't be parsed at all — a recording
    /// killed before `AVAudioFile.close` declares size 0 while holding hours of
    /// real audio, and `TaskQueueManager.repairWavHeaderIfNeeded` exists to
    /// recover exactly that. Treating an unparseable header as "empty" would
    /// delete it.
    nonisolated static func isEmptyRecording(_ url: URL) -> Bool {
        let bytes = fileSize(url)
        if bytes == 0 { return true }
        guard let chunk = WavFileLayout.findDataChunk(atPath: url.path) else { return false }
        return bytes <= Int64(chunk.payloadOffset)
    }

    /// Archive one capture session — the mixed WAV plus its `_system` sibling
    /// when present — as an atomic unit: encode + verify BOTH, then swap both,
    /// then delete both originals.
    nonisolated static func archiveSession(mixedWav: URL) -> SessionResult {
        let fm = FileManager.default
        // Anything already archived is done — and re-entering with a `.m4a`
        // would resolve source and destination to the SAME path, so the guard
        // is what keeps a repeat run from swapping a file with itself.
        guard mixedWav.pathExtension.lowercased() == "wav" else { return .skipped }
        guard fm.fileExists(atPath: mixedWav.path) else { return .skipped }

        var sources = [mixedWav]
        // A `_system` sibling that holds no audio (the capture never got a
        // system stream: header only) is treated as absent rather than as a
        // session to archive — otherwise its unarchivable-ness would block the
        // mixed file, which on this library is 915 MB across 6 meetings.
        // `isEmptyRecording` demands POSITIVE proof of emptiness; anything else,
        // including a header we can't parse, goes into `sources` so the encode
        // path refuses it and the whole session ends `.skipped`.
        var emptySystemHusk: URL?
        let systemWav = AudioBufferManager.systemAudioURL(for: mixedWav)
        if fm.fileExists(atPath: systemWav.path) {
            if isEmptyRecording(systemWav) {
                emptySystemHusk = systemWav
            } else {
                sources.append(systemWav)
            }
        }

        let sourceBytes = sources.reduce(Int64(0)) { $0 + fileSize($1) }
        guard sourceBytes > 0 else { return .skipped }
        // The temp lives beside the source, so the encode needs room for it
        // alongside the original. Requiring the full source size is generous
        // (the archive is ~5× smaller) and cheap.
        if let available = availableBytes(at: mixedWav.deletingLastPathComponent()), available < sourceBytes {
            logger.warning("Skipping archive of \(mixedWav.lastPathComponent, privacy: .public): \(available, privacy: .public) bytes free, need \(sourceBytes, privacy: .public)")
            return .failed
        }

        var staged: [(source: URL, temp: URL, destination: URL)] = []
        func discardTemps() { for item in staged { try? fm.removeItem(at: item.temp) } }

        for source in sources {
            switch encodeAndVerify(source) {
            case .success(let temp):
                staged.append((source, temp, archivedURL(for: source)))
            case .skip:
                // A husk or an off-format file can't be archived, and archiving
                // only half of a session would strand the sibling. Leave the
                // whole session alone.
                discardTemps()
                return .skipped
            case .failure:
                discardTemps()
                return .failed
            }
        }
        guard !staged.isEmpty else { return .skipped }

        var swapped: [(temp: URL, destination: URL)] = []
        for item in staged {
            do {
                if fm.fileExists(atPath: item.destination.path) {
                    _ = try fm.replaceItemAt(item.destination, withItemAt: item.temp)
                } else {
                    try fm.moveItem(at: item.temp, to: item.destination)
                }
                swapped.append((item.temp, item.destination))
            } catch {
                // Undo the swaps that landed so the session stays entirely on
                // its untouched WAVs rather than half migrated.
                for done in swapped { try? fm.moveItem(at: done.destination, to: done.temp) }
                discardTemps()
                logger.error("Archive swap failed for \(item.source.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return .failed
            }
        }

        var saved: Int64 = 0
        for item in staged {
            let before = fileSize(item.source)
            let after = fileSize(item.destination)
            do {
                try fm.removeItem(at: item.source)
                saved += max(0, before - after)
            } catch {
                // The archive is verified and in place; a stuck original is
                // wasted space, not data loss. The next pass retries the
                // delete because the WAV is still on disk.
                logger.warning("Couldn't remove archived original \(item.source.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        // The empty sibling is unreachable now — `systemAudioURL` resolves off
        // the archived `.m4a` — and it holds zero audio frames, so keeping it
        // would only leave the library permanently "partly uncompressed".
        if let husk = emptySystemHusk {
            let before = fileSize(husk)
            do {
                try fm.removeItem(at: husk)
                saved += before
            } catch {
                logger.warning("Couldn't remove empty system husk \(husk.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return .archived(bytesSaved: saved)
    }

    private enum EncodeResult {
        case success(temp: URL)
        case skip
        case failure
    }

    /// Encode one WAV to a verified `.m4a.tmp` beside it. The temp is only
    /// returned after reopening it and confirming 16 kHz mono and an EXACTLY
    /// equal decoded frame count — the guarantee that makes deleting the source
    /// safe, and the check that catches a truncated or resampled encode.
    private nonisolated static func encodeAndVerify(_ source: URL) -> EncodeResult {
        guard let input = try? AVAudioFile(forReading: source) else { return .skip }
        let sourceLength = input.length
        guard sourceLength > 0,
              input.fileFormat.sampleRate == expectedSampleRate,
              input.fileFormat.channelCount == 1 else { return .skip }

        let temp = tempURL(for: source)
        try? FileManager.default.removeItem(at: temp)
        do {
            // Scoped so the writer is released — AVAudioFile has no close();
            // the MPEG-4 trailer is only written when it deallocates, and the
            // verify below reopens the file.
            try writeArchive(from: input, to: temp)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            logger.error("Archive encode failed for \(source.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return .failure
        }

        guard let check = try? AVAudioFile(forReading: temp),
              check.fileFormat.sampleRate == expectedSampleRate,
              check.fileFormat.channelCount == 1,
              check.length == sourceLength else {
            let detail = (try? AVAudioFile(forReading: temp)).map { "\($0.length) frames vs \(sourceLength)" } ?? "unreadable"
            try? FileManager.default.removeItem(at: temp)
            logger.error("Archive verify failed for \(source.lastPathComponent, privacy: .public): \(detail, privacy: .public)")
            return .failure
        }
        return .success(temp: temp)
    }

    /// Streaming copy in `encodeBlockFrames` blocks, mirroring
    /// `AudioBufferManager.mergeMixIntoFile`: bound each read by the frames
    /// remaining, because `read(into:frameCount:)` throws at EOF when asked for
    /// more than the file holds.
    private nonisolated static func writeArchive(from input: AVAudioFile, to temp: URL) throws {
        let output = try AVAudioFile(forWriting: temp, settings: archiveSettings)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: encodeBlockFrames) else {
            throw ArchiveError.bufferAllocationFailed
        }
        input.framePosition = 0
        while input.framePosition < input.length {
            let remaining = input.length - input.framePosition
            buffer.frameLength = 0
            try input.read(into: buffer, frameCount: AVAudioFrameCount(min(Int64(encodeBlockFrames), remaining)))
            guard buffer.frameLength > 0 else { break }
            try output.write(from: buffer)
        }
    }

    // MARK: - Startup reconciliation

    /// Delete `*.m4a.tmp` left behind by an encode that was killed mid-write.
    /// A temp is never the only copy of anything — the source WAV is deleted
    /// only after the temp has been verified AND swapped — so removing them is
    /// always safe. Returns how many were removed.
    @discardableResult
    nonisolated static func sweepOrphanTempFiles() -> Int {
        let fm = FileManager.default
        var removed = 0
        for dir in RecordingStorage.knownAudioDirectories() {
            guard let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for url in contents where url.lastPathComponent.hasSuffix(".\(tempSuffix)") {
                do {
                    try fm.removeItem(at: url)
                    removed += 1
                } catch {
                    logger.warning("Couldn't remove orphan temp \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        if removed > 0 {
            logger.info("Swept \(removed, privacy: .public) orphaned archive temp file(s)")
        }
        return removed
    }

    // MARK: - Eligibility and size reporting

    /// True when this meeting has archive work outstanding: a `.wav` session to
    /// compress, OR files an interrupted run already archived whose row still
    /// names the deleted `.wav`. The second case must count — it is the only way
    /// a stranded row is ever offered to a pass that can repoint it.
    nonisolated static func hasArchivableAudio(_ meeting: Meeting) -> Bool {
        meeting.audioFilePaths.contains { plannedAction(for: $0) != .leave }
    }

    /// The archive safety floor, deliberately the same floor
    /// `AudioRetention.eligibleMeetings` requires before touching audio: the
    /// meeting is finished, transcription actually ran, and it produced at
    /// least one transcript row. Additionally excludes meetings with queue work
    /// in flight, so an archive never races a task that resolved a WAV path.
    static func archivableMeetings(database: AppDatabase, excluding: Set<String> = []) async -> [Meeting] {
        let fetched: (candidates: [Meeting], withTranscripts: Set<String>, busy: Set<String>)? =
            try? await database.writer.read { db in
                let candidates = try Meeting
                    .filter([MeetingStatus.complete.rawValue, MeetingStatus.archived.rawValue].contains(Meeting.Columns.status))
                    .filter(Meeting.Columns.transcriptionAttemptedAt != nil)
                    .filter(Meeting.Columns.audioFilePaths != "[]")
                    .fetchAll(db)
                let withTranscripts = try String.fetchSet(db, sql: "SELECT DISTINCT meetingId FROM transcript")
                let busy = try String.fetchSet(
                    db, sql: "SELECT DISTINCT meetingId FROM taskQueue WHERE status IN ('pending', 'running')")
                return (candidates, withTranscripts, busy)
            }
        guard let (candidates, withTranscripts, busy) = fetched else { return [] }
        return candidates.filter {
            withTranscripts.contains($0.id)
                && !busy.contains($0.id)
                && !excluding.contains($0.id)
                && hasArchivableAudio($0)
        }
    }

    /// Whether ONE meeting clears the floor right now — the enqueue gate for
    /// the automatic post-pipeline archive. `excludingTaskId` discounts the
    /// caller's own in-flight row: the pipeline enqueues this from inside a
    /// handler, so its own task is `running` at that moment.
    static func isArchivable(meetingId: String, database: AppDatabase, excludingTaskId: String? = nil) async -> Bool {
        let checked: Bool? = try? await database.writer.read { db in
            guard let meeting = try Meeting.fetchOne(db, key: meetingId),
                  meeting.status == .complete || meeting.status == .archived,
                  meeting.transcriptionAttemptedAt != nil,
                  hasArchivableAudio(meeting) else { return false }
            let transcripts = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM transcript WHERE meetingId = ?", arguments: [meetingId]) ?? 0
            guard transcripts > 0 else { return false }
            let busy = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM taskQueue
                    WHERE meetingId = ? AND status IN ('pending', 'running') AND id IS NOT ?
                    """,
                arguments: [meetingId, excludingTaskId]) ?? 0
            return busy == 0
        }
        return checked ?? false
    }

    /// What the compression action would do right now, for the Settings preview.
    struct Preview: Sendable {
        /// Meetings with outstanding work — what enables the action. Counts a
        /// meeting whose only remaining work is a repoint, which contributes no
        /// bytes but still needs a pass.
        var meetings = 0
        /// Bytes that would actually be rewritten: every `.wav` session (mixed
        /// plus its `_system` sibling) of those meetings.
        var bytes: Int64 = 0
    }

    /// Deliberately DB-backed rather than a raw directory scan, mirroring
    /// `AudioRetention.reclaimableBytes`: the previewed figure is exactly the set
    /// the run touches, and the action disables itself when the `.wav` files
    /// still on disk all belong to meetings that can't be archived. Off-main:
    /// stats every file.
    static func compressionPreview(database: AppDatabase) async -> Preview {
        let meetings = await archivableMeetings(database: database)
        var preview = Preview(meetings: meetings.count, bytes: 0)
        for meeting in meetings {
            for path in meeting.audioFilePaths
            where URL(fileURLWithPath: path).pathExtension.lowercased() == "wav" {
                let mixed = URL(fileURLWithPath: path)
                preview.bytes += fileSize(mixed)
                preview.bytes += fileSize(AudioBufferManager.systemAudioURL(for: mixed))
            }
        }
        return preview
    }

    // MARK: - Filesystem helpers

    private nonisolated static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private nonisolated static func availableBytes(at directory: URL) -> Int64? {
        (try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }
}

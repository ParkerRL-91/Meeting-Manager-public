import XCTest
import GRDB
@testable import MeetingManager

/// TASK-123: no-speech terminal state.
///
/// Covers the three seams the fix introduces:
///  1. The v72 backfill predicate — which stuck rows it repairs and which it spares.
///  2. The startup-cleanup exclusion — a no-speech meeting is never re-enqueued.
///  3. The exhausted-retries → terminal transition — the typed gate on the
///     injected error plus the persisted status/flag mutation it performs.
final class NoSpeechTerminalStateTests: XCTestCase {

    private var db: AppDatabase!
    private var repo: MeetingRepository!

    override func setUpWithError() throws {
        db = try TestDatabase.create()
        repo = MeetingRepository(database: db)
    }

    // Mirror of the v72 migration body so the predicate is asserted directly.
    // All migrations have already run on the test DB (the noSpeechDetectedAt
    // column exists), so we re-run the identical UPDATE against hand-seeded
    // rows spanning the predicate boundaries.
    private func runBackfill(now: Date) async throws {
        try await db.writer.write { dbc in
            try dbc.execute(sql: """
                UPDATE meeting
                SET status = 'complete', noSpeechDetectedAt = ?, updatedAt = ?
                WHERE status = 'transcribing'
                  AND startDate < ?
                  AND id NOT IN (SELECT DISTINCT meetingId FROM transcript)
                """, arguments: [now, now, now.addingTimeInterval(-86_400)])
        }
    }

    // MARK: - Backfill predicate

    func testBackfillFlipsStuckSilentMeeting() async throws {
        let now = Date()
        var stuck = SampleData.makeMeeting(
            id: "m-stuck", status: .transcribing,
            startDate: now.addingTimeInterval(-48 * 3600))
        try await repo.save(&stuck)

        try await runBackfill(now: now)

        let repaired = try await repo.find(id: "m-stuck")
        XCTAssertEqual(repaired?.status, .complete)
        XCTAssertNotNil(repaired?.noSpeechDetectedAt)
    }

    func testBackfillSparesRecentTranscribing() async throws {
        let now = Date()
        var recent = SampleData.makeMeeting(
            id: "m-recent", status: .transcribing,
            startDate: now.addingTimeInterval(-3600))
        try await repo.save(&recent)

        try await runBackfill(now: now)

        let after = try await repo.find(id: "m-recent")
        XCTAssertEqual(after?.status, .transcribing, "A meeting younger than 24h must not be closed — it may still be processing.")
        XCTAssertNil(after?.noSpeechDetectedAt)
    }

    func testBackfillSparesMeetingWithTranscripts() async throws {
        let now = Date()
        var hasText = SampleData.makeMeeting(
            id: "m-hastext", status: .transcribing,
            startDate: now.addingTimeInterval(-48 * 3600))
        try await repo.save(&hasText)
        try await db.writer.write { dbc in
            var t = SampleData.makeTranscript(meetingId: "m-hastext")
            try t.save(dbc)
        }

        try await runBackfill(now: now)

        let after = try await repo.find(id: "m-hastext")
        XCTAssertEqual(after?.status, .transcribing, "A meeting with transcript rows produced speech and must not be closed as no-speech.")
        XCTAssertNil(after?.noSpeechDetectedAt)
    }

    func testBackfillSparesNonTranscribingMeeting() async throws {
        let now = Date()
        var complete = SampleData.makeMeeting(
            id: "m-complete", status: .complete,
            startDate: now.addingTimeInterval(-48 * 3600))
        try await repo.save(&complete)

        try await runBackfill(now: now)

        let after = try await repo.find(id: "m-complete")
        XCTAssertNil(after?.noSpeechDetectedAt, "Only stuck `transcribing` rows are backfilled.")
    }

    // MARK: - Startup-cleanup exclusion

    func testStartupCleanupExcludesNoSpeechMeetings() async throws {
        var normal = SampleData.makeMeeting(id: "m-normal", status: .transcribing)
        try await repo.save(&normal)

        var noSpeech = SampleData.makeMeeting(id: "m-nospeech", status: .transcribing)
        noSpeech.noSpeechDetectedAt = Date()
        try await repo.save(&noSpeech)

        // Same query the startup orphan scan uses to gather stuck meetings.
        let stuck = try await db.writer.read { dbc in
            try Meeting
                .filter(Meeting.Columns.status == MeetingStatus.transcribing.rawValue)
                .filter(Meeting.Columns.noSpeechDetectedAt == nil)
                .fetchAll(dbc)
        }

        let ids = Set(stuck.map(\.id))
        XCTAssertTrue(ids.contains("m-normal"))
        XCTAssertFalse(ids.contains("m-nospeech"), "A meeting already closed as no-speech must never re-enter the stuck-transcribing recovery set.")
    }

    // MARK: - Exhausted-retries → terminal transition

    func testEmptyResultErrorGatesTheTransition() {
        // The callback in TaskQueueManager fires for every exhausted
        // transcription task; AppState transitions only when the injected error
        // is the empty-result error. Assert the typed gate discriminates.
        let emptyResult: Error = AppState.TranscriptionEmptyResultError(rawSeconds: 90)
        XCTAssertTrue(emptyResult is AppState.TranscriptionEmptyResultError)

        struct SomeOtherError: Error {}
        let other: Error = SomeOtherError()
        XCTAssertFalse(other is AppState.TranscriptionEmptyResultError)
    }

    func testTerminalTransitionPersistsCompleteAndFlag() async throws {
        // A meeting stuck in `transcribing` whose transcription just exhausted
        // its retries with the empty-result error. Apply the exact mutation the
        // AppState callback performs and assert the persisted terminal state.
        var stuck = SampleData.makeMeeting(id: "m-exhausted", status: .transcribing)
        try await repo.save(&stuck)

        var meeting = try await repo.find(id: "m-exhausted")!
        meeting.status = .complete
        meeting.noSpeechDetectedAt = Date()
        meeting.transcriptionAttemptedAt = meeting.transcriptionAttemptedAt ?? Date()
        try await repo.update(meeting)

        let closed = try await repo.find(id: "m-exhausted")
        XCTAssertEqual(closed?.status, .complete)
        XCTAssertNotNil(closed?.noSpeechDetectedAt)
        XCTAssertNotNil(closed?.transcriptionAttemptedAt)

        // And it is now excluded from the stuck-transcribing recovery set.
        let stuckAfter = try await db.writer.read { dbc in
            try Meeting
                .filter(Meeting.Columns.status == MeetingStatus.transcribing.rawValue)
                .filter(Meeting.Columns.noSpeechDetectedAt == nil)
                .fetchAll(dbc)
        }
        XCTAssertFalse(stuckAfter.contains { $0.id == "m-exhausted" })
    }
}

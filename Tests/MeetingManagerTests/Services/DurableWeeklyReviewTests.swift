import XCTest
import GRDB
@testable import MeetingManager

/// TASK-122: durable Weekly Review generation + user-initiated queue expedite.
/// CI-only verified: the local CLT toolchain can neither run nor COMPILE
/// XCTest targets (release builds exclude tests), so this file is exercised
/// exclusively in CI. Symbols were hand-checked against production signatures
/// at authoring time.
final class DurableWeeklyReviewTests: XCTestCase {

    // MARK: - userInitiated metadata → not background-class

    func testUserInitiatedMetadataMakesRowNonBackground() {
        let meta = "{\"userInitiated\":true}"
        // A weeklyDigest sentinel is background-class by TYPE...
        XCTAssertTrue(TaskQueueItem.isBackgroundItem(
            type: .weeklyDigest, meetingId: "__weekly_digest__:2026-W29"))
        // ...but a user-initiated row of the SAME type is not.
        XCTAssertFalse(TaskQueueItem.isBackgroundItem(
            type: .weeklyDigest, meetingId: "__weekly_digest__:2026-W29", metadata: meta),
            "User-initiated work skips quiet-gap deferral regardless of type")
    }

    func testUserInitiatedParseIsStrict() {
        XCTAssertFalse(TaskQueueItem.isUserInitiated(metadata: nil))
        XCTAssertFalse(TaskQueueItem.isUserInitiated(metadata: ""))
        XCTAssertFalse(TaskQueueItem.isUserInitiated(metadata: "not json"))
        XCTAssertFalse(TaskQueueItem.isUserInitiated(metadata: "{\"userInitiated\":false}"))
        XCTAssertFalse(TaskQueueItem.isUserInitiated(metadata: "{\"recipeId\":\"r1\"}"))
        XCTAssertTrue(TaskQueueItem.isUserInitiated(metadata: "{\"userInitiated\":true}"))
    }

    /// The :837 defer-set predicate MUST equal the :627 gate-set predicate, or
    /// the loop hot-spins re-popping an uncovered row. Both call the same
    /// metadata-aware `isBackgroundItem`, so a user-initiated row is excluded
    /// from BOTH the pop gate and the bulk defer — proven here over a batch.
    func testDeferSetEqualsGateSetWithMetadata() {
        let governed = TaskQueueItem.create(
            type: .weeklyDigest, meetingId: "__weekly_digest__:2026-W28", priority: 9)
        var userInitiated = TaskQueueItem.create(
            type: .weeklyDigest, meetingId: "__weekly_digest__:2026-W29", priority: 7,
            metadata: "{\"userInitiated\":true}")
        userInitiated.status = .pending
        let pipeline = TaskQueueItem.create(type: .summary, meetingId: "m1", priority: 5)

        let rows = [governed, userInitiated, pipeline]
        let backgroundIds = rows
            .filter { TaskQueueItem.isBackgroundItem(type: $0.type, meetingId: $0.meetingId, metadata: $0.metadata) }
            .map(\.id)

        XCTAssertEqual(backgroundIds, [governed.id],
            "Only the governed sentinel is background — user-initiated and pipeline rows are excluded")
    }

    // MARK: - settingUserInitiated merge

    func testSettingUserInitiatedFromNil() {
        XCTAssertTrue(TaskQueueItem.isUserInitiated(
            metadata: TaskQueueManager.settingUserInitiated(nil)))
    }

    func testSettingUserInitiatedPreservesExistingKeys() {
        let merged = TaskQueueManager.settingUserInitiated("{\"recipeId\":\"r1\"}")
        XCTAssertTrue(TaskQueueItem.isUserInitiated(metadata: merged))
        let data = merged.data(using: .utf8)!
        let json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["recipeId"] as? String, "r1",
            "Expedite must not clobber a row's existing metadata (e.g. recipeId)")
    }

    // MARK: - expedite field effects

    @MainActor
    func testExpediteClearsDeferralFieldsAndBumpsPriority() async throws {
        let db = try AppDatabase.empty()
        let manager = TaskQueueManager(database: db)

        var row = TaskQueueItem.create(
            type: .weeklyDigest, meetingId: "__weekly_digest__:2026-W29", priority: 9)
        row.runAfter = Date().addingTimeInterval(3600)
        row.firstDeferredAt = Date().addingTimeInterval(-7200)
        try await db.writer.write { db in try row.insert(db) }

        await manager.expedite(taskId: row.id)

        let after = try await db.writer.read { db in try TaskQueueItem.fetchOne(db, key: row.id) }
        let updated = try XCTUnwrap(after)
        XCTAssertNil(updated.runAfter, "Expedite clears the governor's defer window")
        XCTAssertNil(updated.firstDeferredAt, "Expedite clears the starvation anchor")
        XCTAssertEqual(updated.priority, TaskQueueManager.expeditedPriority)
        XCTAssertTrue(updated.isUserInitiated, "Expedite marks the row user-initiated")
    }

    @MainActor
    func testExpediteIsNoOpOnTerminalRows() async throws {
        let db = try AppDatabase.empty()
        let manager = TaskQueueManager(database: db)

        var failed = TaskQueueItem.create(
            type: .weeklyDigest, meetingId: "__weekly_digest__:2026-W29", priority: 9)
        failed.status = .failed
        failed.priority = 9
        try await db.writer.write { db in try failed.insert(db) }

        await manager.expedite(taskId: failed.id)

        let after = try await db.writer.read { db in try TaskQueueItem.fetchOne(db, key: failed.id) }
        let updated = try XCTUnwrap(after)
        XCTAssertEqual(updated.status, .failed)
        XCTAssertEqual(updated.priority, 9, "A terminal row is not expedited")
        XCTAssertFalse(updated.isUserInitiated)
    }

    // MARK: - Week-scoped dedup routing

    /// Mirrors `AppState.enqueueWeeklyReviewGeneration`: the routing predicate
    /// matches the EXACT sentinel, not any weeklyDigest. Same week + non-terminal
    /// → expedite that row; different week → no match → fall through to enqueue.
    /// This guards the "never expedite a different week's row" invariant.
    func testWeekScopedDedupNeverMatchesADifferentWeek() {
        let weekA = TaskQueueItem.create(
            type: .weeklyDigest, meetingId: "__weekly_digest__:2026-W28", priority: 9)

        func existingRow(for isoWeek: String, in tasks: [TaskQueueItem]) -> TaskQueueItem? {
            let sentinel = "\(AppState.weeklyDigestSentinel):\(isoWeek)"
            return tasks.first { $0.type == .weeklyDigest && $0.meetingId == sentinel && !$0.isTerminal }
        }

        // User clicks Generate on week B while a cadence row for week A is pending.
        XCTAssertNil(existingRow(for: "2026-W29", in: [weekA]),
            "Week B must NOT match week A's row — it would expedite the wrong week")
        // Same week matches.
        XCTAssertEqual(existingRow(for: "2026-W28", in: [weekA])?.id, weekA.id)
    }

    func testWeekScopedDedupIgnoresTerminalRows() {
        var completed = TaskQueueItem.create(
            type: .weeklyDigest, meetingId: "__weekly_digest__:2026-W28", priority: 9)
        completed.status = .completed

        let sentinel = "\(AppState.weeklyDigestSentinel):2026-W28"
        let match = [completed].first { $0.type == .weeklyDigest && $0.meetingId == sentinel && !$0.isTerminal }
        XCTAssertNil(match, "A completed row must not block re-generation (Refresh enqueues fresh)")
    }
}

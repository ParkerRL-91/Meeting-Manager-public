import XCTest
@testable import MeetingManager

/// Pins the pure logic behind "Create Task with AI" (PRJ-015 / TASK-111): the
/// deterministic recurrence detector, the compose seed (incl. the trailing-"every"
/// strip), the AI merge (fill-gaps, field-wise recurrence, past-date guard), and the
/// plain-English recurrence summary matrix. `aiCompose` is exercised through a stubbed
/// text generator so the private JSON decode is covered end-to-end. `now`/`calendar`
/// are injected so date and year logic are deterministic.
final class TaskAIComposeTests: XCTestCase {

    // A fixed clock: 2026-06-19 is a Friday; 2026-06-22 is a Monday.
    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }
    private var now: Date { day(2026, 6, 19) }
    private func parser() -> TaskQuickAddParser { TaskQuickAddParser(now: now) }

    private func gen(_ json: String) -> ((String, String) async throws -> String) {
        { _, _ in json }
    }

    // MARK: - detectRecurrence

    func testDetectRecurrenceEveryNUnits() {
        let p = parser()
        XCTAssertEqual(p.detectRecurrence(in: "water the plants every 3 days"),
                       TaskRecurrenceRule(frequency: .daily, interval: 3))
        XCTAssertEqual(p.detectRecurrence(in: "sync every 2 weeks"),
                       TaskRecurrenceRule(frequency: .weekly, interval: 2))
    }

    func testDetectRecurrenceSingleWordForms() {
        let p = parser()
        XCTAssertEqual(p.detectRecurrence(in: "standup daily")?.frequency, .daily)
        XCTAssertEqual(p.detectRecurrence(in: "review every week")?.frequency, .weekly)
        XCTAssertEqual(p.detectRecurrence(in: "rent monthly")?.frequency, .monthly)
        XCTAssertEqual(p.detectRecurrence(in: "taxes annually")?.frequency, .yearly)
    }

    func testWeekdayIsNotDeterministicRecurrence() {
        // "every Monday" is a weekday anchor, not a deterministic recurrence — the AI
        // resolves it. The deterministic detector must return nil here.
        XCTAssertNil(parser().detectRecurrence(in: "send Joel the report every Monday"))
        XCTAssertNil(parser().detectRecurrence(in: "call the bank"))
    }

    // MARK: - composeBase

    func testComposeBaseStripsTrailingOrphanEvery() {
        // parse() strips the bare weekday "Monday", leaving a dangling "every"; the
        // seed must drop it so the title reads cleanly even offline.
        let base = parser().composeBase("send Joel the report every Monday")
        XCTAssertEqual(base.title, "Send Joel the report")   // sentence-cased; "every" stripped
        XCTAssertNotNil(base.dueDate)        // next Monday
        XCTAssertNil(base.recurrence)        // weekday ≠ deterministic recurrence
        XCTAssertFalse(base.aiUsed)
    }

    func testComposeBasePlainTaskUntouched() {
        let base = parser().composeBase("follow up on the vendor contract")
        XCTAssertEqual(base.title, "Follow up on the vendor contract")  // sentence-cased; no clipped "on"
        XCTAssertNil(base.dueDate)
        XCTAssertNil(base.recurrence)
    }

    // MARK: - aiCompose merge

    func testAiComposeFillsGapsFromJSON() async {
        let p = parser()
        let base = p.composeBase("prep the slides")
        let json = #"{"title":"Prep the slides","dueDate":"2026-06-23","priority":3,"tags":["work"],"assignee":null,"recurrence":null}"#
        let r = await p.aiCompose(raw: "prep the slides", base: base, textGenerator: gen(json))
        XCTAssertTrue(r.aiUsed)
        XCTAssertEqual(r.title, "Prep the slides")            // base title == raw → AI title applies
        XCTAssertEqual(r.priority, 3)
        XCTAssertEqual(r.tags, ["work"])
        XCTAssertNotNil(r.dueDate)
        XCTAssertEqual(Calendar.current.component(.day, from: r.dueDate!), 23)
        XCTAssertEqual(Calendar.current.component(.month, from: r.dueDate!), 6)
    }

    func testAiComposeFieldWiseRecurrenceKeepsSeedAndFillsEndDate() async {
        // Seed: daily × 3 (no end). AI returns interval 5 + an end date. The seed's
        // interval is authoritative; only the missing end date is filled from the AI.
        let p = parser()
        let base = p.composeBase("water the plants every 3 days")
        let json = #"{"title":"Water the plants","recurrence":{"frequency":"daily","interval":5,"endDate":"2026-09-01"}}"#
        let r = await p.aiCompose(raw: "water the plants every 3 days", base: base, textGenerator: gen(json))
        XCTAssertEqual(r.recurrence?.frequency, .daily)
        XCTAssertEqual(r.recurrence?.interval, 3)             // seed wins
        XCTAssertNotNil(r.recurrence?.endDate)               // filled from AI
    }

    func testAiComposeTakesWholeRecurrenceWhenSeedHasNone() async {
        let p = parser()
        let base = p.composeBase("review the metrics")          // no deterministic recurrence
        let json = #"{"title":"Review the metrics","recurrence":{"frequency":"weekly","interval":1,"endDate":null}}"#
        let r = await p.aiCompose(raw: "review the metrics", base: base, textGenerator: gen(json))
        XCTAssertEqual(r.recurrence?.frequency, .weekly)
        XCTAssertEqual(r.recurrence?.interval, 1)
    }

    func testAiComposeDropsPastDueDate() async {
        let p = parser()
        let base = p.composeBase("do the thing")               // no deterministic date
        let json = #"{"title":"Do the thing","dueDate":"2026-01-01"}"#   // before the fixed now
        let r = await p.aiCompose(raw: "do the thing", base: base, textGenerator: gen(json))
        XCTAssertTrue(r.aiUsed)
        XCTAssertNil(r.dueDate)                                // past date guarded away
    }

    func testAiComposeAssigneeOnlyOnDelegation() async {
        let p = parser()
        let base = p.composeBase("ask Dana to send the report")
        let json = #"{"title":"Send the report","assignee":"Dana"}"#
        let r = await p.aiCompose(raw: "ask Dana to send the report", base: base, textGenerator: gen(json))
        XCTAssertEqual(r.assignee, "Dana")
    }

    func testAiComposeNoGeneratorReturnsBase() async {
        let p = parser()
        let base = p.composeBase("send Joel the document")
        let r = await p.aiCompose(raw: "send Joel the document", base: base, textGenerator: nil)
        XCTAssertFalse(r.aiUsed)
        XCTAssertEqual(r.title, base.title)
        XCTAssertNil(r.assignee)                               // recipient is not the owner
    }

    func testAiComposeMalformedJSONFallsBackToBase() async {
        let p = parser()
        let base = p.composeBase("send Joel the document")
        let r = await p.aiCompose(raw: "send Joel the document", base: base, textGenerator: gen("sorry, I can't help with that"))
        XCTAssertFalse(r.aiUsed)
        XCTAssertEqual(r.title, base.title)
    }

    // MARK: - recurrence summary matrix (pinned clock: now = 2026-06-19)

    func testRecurrenceSummaryStrings() {
        let cal = Calendar.current
        let jun22 = day(2026, 6, 22)        // Monday
        let sep1_2026 = day(2026, 9, 1)     // in-year → year omitted
        let sep1_2027 = day(2027, 9, 1)     // cross-year → year shown

        func summary(_ freq: TaskRecurrenceRule.Frequency, _ interval: Int, due: Date?, end: Date?) -> String {
            TaskRecurrenceRule(frequency: freq, interval: interval, endDate: end)
                .summary(dueDate: due, now: now, calendar: cal)
        }

        XCTAssertEqual(summary(.weekly, 1, due: nil, end: nil), "Repeats weekly")
        XCTAssertEqual(summary(.daily, 1, due: nil, end: nil), "Repeats daily")
        XCTAssertEqual(summary(.monthly, 1, due: nil, end: nil), "Repeats monthly")
        XCTAssertEqual(summary(.monthly, 2, due: nil, end: nil), "Repeats every 2 months")
        XCTAssertEqual(summary(.daily, 3, due: nil, end: sep1_2026), "Repeats every 3 days until Sep 1")
        XCTAssertEqual(summary(.weekly, 1, due: jun22, end: nil), "Repeats weekly, starting Mon, Jun 22")
        XCTAssertEqual(summary(.weekly, 1, due: jun22, end: sep1_2027),
                       "Repeats weekly, starting Mon, Jun 22, until Sep 1, 2027")
    }
}

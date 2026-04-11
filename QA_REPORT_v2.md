# QA Report v2 — Meeting Manager
**Version:** Post-fix (commit a92210f and subsequent PRJ-007–PRJ-014 feature commits)
**Date:** April 10, 2026
**Scope:** v1 priority fix verification + new feature audit (commits since 44e750e)
**New commits reviewed:** 9

---

## Executive Summary

The developer addressed all five v1 priorities — confirmed fixed. The race condition is gone, the folder picker is gone, audio indicators are back, and the meet-link overwrite no longer nukes valid data. Solid execution on the reported bugs.

However, the PRJ-007–PRJ-014 feature wave introduced eight new issues, three of which are high-severity from an executive-user perspective: a notification action that lies about what it does, a UI card that fights you when you try to navigate, and a badge that never actually updates itself. None of these are crashes, but all three will erode trust in the app from a time-pressed user who expects everything to work at a glance.

---

## Section 1: Scope

Commits audited since prior report baseline (44e750e):
- `a92210f` — Priority fixes (race condition, folder picker, audio, meet link, RelatedMeetings)
- `PRJ-007` through `PRJ-014` — Feature additions: QuickCapture, OpenItemsPanel, DailyBrief, MeetingPrepCard, UpNextBanner, MeetingPrepService, NotificationActions, NaturalLanguageDateParser


---

## Section 2: v1 Priority Fix Verification

### P1 — Race Condition in Search/Date Loading ✅ FIXED
**File:** `MeetingManager/Views/Search/MeetingSearchView.swift`

`@State private var searchTask: Task<Void, Never>?` added. Both `performSearch()` and `loadMeetingsForDate()` now call `searchTask?.cancel()` before creating a new task, store the handle, and guard on `!Task.isCancelled` before writing to `@State`. A 200ms debounce was also added in `performSearch()`. The fix is correct and complete. Empty state now shows date subtext ("Nothing on Apr 11, 2026") and the divider is correctly hidden during search.

### P2 — FolderPickerPopover Navigating Instead of Assigning ✅ FIXED
**File:** `MeetingManager/Views/LiveMeeting/LiveMeetingView.swift`

The entire `FolderPickerPopover` struct was deleted. The sidebar navigation side effect is gone.

### P3 — Audio Level Indicators Removed from BottomBar ✅ FIXED
**File:** `MeetingManager/Views/LiveMeeting/LiveMeetingView.swift`

`AudioLevelIndicator` views for mic and speaker restored in `BottomBar`. *Note: a new minor issue introduced here — see Section 3, item 8.*

### P4 — Meet Link Overwritten on Sync ✅ FIXED
**File:** `MeetingManager/Services/Calendar/CalendarSyncManager.swift`

Changed from unconditional assignment to: `existing.meetLink = event.meetLink ?? existing.meetLink`. Manually-added links survive calendar sync.

### P5 — RelatedMeetingsSection Collapsed by Default ✅ FIXED
**File:** `MeetingManager/Views/Components/RelatedMeetingsSection.swift`

`@State private var isExpanded = false` changed to `true`. Section renders expanded on first load.


### Additional Confirmed Fixes
- `extractCompany()` heuristic in `LiveMeetingView.swift` now uses participant names instead of producing "You last met with with recently"
- `RecordingStrip` timer invalidated properly on `onDisappear` (`timer?.invalidate(); timer = nil`)
- `contextJSON` cache in `RelevantMeetingService` populated on startup and refreshed every 5 minutes via `AppState.preComputePrepContext()`
- Notification categories extended with `prepMeeting` and `sendRecap` actions (new issues with these noted in Section 3)

---

## Section 3: UI/UX Findings — New Issues

### [🔴 HIGH] Captured Item Count Resets on Navigation
**File:** `MeetingManager/Views/LiveMeeting/LiveMeetingView.swift`
**Component:** `BottomBar`

`capturedItemCount` is declared as `@State private var capturedItemCount: Int = 0`. This is a view-local ephemeral state variable. Every time the user navigates away from `LiveMeetingView` and back — which happens naturally in a back-to-back meeting scenario — the badge resets to 0. The action items themselves are persisted to the database correctly via `ActionItemRepository`, but the badge count is meaningless because it only reflects the current view session.

**Executive impact:** The BottomBar badge is meant to confirm "I've captured something." If I tap Prep, navigate away, come back, and the badge shows 0, I assume my capture was lost. Panic, distraction, or redundant re-entry.

**Fix:** Derive the count from the repository at `onAppear`, or move `capturedItemCount` to a `@StateObject` / `AppState` that survives navigation.


### [🟠 HIGH] "Share Recap" Notification Action Doesn't Share
**File:** `MeetingManager/App/AppDelegate.swift`
**Action identifier:** `NotificationActions.sendRecap`

The notification action is labeled "Share Recap" in the UI. When tapped, the handler only sets `AppState.shared?.selectedMeetingId = meetingId` and navigates to the meeting detail view. It does not open a share sheet, trigger the Summary tab, or initiate any recap export.

The action label creates a concrete expectation: tap → sharing options appear. What actually happens: tap → app opens to the meeting. From that point, the user must manually find the Summary tab and find the share button themselves — defeating the purpose of the notification action entirely.

**Fix:** After navigation, trigger the Summary tab and post a notification or call a method to open the share sheet programmatically, or rename the action to "View Recap" if sharing from notification is not yet implemented.

### [🟠 HIGH] Prep Card Tap Expands Instead of Navigating
**File:** `MeetingManager/Views/Home/MeetingPrepCardView.swift`

When a meeting has prep context (`prepBrief?.hasContext == true`), a whole-card `onTapGesture` toggles the expanded/collapsed state of the prep section. When the card does NOT have context, the tap navigates to the meeting.

The inconsistency is fatal from a trust standpoint. An executive taps a meeting card on the home screen expecting to open that meeting — exactly what every other meeting card in the app does. Instead, the card expands to show a prep panel. There is no visual affordance distinguishing "this tap expands" from "this tap navigates." A secondary tap or a separate "Open" button is not discoverable.

**Fix:** Move expand/collapse to a dedicated chevron button or the prep context row only. Preserve the card-level tap for navigation in all cases.


### [🟠 MEDIUM] Daily Brief Sidebar Badge Never Self-Updates
**File:** `MeetingManager/Views/DailyBrief/DailyBriefView.swift` → `AppState.dailyBriefMeetingsNeedingPrep`

`appState.dailyBriefMeetingsNeedingPrep` (the integer driving the sidebar badge) is only updated inside `DailyBriefView.onAppear`. This means the badge count is stale from launch until the first time the user opens the Daily Brief view.

An executive's expectation: if there's a number on the sidebar, something needs attention *right now*. If the badge shows 0 at 8 AM because they haven't opened the view yet — when in reality 3 meetings need prep — the feature is invisible to the people it's meant to help most.

**Fix:** Move the `dailyBriefMeetingsNeedingPrep` computation into `AppState.preComputePrepContext()`, which already runs on startup and every 5 minutes. The sidebar badge will then be accurate without requiring the user to visit the view first.

### [🟡 MEDIUM] Carry-Forward Items Silently Ignored When Note Already Exists
**File:** `MeetingManager/Views/LiveMeeting/NotepadPaneView.swift`

The `onChange(of: initialText)` block that injects carry-forward action items into the notepad only fires if `noteContent.isEmpty`. If the meeting has any prior note content — even a single character — carry-forward is silently skipped. No message, no indicator, nothing.

**Executive impact:** If I started typing a pre-meeting note and then go live, I'll never see the open items the app was supposed to surface for me. The feature just disappears.

**Fix:** Either append carry-forward content below existing notes with a separator (`---\n**Open items from previous meetings:**\n`), or show a dismissible banner: "3 open items from your last meeting with this team."

### [🟡 LOW] "Next Week" Parsed as Today+7, Not Monday
**File:** `MeetingManager/Services/Parsing/NaturalLanguageDateParser.swift` (enum)

The parser returns `Date().addingTimeInterval(7 * 86400)` for "next week." If today is Thursday April 10, "next week" resolves to Thursday April 17 — not Monday April 14 as most users would expect.

This surfaces in `QuickCapturePopoverView` when setting a due date for an action item. Low severity in isolation, but incorrect date assignment on action items under time pressure is worth fixing.

**Fix:** Resolve "next week" to the Monday of the following week using `Calendar.current.nextDate(after:matching:matchingPolicy:)`.


### [🟢 LOW] Speaker Audio Indicator Lost Color Differentiation
**File:** `MeetingManager/Views/LiveMeeting/AudioLevelIndicator.swift` + `LiveMeetingView.swift`

`AudioLevelIndicator` was restored with `label:` and `level:` parameters but without the explicit `color:` parameter. The initializer defaults to `.appAccent`. Both mic and speaker indicators now render in the same accent color. Previously, speaker used `.appSuccess` (green) to differentiate output from input.

**Fix:** Pass `color: .appSuccess` to the speaker `AudioLevelIndicator` call in `BottomBar`.

### [🟡 MEDIUM] Meeting Alert Now Has 5 Notification Actions — Too Many
**File:** `MeetingManager/Services/Notifications/NotificationActions.swift`

The meeting alert category now includes: Join & Record, Record Only, Prep, Snooze, and Dismiss. Five actions on a notification banner is beyond what most users will process in a glance. macOS notification banners truncate action buttons after 2-3 items depending on display width.

**Fix:** Reduce to three: Join & Record (primary), Prep (secondary), Dismiss. Move "Record Only" and "Snooze" into the expanded notification or in-app.

---

## Section 4: Code Quality Findings

### Inline Repository Instantiation in QuickCapturePopoverView
**File:** `MeetingManager/Views/QuickCapturePopoverView.swift`

Each save call executes `ActionItemRepository().save(&item)` — a fresh repository instance created on every call. This bypasses any shared connection pooling or lifecycle management that GRDB provides through `AppDatabase`. It works, but it's inconsistent with the repository pattern used everywhere else in the codebase (where repositories are injected or referenced from a shared `appDatabase` instance).

**Recommendation:** Inject `AppDatabase.shared` into `QuickCapturePopoverView` or use `@Environment(\.appDatabase)` consistent with other views.


### loadPrepBriefs() Called on Every Meeting List Change
**File:** `MeetingManager/Views/Home/HomeView.swift`

`loadPrepBriefs()` is called in `onAppear` and in `onChange(of: upcomingMeetings)` and `onChange(of: pastMeetings)`. Calendar sync events — which happen frequently in the background — will trigger `loadPrepBriefs()` repeatedly. `MeetingPrepService` aggregates related meetings, open action items, and summaries for every prep card. Under normal conditions with 5-8 meetings on screen, this is several database reads per calendar sync cycle.

**Recommendation:** Add a debounce (500ms minimum) on the `onChange` trigger, or cache prep briefs with meeting IDs as cache keys and only recompute on actual meeting content changes (not just list pointer changes).

### MeetingPrepService Architecture is Clean ✅
**File:** `MeetingManager/Services/Prep/MeetingPrepService.swift`

Worth noting: the service itself is well-structured. Aggregation logic is isolated, it's reused correctly across `HomeView`, `DailyBriefView`, and `UpNextBannerView`, and the `MeetingPrepBrief` model is sensibly defined. Good pattern to build on.

### NotificationActions sendRecap Label/Behavior Mismatch (Code-Level)
**File:** `MeetingManager/App/AppDelegate.swift`

Beyond the UX problem, this is also a code correctness issue: the `sendRecap` action identifier is registered in the notification category with the display title "Share Recap" but the handler implements navigation only. This is a broken contract between the action's declared intent and its implementation. The test path for this action (user taps "Share Recap" in notification) is unexercised by the current implementation.

---

## Section 5: Executive Persona Walkthrough

*Persona: Director of Product, back-to-back all day, 15-second attention span per interaction, zero tolerance for "that's weird."*

**8:00 AM — App opens, check home screen.** The Daily Brief badge on the sidebar shows 0. Three meetings need prep but the badge hasn't updated yet because I haven't opened the Daily Brief view. I assume I'm good. I'm not. *(Issue: badge staleness)*

**8:45 AM — Tap a meeting prep card on home screen.** The card expands. I wanted to open the meeting. I tap again. The card collapses. I tap a third time, slower, more deliberately — it expands again. I give up and navigate manually through the sidebar. Thirty seconds lost, mild irritation registered. *(Issue: prep card tap behavior)*

**9:00 AM — First meeting goes live.** I use Cmd+Shift+A to capture an action item mid-conversation. The popover appears, I type "Follow up with legal by next week," and save. The due date is set to next Thursday instead of next Monday. I won't notice until it's wrong. *(Issue: "next week" parsing)*

**9:55 AM — Recording stops. UpNextBanner appears.** Shows the next meeting in 25 minutes with participant count and open items. This part works. I tap "Prep." The prep panel loads. Looks good.

**10:00 AM — I navigate back to home.** Return to LiveMeetingView for the next call. The BottomBar badge showing "2 captured items" from earlier now shows 0. I think my items were lost. I re-enter one of them. It's now a duplicate. *(Issue: capturedItemCount resets)*

**10:50 AM — Notification appears: "Weekly Sync recap is ready — Share Recap."** I tap "Share Recap." The app opens. I'm on the meeting detail page. No share sheet. I look around for 10 seconds. I don't find the share option quickly. I abandon it and move to my next call. The recap is never sent. *(Issue: sendRecap action navigates instead of shares)*

**Net verdict:** The v1 bugs were real friction. The v2 fixes removed that friction. But the new feature set introduced a different kind of problem: interactions that look complete but aren't. An executive will tolerate a missing feature. They will not trust an app that tells them it did something it didn't do.

---

## Section 6: Updated Top Priorities

These are the issues most likely to cost trust with the target user — ranked by executive impact, not engineering complexity.

**Priority 1 — Fix `sendRecap` to actually share** (`AppDelegate.swift`)
A notification action that lies about its behavior is the fastest way to lose user trust. Either implement the share sheet trigger or rename the action. This is a one-function fix.

**Priority 2 — Fix prep card tap to navigate** (`MeetingPrepCardView.swift`)
Card tap = navigate is a core mental model across the entire app. Breaking it conditionally based on whether a card has prep context is unintuitive and will be hit every single day by every user with prep context (i.e., all regular users). Move expand/collapse to a chevron only.

**Priority 3 — Fix Daily Brief badge to self-update** (`AppState.swift` / `DailyBriefView.swift`)
A badge that requires the user to visit a view before it becomes accurate is not a badge — it's a number. Move the computation into `preComputePrepContext()` which already runs on the right cadence.

**Priority 4 — Fix capturedItemCount to survive navigation** (`LiveMeetingView.swift`)
Items persist to DB; the badge doesn't reflect that. Derive count from DB on `onAppear`. Single database read.

**Priority 5 — Fix carry-forward injection for non-empty notes** (`NotepadPaneView.swift`)
Silent data loss is worse than no feature. If carry-forward can't run, show a banner or append below existing content with a visual separator.

---

*Report generated: April 10, 2026*
*Auditor: QA review via static code analysis and commit diff inspection*
*Screenshots: Not available (Screen Recording permission not granted to Desktop Commander sandbox)*

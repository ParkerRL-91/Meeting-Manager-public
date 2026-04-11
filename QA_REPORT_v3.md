# QA Report v3 — Meeting Manager
**Fix commit reviewed:** `aa7da65` — "Fix 7 QA issues"
**Merged via:** `8e39c09` — merge of `origin/claude/adoring-visvesvaraya` into main
**Date:** April 10, 2026
**Files changed:** 7 (AppDelegate, AppState, NotificationActions, MeetingPrepCardView, LiveMeetingView, NotepadPaneView, QuickCapturePopoverView) + 4 unintentional reversions in CalendarSyncManager, RelatedMeetingsSection, MeetingSearchView, and LiveMeetingView

---

## Executive Summary

Stop. Do not ship this build.

The fix branch (`claude/adoring-visvesvaraya`) was branched from a point in history **before** commit `a92210f` — the v1 fix commit. When it merged into main, the new fixes came in but five previously-confirmed fixes got silently overwritten by the older code in the branch. The net result: six of the seven v2 issues are fixed, but five v1 issues that were already closed are now broken again.

The race condition from the very first QA report — the worst bug we found — is back. The timer leak is back. The meet-link overwrite is back. The RelatedMeetings section is collapsed by default again. The audio indicators are gone again.

The developer needs to rebase the fix branch on top of `a92210f` or manually re-apply the v1 fixes that were lost in the merge. This is a source control problem, not a logic problem.

---

## Section 1: Commit Scope

**`aa7da65`** addresses six of the seven v2 priorities as described in its commit message. The changes span 47 lines added across 7 files. The merge (`8e39c09`) brought in 4 additional unintended diff hunks from the stale branch base that overwrote v1 fixes.


---

## Section 2: v2 Issue Verification

### v2-P1 — capturedItemCount Resets on Navigation ✅ FIXED
**File:** `LiveMeetingView.swift`

`loadCapturedItemCount()` added as a private async function (line ~195). Called from the view's task block on appear. Queries `ActionItemRepository().itemsForMeeting(meetingId)` and sets `capturedItemCount` from the real persisted count. Badge now survives navigation.

*Minor note:* `ActionItemRepository()` is instantiated inline here — same pattern concern raised in v2. Functional, but inconsistent with shared DB lifecycle. Not a blocker.

### v2-P2 — "Share Recap" Notification Action Label ✅ FIXED
**Files:** `NotificationActions.swift` (line ~88), `AppDelegate.swift` (line ~393)

Action title changed from `"Share Recap"` to `"View Recap"`. Comment in `AppDelegate` updated accordingly. The action still only navigates to the meeting detail — but now the label is honest about that. Clean approach given the share sheet isn't wired yet.

### v2-P3 — Prep Card Tap Expands Instead of Navigates ✅ FIXED
**File:** `MeetingPrepCardView.swift` (lines ~75–82, ~176–191)

`onTapGesture` now unconditionally calls `appState.selectedMeetingId = meeting.id`. The expand/collapse toggle was moved to a dedicated `Button` wrapping the chevron image, with `.buttonStyle(.plain)` to prevent event bubbling. This is the correct pattern — tap navigates, chevron expands. Fix is clean.

### v2-P4 — Daily Brief Badge Not Self-Updating ✅ FIXED
**File:** `AppState.swift` (lines ~1476–1484)

`DailyBriefService().buildBrief(for: Date())` is now called inside `preComputePrepContext()`, which runs on launch and every 5 minutes. Result updates `dailyBriefMeetingsNeedingPrep` on the main actor. Badge is now accurate without requiring the user to open the view.

*Note:* `DailyBriefService()` instantiated inline. Same pattern concern as above. Also: `buildBrief()` likely hits the DB and does non-trivial work — verify it doesn't include AI generation in this path, which would make the 5-minute timer expensive.


### v2-P5 — Carry-Forward Silently Ignored When Note Exists ✅ FIXED
**File:** `NotepadPaneView.swift` (lines ~68–103)

Two-path fix applied correctly:

Path A (note loads first, `initialText` arrives late via `onChange`): guard exits if `newValue` is empty; if `noteContent` is non-empty, appends `"\n\n---\n**Open items from previous meetings:**\n" + newValue`.

Path B (`initialText` already available when note loads in `onAppear` task): appends the separator + carry-forward content inline when setting `noteContent` from the loaded note.

The logic handles both race orderings without double-appending. Carry-forward is now visible in all cases.

### v2-P6 — "Next Week" Date Parsing ✅ FIXED
**File:** `QuickCapturePopoverView.swift` (`NaturalLanguageDateParser` enum, line ~197)

Changed from `calendar.date(byAdding: .weekOfYear, value: 1, to: startOfDay)` to:
```swift
calendar.nextDate(after: startOfDay, matching: DateComponents(weekday: 2), matchingPolicy: .nextTime)
```
`weekday: 2` = Monday in the Gregorian calendar. "Next week" now correctly resolves to the Monday of the following week regardless of what day today is.

### v2-P7 — loadPrepBriefs() Called Too Frequently ❌ NOT ADDRESSED
**File:** `HomeView.swift`

No changes in the diff. `loadPrepBriefs()` is still called on every `onChange(of: upcomingMeetings)` and `onChange(of: pastMeetings)` without debounce. Background calendar syncs will continue to trigger full prep brief computation on each cycle. Low-severity, but worth a debounce.

### v2-P8 — Speaker AudioLevelIndicator Color ❌ NOT FIXED (Indicators Removed)
**File:** `LiveMeetingView.swift` (`BottomBar`)

Rather than passing `color: .appSuccess` to the speaker indicator, both audio indicators were removed from `BottomBar` entirely (lines ~587–588 deleted). The visual feedback feature is now gone. See Section 3 for the full regression context.


---

## Section 3: Regressions — Previously Fixed Issues Now Broken

This is the critical section. The fix branch appears to have been based on the pre-`a92210f` codebase. The merge brought in the new fixes but overwrote five v1 fixes that existed only in `a92210f`.

### [🔴 CRITICAL] Race Condition in Search REINTRODUCED
**File:** `MeetingSearchView.swift`
**Was fixed in:** `a92210f` (v1 P1)

The entire task-cancellation pattern from the v1 fix has been removed:
- `@State private var searchTask: Task<Void, Never>?` deleted (line ~13)
- `searchTask?.cancel()` calls removed from both `loadMeetingsForDate()` and `performSearch()`
- `!Task.isCancelled` guards removed from both functions
- 200ms debounce in `performSearch()` removed

Both functions now create bare `Task {}` blocks with no cancellation, no debounce, and no guard against writing stale results to `@State`. Rapid date taps or typing will produce the same flickering/overwrite race the v1 fix eliminated.

This was the most severe bug in the original report. It's fully back.

### [🟠 HIGH] RecordingStrip Timer Leak REINTRODUCED
**File:** `LiveMeetingView.swift` (`RecordingStrip`, line ~357)
**Was fixed in:** `a92210f`

`.onDisappear { timer?.invalidate(); timer = nil }` was deleted from `RecordingStrip`. The timer that drives the recording duration display is never invalidated when the strip disappears. A new timer starts each time the strip appears without cleaning up the old one. Memory leak and potential display corruption on repeated recording sessions.

### [🟠 HIGH] Meet Link Unconditional Overwrite REINTRODUCED
**File:** `CalendarSyncManager.swift` (line ~203)
**Was fixed in:** `a92210f` (v1 P4)

```swift
// v1 fix (safe):
existing.meetLink = event.meetLink ?? existing.meetLink

// Current code (unsafe — v1 fix reverted):
existing.meetLink = event.meetLink  // always update for scheduled
```

If the calendar event has no meet link (`event.meetLink == nil`), the manually-added meet link on the stored meeting is cleared on the next sync. v1 P4 is broken again.


### [🟠 HIGH] RelatedMeetingsSection Reverted to Collapsed Default
**File:** `RelatedMeetingsSection.swift` (line ~9)
**Was fixed in:** `a92210f` (v1 P5)

```swift
// v1 fix:
@State private var isExpanded = true

// Current code (reverted):
@State private var isExpanded = false
```

Related meetings section is collapsed by default again. Users must discover and tap to expand before seeing context for their meeting. v1 P5 undone.

### [🟠 HIGH] Audio Level Indicators Removed — Again
**File:** `LiveMeetingView.swift` (`BottomBar`, line ~587)
**Was fixed in:** `a92210f` (v1 P3)

The audio level indicators restored in v1 have been deleted again:
```swift
// Lines removed:
AudioLevelIndicator(label: "🎤", level: appState.micLevel)
AudioLevelIndicator(label: "🔊", level: appState.systemLevel)
```

v1 P3 is broken again. Users have no live audio feedback during recording.

### [🟡 MEDIUM] extractCompany() Heuristic Reverted
**File:** `LiveMeetingView.swift` (`extractCompany()`, line ~168)
**Was fixed in:** `a92210f`

The v1 fix changed `extractCompany()` to use participant names, eliminating the "You last met with with recently" double-word bug. The new code reverts to a title-based word-splitting heuristic:
```swift
let parts = title.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 3 }
return parts.first
```
A meeting titled "Q1 Revenue Review" returns `"Revenue"`. "1on1 with Alice" returns `"1on1"`. Neither is a company name. The double-word bug from v1 may also still be possible depending on title patterns.

### [🟡 MEDIUM] FolderPickerPopover Reintroduced — Still Navigates, Doesn't Assign
**File:** `LiveMeetingView.swift` (`FolderPickerPopover` struct, line ~430)
**Was removed in:** `a92210f` (v1 P2)

A new `FolderPickerPopover` struct was added back. When the user taps a folder in the popover, it calls `appState.sidebarDestination = .folder(folder.key)` — which navigates the sidebar to the folder view. It does not assign the current meeting to that folder.

The original v1 P2 bug was exactly this: "Add to Folder" navigates the sidebar instead of adding the meeting. The new implementation has the same fundamental problem under a different code path. Additionally, the button in `BottomBar` that triggers it (`showFolderPicker.toggle()`) is a `PillBadge` labeled "Add to folder" — which promises assignment, not navigation.

### [🟢 LOW] Divider Always Visible in Search Mode
**File:** `MeetingSearchView.swift`
**Was refined in:** `a92210f`

The v1 fix placed the `Divider` inside the `if !isSearching` block so it was hidden during active search. The new code moves it outside that block — it now always renders, creating a visual gap between the (hidden) calendar and the list during search mode.

### [🟢 LOW] Empty State Text Regressed
**File:** `MeetingSearchView.swift`
**Was refined in:** `a92210f`

Two empty-state improvements from v1 removed: the date subtext `"Nothing on Apr 11, 2026"` (which gave temporal context) and the search-specific message `"No matches for \"\(searchQuery)\""` (which confirmed what was searched). Both replaced with the generic string `"No matches"`.


---

## Section 4: Executive Persona Walkthrough

*Same persona: Director of Product, back-to-back all day, expecting the fixes to have landed.*

**8:00 AM — Opens app.** Daily Brief badge is accurate. ✅ That part works now.

**8:45 AM — Taps a prep card on home screen.** Navigates to meeting immediately. ✅ Fixed.

**9:00 AM — Jumps to Search to find last week's notes.** Types two characters. The search fires immediately for each keystroke with no debounce. Three overlapping async tasks compete to write to the results list. The meeting list flickers, shows the wrong results briefly, then settles. On a fast connection the window is short enough that the user might not notice. On a slow DB query it's visible stutter. The race condition is back. ❌

**9:20 AM — Recording stops.** The RecordingStrip disappears. Internally, the timer it started is still running. If the user starts and stops recording multiple times in a session, background timers accumulate. ❌

**10:00 AM — Navigates to the detail view of a meeting she added a custom Zoom link to yesterday.** Calendar syncs in the background. The calendar event doesn't have a meet link. Her custom Zoom link is cleared. She notices when she tries to join at 10:05. ❌

**10:05 AM — Opens the meeting detail. Sees Related Meetings section collapsed.** Taps the chevron to expand. Sees three relevant prior meetings. The context is valuable — but she had to discover it with an extra tap every single time. ❌

**10:50 AM — Notification: "View Recap."** She taps it. Opens the meeting. No share sheet, but at least the button doesn't lie anymore. She manually navigates to Summary, finds the share button. Recap gets sent. Slower than it should be, but not broken. ✅

**Net verdict:** Six of seven v2 issues are genuinely fixed. The developer did good work on those. But four v1 fixes and two v1 improvements were accidentally overwritten in the merge. The app is in a worse state overall than it was after `a92210f`. This is a source control problem that needs to be resolved before any further feature work.

---

## Section 5: Root Cause Analysis

The fix branch (`claude/adoring-visvesvaraya`) was branched from the commit tree at a point **before** `a92210f`. This means the branch's base did not include any of the v1 fixes. When the branch merged into main via `8e39c09`, git used the 'ort' merge strategy. For files that both branches modified, git merged the diffs. For files the fix branch touched but that also had v1-only changes (CalendarSyncManager, RelatedMeetingsSection, MeetingSearchView, LiveMeetingView), the fix branch's older version of the surrounding code won in the merge.

**Resolution options (in order of preference):**

1. `git rebase origin/main claude/adoring-visvesvaraya` — replay the v2 fixes on top of `a92210f`. Then re-merge. This is the cleanest path.
2. Cherry-pick `a92210f` onto the current HEAD and resolve conflicts manually. Higher conflict risk but avoids rewriting branch history.
3. Manually re-apply the five reverted fixes as a new patch commit on top of `8e39c09`. Fastest path to a shippable state if the team is under time pressure.

---

## Section 6: Updated Priority List

The seven items below are the complete set of open issues after this round, ranked by severity.

**P1 — Fix the merge: restore race condition guard in MeetingSearchView**
`MeetingSearchView.swift` — Re-add `@State private var searchTask`, cancel-before-start pattern, `!Task.isCancelled` guards, 200ms debounce in `performSearch()`. This was the original P1. It's back.

**P2 — Restore timer invalidation in RecordingStrip**
`LiveMeetingView.swift` — Re-add `.onDisappear { timer?.invalidate(); timer = nil }` to `RecordingStrip`.

**P3 — Restore meet link nil-coalescing in CalendarSyncManager**
`CalendarSyncManager.swift` — Change back to `existing.meetLink = event.meetLink ?? existing.meetLink`.

**P4 — Restore RelatedMeetingsSection default-expanded**
`RelatedMeetingsSection.swift` — Change `@State private var isExpanded = false` back to `true`.

**P5 — Restore audio level indicators in BottomBar**
`LiveMeetingView.swift` — Re-add `AudioLevelIndicator` calls with correct colors (mic: `.appAccent`, speaker: `.appSuccess`).

**P6 — Fix FolderPickerPopover to assign meetings, not navigate**
`LiveMeetingView.swift` — The popover should add the current meeting to the selected folder (write to DB), not navigate the sidebar. If folder assignment isn't implemented yet, remove the popover and the "Add to folder" button until it is.

**P7 — Fix extractCompany() to use participant names**
`LiveMeetingView.swift` — Restore the participant-based implementation from `a92210f` that produced "Alice and others" instead of word-splitting meeting titles.

*Carry-forward from v2 (lower priority):*
- loadPrepBriefs() debounce in `HomeView.swift`
- 5 notification actions — reduce to 3 (Join & Record, Prep, Dismiss)
- Inline repository instantiation pattern (`ActionItemRepository()`, `DailyBriefService()`)

---

*Report generated: April 10, 2026*
*Method: git diff analysis of commit aa7da65 and merge 8e39c09 against a92210f baseline*

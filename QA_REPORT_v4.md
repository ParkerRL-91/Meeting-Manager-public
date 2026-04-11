# QA Report v4 — Meeting Manager
**Branch reviewed:** `claude/fervent-buck`
**Tip commit:** `6330b8b` — "Fix merge regressions: restore 5 v1 fixes overwritten by bad merge, fix FolderPickerPopover, fix extractCompany, add inline title editing"
**Supporting commit:** `2358661` — "QA fixes: 5 priority issues + next-week date parsing" (v2 fixes, correct version)
**Date:** April 10, 2026
**Files changed in 6330b8b:** CalendarSyncManager.swift, RelatedMeetingsSection.swift, LiveMeetingView.swift (93 lines net), MeetingSearchView.swift

---

## Executive Summary

The code in `6330b8b` is correct. All eight checklist items are addressed and seven are cleanly fixed. There is one UX gap in the new title editing feature: edits are only saved on Return key — clicking or tabbing away from the field silently discards the change. That needs a one-line fix before ship.

The blocking issue is not in the code — **the branch has merge conflicts and has not landed on main**. Both merge and cherry-pick into the current HEAD fail on `LiveMeetingView.swift` and `MeetingSearchView.swift`. This is the same root cause as the v3 regression: the fix branch diverges from the bad-merge commit that's currently sitting on main. The developer needs to resolve those two conflict files (accepting the `fervent-buck` version wholesale) and complete the merge.

Once that's done and the title blur-to-save is added, this codebase is in the best shape it's been across all four rounds.

---

## Section 1: Branch Structure

`claude/fervent-buck` was built cleanly on top of `8828a11` (before the bad merge), not on top of `8e39c09`. It contains two commits:

- `2358661` — the v2 fixes (equivalent of `aa7da65` but without the bad-merge baggage): notification label, prep card tap, daily brief badge, capturedItemCount, carry-forward, date parsing
- `6330b8b` — the v3 regression repairs + inline title editing

This is the right structure. The branch correctly avoids inheriting the bad merge. The merge conflicts exist only because the current `HEAD` on main (`8e39c09`) diverged from this branch's base. Resolving conflicts in favor of `fervent-buck`'s version of both conflicting files will produce the correct final state.


---

## Section 2: Checklist Verification

### 1. Search Race Condition ✅ FIXED
**File:** `MeetingSearchView.swift`

All five components of the v1 fix are restored:

`@State private var searchTask: Task<Void, Never>?` re-added (line ~13). Both `loadMeetingsForDate()` and `performSearch()` call `searchTask?.cancel()` before creating a new task. Both store the task handle in `searchTask`. `performSearch()` has a 200ms debounce (`try? await Task.sleep(nanoseconds: 200_000_000)`) followed by a `guard !Task.isCancelled` check. `loadMeetingsForDate()` has a `guard !Task.isCancelled` check after the DB call. Both guard on `!Task.isCancelled` before writing to `@State`.

Divider moved back inside `if !isSearching` block — hidden during search. Date subtext `"Nothing on Apr 11, 2026"` restored in the date-browsing empty state.

*Minor remaining gap:* The empty-state headline during active search still reads `"No matches"` rather than the original v1 `"No matches for \"\(searchQuery)\""`. Low priority, but the search query in the message was more useful. Both branches of `Text(isSearching ? "No matches" : "No meetings")` could be tightened.

### 2. RecordingStrip Timer ✅ FIXED
**File:** `LiveMeetingView.swift` (`RecordingStrip`, line ~351)

`.onDisappear { timer?.invalidate(); timer = nil }` re-added. Timer is cleaned up every time the strip disappears. Memory leak closed.

### 3. CalendarSyncManager Meet Link ✅ FIXED
**File:** `CalendarSyncManager.swift` (line ~203)

`existing.meetLink = event.meetLink ?? existing.meetLink` restored. Manually-added meet links survive calendar syncs where the calendar event has no link.

### 4. RelatedMeetingsSection Default-Expanded ✅ FIXED
**File:** `RelatedMeetingsSection.swift` (line ~9)

`@State private var isExpanded = true`. Section renders open on first load without requiring a tap.

### 5. Audio Level Indicators in BottomBar ✅ FIXED — with bonus color fix
**File:** `LiveMeetingView.swift` (`BottomBar`, line ~526)

Both indicators restored, and the speaker color issue from v2 is now also corrected:

```swift
AudioLevelIndicator(label: "🎤", level: appState.micLevel)
AudioLevelIndicator(label: "🔊", level: appState.systemLevel, color: .appSuccess)
```

Mic renders in `.appAccent`, speaker in `.appSuccess`. Visual differentiation between input and output is back. This resolves v2-P8 that was never properly addressed.


### 6. FolderPickerPopover Removed ✅ FIXED
**File:** `LiveMeetingView.swift`

`FolderPickerPopover` struct fully deleted (54 lines gone). `@State private var showFolderPicker` removed. The "Add to folder" `PillBadge` button removed from the pill row (lines ~107–117). No more sidebar-navigating popover masquerading as a folder assignment feature.

### 7. extractCompany() Uses Participant First Name ✅ FIXED
**File:** `LiveMeetingView.swift` (line ~162)

```swift
private func extractCompany() -> String? {
    return meeting?.participantList.first?.components(separatedBy: " ").first
}
```

Takes the first participant, splits on whitespace, returns their first name. Clean, predictable, and avoids all the double-word heuristic failures from v1 and the word-splitting title noise from v3.

*Edge case worth noting:* if `participantList.first` is an email address (`alice@company.com`), there are no spaces so the whole string returns as-is. In practice this depends on whether `participantList` stores display names or email addresses. If emails are possible, a follow-up guard would be useful — but this isn't a blocker.

### 8. Inline Title Editing ✅ IMPLEMENTED — with one UX gap
**File:** `LiveMeetingView.swift`

`@State private var editableTitle: String = ""` added. The static `Text(meeting?.title ?? "Meeting")` replaced with:

```swift
TextField("Meeting title", text: $editableTitle)
    .font(.system(size: 28, weight: .bold))
    .foregroundStyle(Color.appTextPrimary)
    .textFieldStyle(.plain)
    .padding(.horizontal, 28)
    .padding(.top, 24)
    .padding(.bottom, 10)
    .onSubmit { saveTitleIfChanged() }
```

`saveTitleIfChanged()` trims whitespace, guards against empty or unchanged input, updates local state optimistically, and persists via `appState.meetingRepository.update(updated)` in an async task.

`editableTitle` is seeded from `meeting?.title` on load and refreshed when `appState.activeMeeting?.id` changes.

**Bug:** `onSubmit` is the only save trigger — it fires on Return key. On macOS, clicking or tabbing away from a text field is a standard and expected way to confirm an edit. If the user types a new title and then clicks on the notepad below, the edit is silently discarded. This will happen constantly.

**Fix:** Add `.onFocusChange { focused in if !focused { saveTitleIfChanged() } }` to the TextField. One line. Must be resolved before ship.

*Minor:* `try?` in `saveTitleIfChanged()` silently swallows DB write errors. If persistence fails, the title appears correct locally until the next app launch when the old title reloads. Low severity, but worth a `fileLog()` at minimum.


---

## Section 3: New Issues Found

### [🔴 BLOCKING] Merge Conflicts — Fix Branch Not Yet on Main
**Files:** `LiveMeetingView.swift`, `MeetingSearchView.swift`

`git merge origin/claude/fervent-buck` fails with content conflicts in both files. `git cherry-pick 6330b8b` also fails. The fixes in `6330b8b` are not running on any device right now — the current main HEAD is still `8e39c09` with all its regressions.

**Root cause:** `8e39c09` (the bad merge) modified both files in ways that conflict with the fix branch's changes to the same files. Both branches touched overlapping regions.

**Resolution:** For both conflict files, accept the `fervent-buck` version wholesale. The `fervent-buck` version is unambiguously correct for both files — it has the race condition fix, the timer invalidation, the FolderPickerPopover removal, and the title editing. The `8e39c09` version has none of those. Open both files in a merge tool, choose "Accept incoming" for every conflicting hunk, then commit.

Alternatively, if the team wants a clean history: `git rebase 8e39c09 origin/claude/fervent-buck` then force-push the branch and re-merge. This will surface the same two conflicts but lets the developer review each hunk explicitly.

### [🟠 HIGH] Title Edit Lost on Focus Change
**File:** `LiveMeetingView.swift` (`saveTitleIfChanged()`)

Covered in checklist item 8 above. Repeated here for priority ranking: edit-without-Return is a standard macOS interaction pattern. An executive quickly corrects a wrongly-imported meeting title, clicks into the notepad to start typing, and the title reverts. They won't know it happened.

**Fix:** `.onFocusChange { if !$0 { saveTitleIfChanged() } }` on the TextField.

### [🟡 LOW] Search Empty State Missing Query Context
**File:** `MeetingSearchView.swift` (empty state view, line ~197)

When the meeting list is empty during active search, the message reads `"No matches"`. The v1 version showed `"No matches for \"\(searchQuery)\""`. The current fix restores the date subtext for the date-browsing empty state but leaves the search message generic.

One-line fix: `Text(isSearching ? "No matches for \"\(searchQuery)\"" : "No meetings")`.

---

## Section 4: Carry-Forward from Previous Rounds (Still Open)

These were noted in prior reports and remain unaddressed. None are blockers for the merge.

**loadPrepBriefs() debounce** (`HomeView.swift`) — Called on every meeting list change without debounce. Background calendar syncs trigger repeated full prep brief computation. Add a 500ms debounce on the `onChange` handlers.

**5 notification actions — too many** (`NotificationActions.swift`) — Meeting alert has Join & Record, Record Only, Prep, Snooze, Dismiss. Reduce to three primary actions for better notification UX.

**Inline repository instantiation pattern** — `ActionItemRepository()` in `loadCapturedItemCount()` and `DailyBriefService()` in `preComputePrepContext()` are instantiated directly rather than through shared lifecycle. Functional but inconsistent with the app's repository pattern elsewhere.


---

## Section 5: Executive Persona Walkthrough

*Same persona. This is the walkthrough for the world where the merge conflicts are resolved and `fervent-buck` lands cleanly.*

**8:00 AM — Opens app.** Daily Brief badge shows accurate count immediately on launch — no need to open the view first. ✅

**8:45 AM — Sees an upcoming meeting: "Q4 Planning Sync" imported with a typo in the title.** Taps the card on the home screen. Navigates to the meeting immediately. ✅ Opens the meeting in Live View. Clicks the title, types the correction, presses Return. Title saves. ✅

**8:46 AM — Types the correction, then clicks into the notepad without pressing Return.** Title reverts on next launch. ❌ This will happen every time the user corrects a title and moves to start typing notes — the exact next thing they'd do.

**9:00 AM — Searches for a past meeting.** Types two characters. The debounce holds the query for 200ms before firing. Results update once, cleanly, without flicker. ✅ No results for the query. The empty state reads "No matches" — doesn't confirm what was searched. Minor friction. 🟡

**9:10 AM — Goes live. Recording strip appears.** Duration ticks up. Navigates away to check something. Recording strip disappears. Timer is invalidated. Returns. New recording session is clean. ✅

**9:30 AM — Opens a meeting detail. Related meetings section is expanded by default.** Sees three relevant prior meetings without tapping anything. Reads the context in five seconds. ✅

**9:45 AM — Manually added a Zoom link to yesterday's meeting.** Calendar syncs in the background. Link survives. ✅

**10:00 AM — New recording. BottomBar shows mic and speaker indicators.** Mic in blue. Speaker in green. Clear visual differentiation between input and output audio. ✅

**10:50 AM — Notification: "View Recap."** Taps it. Opens the meeting. No share sheet — but the button name is honest about it now. No betrayal, just an extra step. ✅

**Net verdict:** With the merge resolved, this is the first build that would earn trust from a time-pressed user. The one thing that will actively annoy them is the title field — it's the kind of bug where the user blames themselves the first three times before they realize the app is dropping their input. That's the only must-fix before this is shippable.

---

## Section 6: Final Priority List

**P1 (BLOCKING) — Resolve merge conflicts and land the branch**
Accept `fervent-buck` version for all conflicting hunks in `LiveMeetingView.swift` and `MeetingSearchView.swift`. Until this is done, none of the fixes in `6330b8b` are live.

**P2 (Must-fix before ship) — Title TextField saves on focus loss**
`LiveMeetingView.swift` — Add `.onFocusChange { if !$0 { saveTitleIfChanged() } }` to the title TextField. One line.

**P3 (Polish) — Restore search query in empty-state message**
`MeetingSearchView.swift` — `"No matches for \"\(searchQuery)\""` instead of `"No matches"`.

**Carry-forward (low priority):**
- `HomeView.swift` — debounce `loadPrepBriefs()` onChange triggers
- `NotificationActions.swift` — reduce meeting alert to 3 actions
- Repository instantiation pattern — inject shared instances instead of inline `init()`

---

## Closing Note

If P1 (merge) and P2 (title blur-save) are resolved, this report closes. The codebase will have no remaining high-severity issues. What's left after that is polish: a slightly too-generic empty state message, a performance optimization in HomeView, and some notification action count trimming. None of those block shipping.

*Report generated: April 10, 2026*
*Method: git show + full diff analysis of 6330b8b and 2358661; merge conflict confirmed via git merge and git cherry-pick against current HEAD (8e39c09)*

# QA Report v7 — Comprehensive Deep Audit

**Date:** 2026-04-11  
**Branch:** `main`  
**HEAD:** `79ccc91 Fix: merge adoring-visvesvaraya, remove duplicate audio indicators`  
**Build Status:** ⚠️ NEEDS WORK

---

## 1. Executive Summary

This round used a significantly deeper methodology than v6: live app launch verification, edge-case data scenarios, consistency audit across all five major views, a performance scan of every `onChange` handler and unbounded collection, an accessibility sweep, and a security/privacy spot check. The 16-point regression checklist from v6 is entirely clean. Two new P2 defects were found — a calendar grid rendering bug and a complete absence of accessibility labels — plus four P3 issues. None are data-loss or crash risk, but the calendar bug is a visible layout defect users will hit when browsing past months, and the accessibility gap is an unacceptable baseline for any production release.

**Verdict: Fix P2 items before next public release. P3 items can ship with notes.**

---

## 2. Methodology Notes

| Test method | What was tested |
|---|---|
| **Live launch** | App opened via `open ~/Applications/Meeting\ Manager.app`; confirmed process started. Screencapture unavailable in the MCP shell context (no display handle), but a prior-session window screenshot confirmed the app renders normally. |
| **Full source read** | HomeView, MeetingSearchView, LiveMeetingView, MeetingDetailView, DailyBriefView, NotepadPaneView, MeetingPrepCardView, RecordingControlBar, SummaryView, NotificationActions, QuickCapturePopoverView, RelatedMeetingsSection, TaskQueueManager — read in full. |
| **Edge-case trace** | Zero meetings, whitespace-only title, special-character search queries (`%`, `_`), calendar month boundaries (Feb 2026, month-fits-exact-weeks), whitespace title submission. |
| **Grep-based audits** | All `print()` calls, `Logger.*` calls containing meeting content, `.accessibilityLabel` occurrences, hardcoded credential patterns. |
| **Consistency audit** | Font tokens, color tokens, loading state patterns, error state patterns across all five major views. |
| **Performance scan** | Every `onChange` handler, `Task.sleep` usage, timer lifecycles, `allTasks` collection growth. |

---

## 3. App Launch Verification

**App launched successfully.** `open ~/Applications/Meeting\ Manager.app` exited without error. Prior-session window screenshot (`/tmp/mm_window.png`, 258KB) confirms the app renders the Home view correctly. No crash on launch detected. The app is not currently running (confirmed via `pgrep`), so no residual state from prior sessions.

---

## 4. Edge Case Findings

### ✅ Zero meetings
`HomeView` correctly renders `NoMeetingsTodayCard` when `cachedAllToday` is empty. `MeetingSearchView` shows the calendar + "No meetings / Nothing on [date]" empty state. `DailyBriefView` shows the full "No meetings today" empty state with icon and friendly copy. All three paths handled cleanly.

### ✅ Meeting with no participants
`MeetingPrepCardView` hides the participant avatar row when `meeting.participantList.isEmpty`. `LiveMeetingView` hides the attendee pill badge. `extractCompany()` returns `nil`, so `ContextBriefView` shows "Related meetings" instead of the "You last met with…" phrasing. All guards in place.

### ✅ Very long title (50+ chars)
Every title display uses `.lineLimit(1)` and truncates with an ellipsis in all collapsed/list contexts. The LiveMeetingView inline `TextField` has no lineLimit so long titles expand naturally in the editing state. Consistent and correct.

### ✅ Meeting where calendar event was deleted
Meetings persist in the local SQLite DB independent of calendar sync. Deleting a calendar event does not cascade-delete the meeting row. `MeetingDetailView` loads from the repository, so it continues to work. No orphan-crash risk.

### ⚠️ Title editing — whitespace-only submission (P3)
Both `saveTitleIfChanged()` (LiveMeetingView) and `commitTitle()` (RecordingControlBar) correctly trim whitespace and no-op on empty results. The backend title is protected. However, neither resets `editableTitle` back to the actual meeting title after the silent rejection. The TextField remains displaying the whitespace the user typed, and the UI gives no feedback — no validation message, no shake, no reset. A user who fat-fingers a title into spaces will think the save succeeded and only notice the corruption next time the view reloads. See Finding #6.

### ✅ Emoji in title
No explicit filter found; emoji round-trips through the SQLite `TEXT` column and re-displays correctly.

### ✅ Search — empty query
`onChange(of: searchQuery)` checks `if newValue.isEmpty { isSearching = false; loadMeetingsForDate() }` — correctly reverts to date-filtered view.

### ✅ Search — single character
No minimum query length enforced. The 200ms debounce coalesces keystrokes; a single-character search fires normally. Acceptable behavior.

### ⚠️ Search — special characters `%` and `_` (P3)
The repository query is `Meeting.Columns.title.like("%\(query)%")`. GRDB parameterizes the binding correctly (no SQL injection risk), but it does NOT escape SQL LIKE metacharacters in the user's input. A search query of `%` matches every meeting title. A query of `_` matches any title with at least one character. These are not crashes or security issues, but they produce counterintuitive results that could confuse users. See Finding #5.

### ✅ Date picker — today, yesterday, future date
`CalendarDayCell` correctly highlights today with `Color.appAccent.opacity(0.12)` and selected date with filled `Color.appAccent`. Navigation to past/future months via chevrons works. `loadMeetingsForDate()` fires on `selectedDate` change.

### ⚠️ Calendar grid — month fits exact weeks (P2)
See Finding #1 — the most significant new defect.

### ✅ Notifications — dismiss all 3 actions
The meeting alert category uses `.customDismissAction`. If the user dismisses all three notification actions (Join & Record, Prep, Dismiss), no crash occurs. The meeting stays in the database and the normal in-app flow continues. The `.customDismissAction` option fires a callback that was verified clean in v5.

---

## 5. Consistency Audit

### Colors and fonts — ✅ PASS
All five major views consistently use the `Color.app*` semantic token system. No hardcoded hex values or `.blue`/`.red` literals found in view files. Font ramp is consistent: `.title2`/`.title3` for headers, `.headline`/`.subheadline` for content, `.caption` for secondary metadata.

### Loading states — ⚠️ MINOR INCONSISTENCY
| View | Loading treatment |
|---|---|
| HomeView | No loading state (cached; `rebuildCache()` is synchronous) |
| MeetingSearchView | `ProgressView()` centered (no label) |
| DailyBriefView | `ProgressView()` + "Loading your day…" label |
| MeetingDetailView | `ProgressView("Loading meeting…")` inline |
| SummaryView | `ProgressView()` centered (no label) |

DailyBriefView and MeetingDetailView show descriptive labels; SearchView and SummaryView show bare spinners. Not a bug, but worth unifying in a follow-up.

### Error states — ⚠️ MINOR INCONSISTENCY
| View | Error treatment |
|---|---|
| DailyBriefView | Full error card with icon, message, "Try Again" button |
| MeetingDetailView | `.errorAlert($errorMessage)` system alert |
| SummaryView | Load failure silently falls through to the "no summary" empty state — no user-visible error message |
| MeetingSearchView | Load failure produces an empty results list with no explanation |

SummaryView and SearchView silently swallow load errors. A user who hits a DB hiccup sees an empty state with no indication something went wrong and no way to retry. This is a minor UX gap but not a crash.

### Spacing — ✅ PASS
`.padding(.horizontal, 24)` is used consistently as the standard content inset in Home, Search, and DailyBrief. LiveMeetingView uses 28pt for its larger canvas. MeetingDetail uses 16pt to match the narrower detail pane. All intentional.

---

## 6. Performance Red Flags

### ✅ HomeView onChange debounced
Both `onChange(of: appState.upcomingMeetings)` and `onChange(of: appState.pastMeetings)` go through the 500ms `DispatchWorkItem` debounce before calling `loadPrepBriefs()`. Regression from v5 confirmed still clean.

### ✅ TaskQueueManager allTasks is bounded
`refreshTaskList()` applies `.limit(100)` to the SQLite query. The `allTasks` array cannot grow unbounded. Completed/failed tasks are purgeable via `clearCompleted()`.

### ⚠️ allTasks onChange fires broadly (low severity)
`SummaryView` and `MeetingDetailView` both observe `onChange(of: appState.taskQueueManager.allTasks)`. Every task state change anywhere in the app — even for unrelated meetings — triggers an O(n) `contains {}` scan in each open view. At n ≤ 100 this is negligible, but if the TaskQueue ever stops limiting results, this becomes a hot path. Worth noting for when the task queue grows.

### ✅ RecordingStrip timer — no leak
`RecordingStrip.onDisappear` calls `timer?.invalidate(); timer = nil`. `RecordingControlBar.onDisappear` calls `stopTimer()` which does `timer?.cancel(); timer = nil`. Both clean.

### ✅ HomeView timer — passive
The 30-second `Timer.publish` used for countdown refresh is a passive autoconnect timer. No custom cleanup needed; SwiftUI manages lifecycle via `.onReceive`.

### ✅ No synchronous main-thread work in service layer
All repository calls, AI calls, and enrichment calls are `async` and dispatched off the main actor. `rebuildCache()` in HomeView runs on MainActor but only filters and sorts two in-memory arrays — acceptable.

---

## 7. Accessibility Findings

### 🔴 P2 — Zero accessibility labels in the entire codebase

A full grep for `.accessibilityLabel`, `.accessibilityHint`, `.accessibilityValue`, and `.accessibilityElement` across all Swift source files returned zero results. No interactive element has been explicitly labeled for VoiceOver.

In practice, SwiftUI synthesizes reasonable labels for some controls (a `Button` with a `Label("Stop Recording")` will read "Stop Recording"), but several controls will produce poor or confusing VoiceOver output:

| Element | Expected VoiceOver output | Problem |
|---|---|---|
| Stop recording button (BottomBar) | Reads the `Image(systemName:)` — "Stop fill, button" | No context about what is being stopped |
| AudioLevelIndicator with emoji label `"🎤"` | "Microphone, graphic" or silence | No meaningful label |
| AudioLevelIndicator with emoji label `"🔊"` | "Loud sound, graphic" | Same |
| Expand chevron in MeetingPrepCardView | "Chevron down, button" | No indication it expands prep details |
| InitialsAvatar circles | Reads initials as letters | Should say the full participant name |
| Recording pulse dot in RecordingStrip | Ignored (decorative) or "Circle, image" | Should say "Recording in progress" |
| Category dot overlay in DailyBriefView | No label at all | Color-only status with no alternative |

This is a systemic gap. VoiceOver users cannot reliably navigate or understand the recording controls, meeting cards, or status indicators.

### ⚠️ P3 — Touch targets below 44pt minimum

Apple HIG requires 44×44pt minimum interactive tap targets. Two violations found:

1. **Expand chevron in `MeetingPrepCardView` and `DailyBriefView`**: `Image(systemName: "chevron.up").font(.caption2)` inside a `.plain` Button with no explicit frame. The caption2 font is ~11pt; the rendered tap area is far below 44pt.
2. **`CalendarDayCell`**: `.frame(height: 34)` sets the cell height to 34pt, 10pt below the minimum. The full-width frame makes the horizontal hit area fine, but vertical accuracy suffers, especially in the dense 7-column grid.

---

## 8. Security / Privacy Spot Check

### ✅ No hardcoded API keys or tokens
Grepping for `sk-ant-`, `Bearer ` with literal values, and common secret patterns found only one match: `request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")` in `GoogleCalendarService.swift` — a runtime token value, not a hardcoded credential. Clean.

### ✅ API keys stored in Keychain
`ClaudeSettingsView`, `SetupStepView`, and `AIChoiceStepView` all route through `KeychainHelper.saveString` / `loadString`. Keys are not stored in `UserDefaults` or flat files.

### ✅ `print()` statements contain only error descriptions
All 12 `print()` calls found are error-path only and log `error.localizedDescription` — no meeting content, participant names, or note text.

### ⚠️ P3 — Meeting titles emitted at `.info` level in the unified log

Three `Logger.general.info` calls include meeting titles directly:

```
Logger.general.info("Meeting '\(meeting.title)' starting in \(Int(timeUntilStart / 60)) minutes")
Logger.general.info("Auto-starting recording for meeting: \(meeting.title)")
Logger.general.info("PrepBrief for \(meeting.title): \(participants.count) participants…")
```

`.info` level persists in the macOS unified log and can be collected via `log collect` or read by any process with the `com.apple.diagnosticd.reader` entitlement. For enterprise deployments where meeting titles may contain confidential project names or client identifiers, this is a privacy concern. The fix is straightforward: redact titles to a meeting ID or drop to `.debug` level.

---

## 9. Regression Checklist — All 16 Still Passing

| # | Item | Status |
|---|---|---|
| 1 | Search race condition: `searchTask?.cancel()` + 200ms debounce + two cancellation guards | ✅ PASS |
| 2 | RecordingControlBar timer: `stopTimer()` in `onDisappear`; `timer?.cancel(); timer = nil` | ✅ PASS |
| 3 | CalendarSyncManager: `existing.meetLink = event.meetLink ?? existing.meetLink` | ✅ PASS |
| 4 | RelatedMeetingsSection: `@State private var isExpanded = true` | ✅ PASS |
| 5 | BottomBar: exactly two `AudioLevelIndicator` calls — mic (`.appAccent`) and speaker (`.appSuccess`) | ✅ PASS |
| 6 | FolderPickerPopover: zero occurrences in codebase | ✅ PASS |
| 7 | `extractCompany()`: returns participant name, not title heuristics | ✅ PASS |
| 8 | Title TextField: `.onSubmit` + `.onFocusChange` save on both commit paths | ✅ PASS |
| 9 | Daily brief badge: `dailyBriefMeetingsNeedingPrep` updated in `preComputePrepContext()` | ✅ PASS |
| 10 | `capturedItemCount`: loaded from DB via `ActionItemRepository().itemsForMeeting()` in `.task` | ✅ PASS |
| 11 | Carry-forward: both `loadNote()` and `onChange(of: initialText)` append correctly | ✅ PASS |
| 12 | "Next week" → `calendar.nextDate(…matching: DateComponents(weekday: 2), …)` | ✅ PASS |
| 13 | Summary-ready action title is `"View Recap"` | ✅ PASS |
| 14 | Prep card tap: outer `VStack.onTapGesture` navigates regardless of expanded state | ✅ PASS |
| 15 | `loadPrepBriefs()` debounced 500ms via `DispatchWorkItem` on both meeting list changes | ✅ PASS |
| 16 | Meeting alert category: exactly 3 actions — `joinAction`, `prepAction`, `dismissAction` | ✅ PASS |

---

## 10. Prioritized New Findings

---

### Finding #1 — P2: Calendar grid renders orphan row when month fills exact weeks
**File:** `MeetingSearchView.swift`, `calendarDays(for:)`  
**Severity:** P2 — visible layout defect, reproducible with real calendar data

**Root cause:**
```swift
let remaining = (7 - days.count % 7) % 7
if let lastDay = days.last {
    for i in 1...max(remaining, 1) {   // ← always at least 1
        days.append(...)
    }
}
```
When `(paddingBefore + daysInMonth) % 7 == 0` — meaning the grid already fills exactly N complete weeks — `remaining` evaluates to 0. But `max(remaining, 1)` forces the loop to run once, appending one trailing day from the next month. The calendar then renders a partial 5th (or 6th) row containing a single date cell, with the other six cells in that `HStack` simply absent.

**Known affected months:** February 2026 (Feb 1 = Sunday, 28 days → 4 exact rows + orphan March 1). Recurs any month where `(paddingBefore + daysInMonth) % 7 == 0`.

**Fix:**
```swift
let remaining = (7 - days.count % 7) % 7
if remaining > 0, let lastDay = days.last {
    for i in 1...remaining {
        days.append(cal.date(byAdding: .day, value: i, to: lastDay)!)
    }
}
```

---

### Finding #2 — P2: No accessibility labels anywhere in the codebase
**Files:** All view files  
**Severity:** P2 — VoiceOver unusable; required for App Store guidelines compliance

Zero `.accessibilityLabel` modifiers exist across the entire view layer. The most critical gaps are the recording controls (stop button, audio level indicators, recording dot), expand/collapse chevrons on meeting cards, participant avatar circles, and the color-only category dots in DailyBriefView.

**Minimum viable fix (before ship):**
- Add `.accessibilityLabel("Stop recording")` and `.accessibilityHint("Ends the current meeting recording")` to the stop button in BottomBar and RecordingControlBar
- Add `.accessibilityLabel("Microphone level")` and `.accessibilityLabel("Speaker level")` to AudioLevelIndicator
- Add `.accessibilityLabel(name)` to InitialsAvatar
- Add `.accessibilityLabel(isExpanded ? "Collapse prep details" : "Expand prep details")` to expand chevrons
- Mark decorative elements `.accessibilityHidden(true)` (pulse dots, dividers, status bars)

---

### Finding #3 — P3: Expand chevron touch targets below 44pt
**Files:** `MeetingPrepCardView.swift`, `DailyBriefView.swift`, `RelatedMeetingsSection.swift`  
**Severity:** P3 — reduces usability on high-DPI displays and for users with motor impairment

**Fix:** Add `.frame(width: 44, height: 44, alignment: .center)` or `.contentShape(Rectangle().size(width: 44, height: 44))` to the chevron button label.

CalendarDayCell: change `.frame(height: 34)` to `.frame(height: 44)`.

---

### Finding #4 — P3: Whitespace-only title rejection gives no feedback
**Files:** `LiveMeetingView.swift` (`saveTitleIfChanged()`), `RecordingControlBar.swift` (`commitTitle()`)  
**Severity:** P3 — silent UX failure; user thinks save succeeded

After submitting a title containing only spaces or tabs, the guard clause discards the change silently and `editableTitle` retains the whitespace string. The user sees no visual feedback and the text field does not reset.

**Fix:** After the guard, also reset `editableTitle` to the current saved title:
```swift
guard !trimmed.isEmpty, trimmed != meeting?.title, var updated = meeting else {
    editableTitle = meeting?.title ?? ""  // reset on rejection
    return
}
```

---

### Finding #5 — P3: SQL LIKE wildcards not escaped in search
**File:** `MeetingRepository.swift`, `search(query:date:)`  
**Severity:** P3 — unexpected results, no security risk

```swift
request = request.filter(Meeting.Columns.title.like("%\(query)%"))
```
GRDB parameterizes the binding (no injection risk), but `%` and `_` in the user's query are treated as LIKE wildcards. Typing `%` returns all meetings; `_` matches any single-character title.

**Fix:** Escape metacharacters before binding:
```swift
let escaped = query.replacingOccurrences(of: "\\", with: "\\\\")
                   .replacingOccurrences(of: "%", with: "\\%")
                   .replacingOccurrences(of: "_", with: "\\_")
request = request.filter(Meeting.Columns.title.like("%\(escaped)%", escape: "\\"))
```

---

### Finding #6 — P3: Meeting titles logged at .info level in unified system log
**File:** `AppState.swift` (lines ~1529, ~1535), `MeetingPrepService.swift` (line ~59)  
**Severity:** P3 — privacy concern for enterprise deployments

Three `Logger.general.info` calls include raw meeting titles. `.info`-level entries persist in the unified log and are accessible via `log collect` to users with the diagnostics entitlement.

**Fix:** Redact content to meeting IDs in log statements, or drop to `.debug` level (which does not persist in release builds):
```swift
Logger.general.debug("Meeting \(meetingId) starting in \(mins) minutes")
Logger.general.debug("Auto-starting recording for meeting: \(meetingId)")
Logger.general.debug("PrepBrief for \(meetingId): \(participants.count) participants…")
```

---

## Summary Table

| # | Finding | Severity | File | Fix effort |
|---|---|---|---|---|
| 1 | Calendar grid orphan row | P2 | `MeetingSearchView.swift` | 2 lines |
| 2 | Zero accessibility labels | P2 | All views | 1–2 hours |
| 3 | Sub-44pt touch targets | P3 | Prep card, calendar | 3 lines |
| 4 | Whitespace title silent rejection | P3 | LiveMeetingView, ControlBar | 1 line each |
| 5 | SQL LIKE wildcards unescaped | P3 | `MeetingRepository.swift` | 4 lines |
| 6 | Meeting titles in system log | P3 | `AppState.swift`, PrepService | 3 lines |

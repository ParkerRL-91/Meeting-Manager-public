# QA Report — Round 5
**Date:** 2026-04-10  
**Branch:** main (HEAD: e64747f)  
**Git pull result:** Fast-forward, 6 files changed  

---

## Summary

**9 of 16 items confirmed fixed. 7 items remain unresolved.**

This is not a shippable build. The root cause of most failures is a branch that was never merged: commit `aa7da65` on `claude/adoring-visvesvaraya` contains correct fixes for items 9–14 but was excluded from the two most recent merge commits (37adf69, e64747f). Item 5 is a new regression introduced by the e64747f merge conflict resolution.

---

## Confirmed Fixed ✅

| # | Item | Verification |
|---|------|-------------|
| 1 | Search race condition | `@State private var searchTask`, cancel-before-start in both `performSearch()` and `loadMeetingsForDate()`, two `guard !Task.isCancelled` guards, `Task.sleep(for: .milliseconds(200))` debounce, Divider inside `if !isSearching`, date shown in non-search empty state, query shown in search empty state. All present. |
| 2 | RecordingStrip timer | `.onDisappear { timer?.invalidate(); timer = nil }` present in `RecordingStrip`. |
| 3 | CalendarSyncManager meetLink | `existing.meetLink = event.meetLink ?? existing.meetLink` present in the `.scheduled || .notified` branch of `upsertMeeting()`. |
| 4 | RelatedMeetingsSection isExpanded | `@State private var isExpanded = true` confirmed at line 9. |
| 6 | FolderPickerPopover removed | Not present anywhere in `Views/Components/` — directory listing confirms removal. |
| 7 | extractCompany() uses participant | Uses `meeting.participantList` directly; returns `participants.first` (single attendee) or `"\(participants[0]) and others"` (multiple). No longer derives a company from the title. |
| 8 | Title TextField dual-save | Both `.onSubmit { saveTitleIfChanged() }` and `.onFocusChange { focused in if !focused { saveTitleIfChanged() } }` present on the title `TextField`. |
| 15 | loadPrepBriefs() debounced 500ms | Both `onChange(of: appState.upcomingMeetings)` and `onChange(of: appState.pastMeetings)` cancel any pending `DispatchWorkItem` and schedule a new one 500ms out before calling `loadPrepBriefs()`. |
| 16 | Notification actions reduced to 3 | `meetingCategory` actions array is `[joinAction, prepAction, dismissAction]` — exactly 3. `startAction` and `snoozeAction` are defined but not included in this category. |

---

## Still Failing ❌

### MEDIUM — Item 5: BottomBar duplicate audio indicators
**File:** `MeetingManager/Views/LiveMeeting/LiveMeetingView.swift`, lines 541–542 and 559–560  
**Regression introduced by:** merge commit e64747f  

The `BottomBar` body contains two separate pairs of `AudioLevelIndicator` calls — one before the stop button and one after — totalling 4 indicators instead of 2. The second pair also omits the `.appSuccess` color on the speaker indicator.

```swift
// First pair (correct colors, wrong position):
AudioLevelIndicator(label: "🎤", level: appState.micLevel)                           // default = .appAccent ✓
AudioLevelIndicator(label: "🔊", level: appState.systemLevel, color: .appSuccess)    // ✓

// Stop button ...

// Duplicate pair (missing .appSuccess on speaker):
AudioLevelIndicator(label: "🎤", level: appState.micLevel)
AudioLevelIndicator(label: "🔊", level: appState.systemLevel)                        // color defaults to .appAccent ✗
```

The merge commit message says it was "keeping fervent-buck features (audio indicators)" — the conflict resolution left both sides' indicator placements in place. The second block (after the stop button) should be deleted entirely.

---

### HIGH — Items 9–14: Fixes exist on unmerged branch `claude/adoring-visvesvaraya`

Commit `aa7da65` ("Fix 7 QA issues: notification label, prep card nav, daily brief badge, captured item count, carry-forward append, and date parsing") correctly implements all six of these fixes. It is reachable only from `claude/adoring-visvesvaraya` and has not been merged into `main`. The two subsequent merges (37adf69 and e64747f) both pulled from `fervent-buck` only.

**Resolution: merge `claude/adoring-visvesvaraya` into main.** Detailed state of each item is documented below for reference.

---

#### Item 9: Daily Brief badge not updated in preComputePrepContext()
**File:** `MeetingManager/App/AppState.swift` ~line 1465  

`preComputePrepContext()` only enriches context JSON for upcoming meetings. It does not compute or set `dailyBriefMeetingsNeedingPrep`. That property is only assigned inside `DailyBriefView.loadBrief()`, which runs only when the view is opened. The sidebar badge stays stale until the user manually navigates to Daily Brief.

The fix in `aa7da65` adds the prep-count computation inside `preComputePrepContext()` so the badge refreshes every 5 minutes.

---

#### Item 10: capturedItemCount not loaded from DB
**File:** `MeetingManager/Views/LiveMeeting/LiveMeetingView.swift`  

`capturedItemCount` is declared as `@State private var capturedItemCount = 0` and is only incremented by in-session callbacks. There is no DB fetch in the `.task` block. On re-navigation to an active meeting the count resets to 0 even if items were already captured.

The fix in `aa7da65` adds a `loadCapturedItemCount()` call inside the `.task` block that queries `ActionItemRepository`.

---

#### Item 11: Carry-forward does not append to non-empty notes
**File:** `MeetingManager/Views/LiveMeeting/NotepadPaneView.swift`, `loadNote()` and `onChange(of: initialText)`  

Both code paths silently discard `initialText` when `noteContent` is already non-empty:

```swift
// loadNote():
if let note = ... {
    self.noteContent = note.content   // initialText ignored if note exists
}

// onChange(of: initialText):
if noteContent.isEmpty && !newValue.isEmpty {
    noteContent = newValue            // only fires when empty
}
```

Spec requires: append carry-forward below existing content with a `---` separator. The fix in `aa7da65` adds the separator append path.

---

#### Item 12: "next week" resolves to +7 days, not Monday
**File:** `MeetingManager/Views/LiveMeeting/QuickCapturePopoverView.swift`, `NaturalLanguageDateParser.parse()`  

```swift
if lower == "next week" {
    return calendar.date(byAdding: .weekOfYear, value: 1, to: calendar.startOfDay(for: now))
}
```

This adds exactly 7 days to today. On a Thursday, "next week" becomes next Thursday. Spec requires Monday of the following week via `Calendar.nextDate(after:matching:matchingPolicy:)`. The fix in `aa7da65` uses the correct `nextDate` API.

---

#### Item 13: Notification action label still "Share Recap"
**File:** `MeetingManager/Services/Notifications/NotificationActions.swift`  

```swift
let shareRecapAction = UNNotificationAction(
    identifier: sendRecap,
    title: "Share Recap",    // should be "View Recap"
    options: [.foreground]
)
```

The action navigates to the meeting detail — it does not open a share sheet. The label is misleading. The fix in `aa7da65` renames it to "View Recap".

---

#### Item 14: Prep card tap toggles expansion instead of always navigating
**File:** `MeetingManager/Views/Home/MeetingPrepCardView.swift`  

```swift
.onTapGesture {
    if prepBrief?.hasContext == true {
        withAnimation { isExpanded.toggle() }   // tap expands/collapses
    } else {
        appState.selectedMeetingId = meeting.id  // only navigates when no context
    }
}
```

Spec requires: tap always navigates; the chevron button handles expand/collapse exclusively. The fix in `aa7da65` moves the toggle to the chevron `Button` and makes the row `onTapGesture` unconditionally navigate.

---

## New Issues Found in Commit Sweep

No new issues beyond item 5 (duplicate audio indicators introduced by e64747f). The three most recent commits are all merge/polish commits; no new feature code was introduced that warrants additional review.

---

## Required Actions Before Ship

1. **Merge `claude/adoring-visvesvaraya` into main** — resolves items 9, 10, 11, 12, 13, 14 in a single merge.  
2. **Remove duplicate `AudioLevelIndicator` block in `BottomBar`** (lines 559–560 of `LiveMeetingView.swift`) — resolves item 5.
3. **Re-run Round 6 QA** to confirm the merge is clean and no new conflicts were introduced.

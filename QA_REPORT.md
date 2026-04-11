# Meeting Manager — QA Report
**Version:** v1.9.0
**Audit Date:** April 10, 2026
**Reviewer:** QA Audit (code review + static analysis of all changed files)
**Scope:** Last 10 commits / PRJ-006 "Meeting Detail UX Overhaul" + TASK-017 polish pass

> **Note on live testing:** The app was launched (`build/app/Meeting Manager.app`) during this audit.
> Screen capture tools available in this environment are browser-scoped and could not observe the
> native macOS window. All findings below are grounded in direct code inspection of every changed
> file, with specific file and line references. A follow-up session with screen recording access
> is recommended to validate UI rendering on real data.

---

## 1. Executive Summary

Meeting Manager v1.9.0 ships a meaningful UX overhaul — the Home dashboard, live recording view,
and notification flow are genuinely well-designed and would earn a place in a busy executive's day.
The new "Join & Record" notification action is the standout improvement: one tap to open the call
and start capturing. However, the Search view (the most-changed component in this release) has a
race condition in its data-loading logic that will produce incorrect or flickering results under
normal use, and a misleadingly-labeled "Add to folder" button in the live meeting view navigates
away instead of actually adding the meeting. The audio level indicators were also silently removed
from the live recording view, eliminating the only real-time confirmation that audio is being
captured. None of these are crashes, but two are executive-grade friction points that will erode
trust in the app quickly.

---

## 2. Recent Changes Reviewed

| Commit | Area | Summary |
|--------|------|---------|
| `44e750e` | Release | v1.9.0 tag |
| `9a4b01c` | All PRJ-006 | Meeting Detail UX Overhaul |
| `7d635aa` | GoogleCalendarService | Request conferenceData, remove debug log |
| `f3b274c` | CalendarSyncManager | Backfill participants + meetLink on completed meetings |
| `2b55cf5` | Search, Notifications, LiveMeeting | TASK-017 polish |
| `ab2b623` | Search, LiveMeeting | Calendar search layout, Granola-style live view |
| `054f0fa` | MeetingStateMachine | Crash recovery: reset stuck recordings |
| `d73b320` | MeetingSearchView | Full-screen search with calendar picker |
| `100af1c` | RelevantMeetingService | Context enrichment for past meetings |
| `e998064` | Sidebar, LiveMeeting, ParticipantBar | Sidebar cleanup, participant display |

**Files deeply inspected:**
`MeetingSearchView.swift`, `LiveMeetingView.swift`, `MeetingDetailView.swift`, `SummaryView.swift`,
`SidebarView.swift`, `MeetingListRow.swift`, `HomeView.swift`, `CalendarSyncManager.swift`,
`NotificationActions.swift`, `NotificationService.swift`, `AppDelegate.swift`,
`RelatedMeetingsSection.swift`, `ParticipantBar.swift`, `Meeting.swift`, `Migrations.swift`,
`MeetingRepository.swift`


---

## 3. UI/UX Findings

### 🔴 CRITICAL — "Add to Folder" does nothing useful during a live meeting

**File:** `Views/LiveMeeting/LiveMeetingView.swift` → `FolderPickerPopover`

The live meeting view shows an "Add to folder" pill badge. Tapping it opens a popover listing the
user's folders. Tapping a folder does this:

```swift
appState.sidebarDestination = .folder(folder.key)
```

It navigates the sidebar — it does **not** add the current meeting to the folder. An executive
mid-call who taps "Add to folder" and selects "Sales Pipeline" will find themselves navigated away
from their live recording view with no confirmation and the meeting unchanged. This is a broken
affordance. Either wire this to an actual "add meeting to folder" function, or remove the button.

---

### 🔴 HIGH — Search results can silently show wrong data (race condition)

**File:** `Views/Search/MeetingSearchView.swift` → `performSearch()`, `loadMeetingsForDate()`

Both `performSearch()` and `loadMeetingsForDate()` fire unstructured `Task {}` blocks with no
cancellation handle. Rapid typing launches multiple overlapping search tasks. The last task to
*complete* (not the last task *started*) wins and sets `results`. Under latency — DB contention,
a slow disk, a cold launch — results from an earlier query can overwrite results from a later one.

**Repro:** Type "budget" quickly, then clear the field. The date-filtered list may briefly flash
the "budget" results before settling on today's meetings, or vice versa.

**Fix:** Store a `Task` handle on `@State private var searchTask: Task<Void, Never>?`, cancel it
before starting a new one, and add a debounce (~200ms) on the query onChange.


---

### 🟠 HIGH — Audio level indicators removed; no feedback that recording is working

**File:** `Views/LiveMeeting/LiveMeetingView.swift` → `BottomBar` (commit `2b55cf5`)

The mic 🎤 and speaker 🔊 `AudioLevelIndicator` widgets were removed from the bottom bar with no
replacement. The only remaining recording signal is the pulsing red dot in the top strip. That dot
animates unconditionally — it will pulse even if the microphone is muted, the audio tap failed, or
the system audio permissions were denied. An executive cannot tell whether their call is actually
being captured. This is a trust-destroying gap. Even a single static bar indicating non-zero input
would suffice. The removed code was the app's only real-time audio health signal.

---

### 🟠 HIGH — Search view: calendar permanently occupies top half regardless of window size

**File:** `Views/Search/MeetingSearchView.swift` — layout structure

The previous design toggled between calendar and results. The new design always shows the calendar
in the top half and results below. On the minimum window width (~400px), the calendar grid renders
at compressed density and the meeting list below it gets very little height. An executive who wants
to quickly find a meeting by typing a name must scroll past a full calendar grid every time. The
calendar is most useful for date-browsing; text search should collapse it automatically. The
`isSearching` flag exists but only hides the calendar section — the `Divider()` between calendar
and list renders unconditionally, leaving an orphaned separator line during search mode.

**Quick fix (divider):**
```swift
if !isSearching {
    calendarSection
    Divider().padding(.horizontal, 20)
}
meetingListSection
```

---

### 🟡 MEDIUM — Empty state lost its context string

**File:** `Views/Search/MeetingSearchView.swift` → `meetingListSection` empty branch

Old empty state: `"Nothing scheduled for this day."` / `"Try a different search term."`
New empty state: `"No meetings"` / `"No matches"`

The subtext was removed in the TASK-017 polish pass. "No meetings" with no date reference is
ambiguous — the executive doesn't know if there are genuinely no meetings on April 9th or if the
app failed to load. Put the date back: `"Nothing on \(selectedDate.formatted(date: .abbreviated, time: .omitted))"`.

---

### 🟡 MEDIUM — Related Meetings section collapsed by default; key feature is hidden

**File:** `Views/Components/RelatedMeetingsSection.swift` line 11: `@State private var isExpanded = false`

Context enrichment (TASK-014) is one of the headline features of PRJ-006. After the enrichment
task runs, the Related Meetings section appears in meeting detail — but collapsed, showing only a
tiny header row. An executive opening a past meeting before a follow-up call has to know to click
the chevron to reveal the context. Default should be `true` (expanded), or at minimum expanded for
meetings with 2+ related entries.


---

### 🟡 MEDIUM — Context Brief header produces nonsensical strings

**File:** `Views/LiveMeeting/LiveMeetingView.swift` → `extractCompany()` (~line 147)

```swift
private func extractCompany() -> String? {
    let parts = title.components(separatedBy: CharacterSet.alphanumerics.inverted)
        .filter { $0.count >= 3 }
    return parts.first
}
```

This grabs the first word ≥3 chars from the meeting title. For "1:1 with Sarah" → "with".
For "Budget Review Q2" → "Budget". The live view banner then reads:
`"You last met with with recently"` or `"You last met with Budget recently"`.

This is embarrassing in a C-suite app. Either use participant names for the header, or drop the
company heuristic and use a generic: `"Related meetings"`.

---

### 🟢 LOW — Join & Record notification action brings app to foreground during a call

**File:** `Services/Notifications/NotificationActions.swift` — `joinMeeting` action uses `.foreground` option

When an executive taps "Join & Record" from a notification, `NSWorkspace.shared.open(url)` launches
the video call, and the `.foreground` option brings Meeting Manager to front. On a single-monitor
setup this can briefly obscure the video call window. Consider removing `.foreground` from the
`joinMeeting` action (keeping it only on `startRecording`) — the app doesn't need to be frontmost
to start recording.

---

### 🟢 LOW — MeetingDetailView toolbar overflow risk

**File:** `Views/MeetingDetail/MeetingDetailView.swift` → `toolbar` block

The detail view can surface up to 8 toolbar items simultaneously (Edit, Archive, Resume Recording,
Cancel, Recipes, Share menu, Export menu, Delete). On narrower windows these overflow into a
`...` menu with no visual priority. The most executive-critical actions (Share, Export) are buried
in submenus even at full width. Consider surfacing only Share at the top level and grouping the
rest.

---

### 🟢 LOW — `onChange(of: allTasks)` triggers full DB reload for any queue activity

**File:** `Views/MeetingDetail/MeetingDetailView.swift` — `.onChange(of: appState.taskQueueManager.allTasks)`

Every time any task changes state (including background summarizations for other meetings), this
view fires `appState.meetingRepository.find(id: meetingId)`. Under heavy queue activity this is
wasteful. The guard `if contextDone { ... }` limits the reload, but the check itself runs on every
queue mutation. Filter the relevant tasks first:
`let relevant = tasks.filter { $0.meetingId == meetingId }`.


---

## 4. Code Quality Findings

### 🔴 BUG — `performSearch()` and `loadMeetingsForDate()` share mutable state with no coordination

**File:** `Views/Search/MeetingSearchView.swift`

Both functions write to `@State var results` and `@State var isLoading` from inside unstructured
Swift `Task {}` blocks. They share no `actor` isolation beyond `@MainActor.run {}` at the end.
If both are in-flight simultaneously (which happens when the user clears a search query), the
`isLoading = false` from the first-to-complete task will visually end the loading state while the
second task is still running. The user sees a blank list, then a flash of results.

---

### 🟠 BUG — Redundant `meetLink` assignment in CalendarSyncManager for scheduled meetings

**File:** `Services/Calendar/CalendarSyncManager.swift` (~lines 182–230)

For a scheduled/notified meeting, `meetLink` is set **twice**: once in the outer
`if existing.meetLink == nil` guard, and again unconditionally inside the
`if existing.status == .scheduled || .notified` block:

```swift
// Outer guard (line ~192):
if existing.meetLink == nil && event.meetLink != nil {
    existing.meetLink = event.meetLink   // ← only if nil
}

// Inner block (line ~205):
if existing.status == .scheduled || existing.status == .notified {
    existing.meetLink = event.meetLink   // ← always overwrites
}
```

For a scheduled meeting that already has a `meetLink`, the outer guard won't fire, but the inner
block will still overwrite it with whatever the calendar returns. If Google Calendar ever returns
`nil` for `event.meetLink` on a subsequent sync, a previously valid link gets cleared. This is
subtle data loss. The inner assignment should also guard: `existing.meetLink = event.meetLink ?? existing.meetLink`.

---

### 🟠 RISK — Silent error swallowing throughout async data paths

**Pattern seen in:** `MeetingDetailView`, `LiveMeetingView`, `SummaryView`, `MeetingSearchView`

The pattern `(try? await repo.someCall()) ?? []` is used ~15 times across the codebase. While
this prevents crashes, it means DB errors, permission failures, and network issues are invisible
to the user. The app shows an empty state that looks identical to "genuinely no data." At minimum,
critical paths (summary load, transcript load) should distinguish between empty and failed and
surface a retry affordance. The `errorMessage: String?` + `.errorAlert()` pattern already exists
in the codebase — use it more aggressively.

---

### 🟡 ISSUE — `RecordingStrip` timer leaks if view is dismissed unexpectedly

**File:** `Views/LiveMeeting/LiveMeetingView.swift` → `RecordingStrip`

```swift
@State private var timer: Timer?

private func startTimer() {
    timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
        Task { @MainActor in updateElapsed() }
    }
}
```

There is no `onDisappear` or `invalidate()` call. If `RecordingStrip` is removed from the view
hierarchy while recording (e.g., window minimized, navigation state change), the Timer continues
firing and posting to the main actor indefinitely. The `SidebarRecordingBar` handles this correctly
with `onDisappear(perform: stopTimer)` — `RecordingStrip` should do the same.

---

### 🟡 ISSUE — `selectedDate` date-boundary edge case in search

**File:** `Views/Search/MeetingSearchView.swift` → `loadMeetingsForDate()`
**File:** `Database/MeetingRepository.swift` → `search(date:)`

The repository builds `dayStart`/`dayEnd` using `Calendar.current.startOfDay(for: date)`. If the
user's system timezone changes between app launches (e.g., a travelling executive), previously
selected dates will shift their day boundary. This is unlikely but worth noting for a user base
that travels internationally.

---

### 🟢 NOTE — `isSameDay` helper removed; inline Calendar calls are clearer

**File:** `Views/Search/MeetingSearchView.swift` — removed `isSameDay(_:_:)` helper

This is a clean improvement. The replacement `Calendar.current.isDate(_:inSameDayAs:)` and
`Calendar.current.isDateInToday(_:)` are standard API and easier to audit. No issue.

---

### 🟢 NOTE — Migration v16 (`meetLink`) is correctly structured

**File:** `Database/Migrations.swift` — `v16-meet-link` migration

Additive column with `.text` (nullable), no default needed. Model and column enum in `Meeting.swift`
updated consistently. No concerns.


---

## 5. Executive Persona Experience

*Persona: The Executive. Back-to-back calendar. Uses an iPhone and a MacBook. Opens Meeting Manager
from the menu bar. Needs to be oriented in under 3 seconds. Every extra click is friction. Every
unclear label is a trust violation.*

---

**8:57 AM — Notification fires: "All-Hands starts in 3 minutes."**

The notification arrives with three actions: "Join & Record", "Record Only", "Snooze". This is
excellent. The primary action is exactly right — one tap gets the call open and the recording
started. No fumbling. This is the best moment in the app.

**Friction point:** If "Join & Record" is tapped, Meeting Manager comes to the foreground
(`.foreground` option). On a single monitor, the video call (Zoom/Meet) was just opened, and the
Meeting Manager window now sits on top of it. The executive has to click back to the call. Small
annoyance, but noticeable when every second counts.

---

**9:02 AM — Now in the call. Live Recording view is open.**

Big bold title. Clean. Notes area immediately available. The pulsing red "Recording" strip at the
top is reassuring at first glance. But 30 seconds in, a question: *is the mic actually on?*
The audio level indicators that used to answer this are gone. There's no way to tell. The
executive minimizes the window, comes back, the dot is still pulsing — it will always pulse.
Confidence in the recording drops.

The "Add to folder" pill is visible. The meeting is for a specific client. The executive taps it,
selects "Acme Corp" folder — and the sidebar navigates to the Acme Corp folder. The recording view
is still there, but the sidebar shifted. Nothing was added to the folder. Confusion. This
interaction is broken.

---

**9:47 AM — Meeting ended. Navigates to the meeting detail.**

Summary tab loads. Clean. "Generated 30s ago" timestamp visible. Four toolbar actions visible on
screen — Edit, Recipes, Share, Export. More hidden in overflow. The executive wants to forward the
summary to the team. "Share" is there. Good.

The "Related Meetings" section is visible above the tab picker — but it shows just a tiny header
row: "Related Meetings (3) ▼". The executive doesn't click it. The context from the last three
meetings with this client is sitting one click away, unclaimed.

---

**10:05 AM — Needs to find a meeting from last Tuesday.**

Opens Search. Full calendar renders in the top half of the window. Types "acme" in the search bar.
Calendar collapses (good). Results appear. Types quickly — "a", "ac", "acm", "acme". Results
flicker. One moment it shows 0 results, then 4, then briefly 2 again (stale task completing late).
Finds the meeting, clicks it. Success — but the flickering was noticed.

Later, clears the search. The date reverts to today. Below the calendar (which reappears) is a
list that says "No meetings" with no date reference. Today actually has no meetings on this test
account. Is that right? Did the app fail? The old copy said "Nothing scheduled for this day."
which was self-explanatory.

---

**Overall verdict:** The app *feels* like a capable copilot 70% of the time. The Home view is
genuinely excellent — countdowns, participant avatars, "Record Now" CTA is all correct. The
notification flow for joining calls is the best feature in this release. But the broken "Add to
folder" and the missing audio feedback in the live view are the two moments where trust breaks
down entirely. For an executive, a tool that appears to do something but doesn't is worse than
a tool that doesn't offer the feature at all.


---

## 6. Top Priorities

### Priority 1 — Fix "Add to Folder" in the live meeting view
**File:** `Views/LiveMeeting/LiveMeetingView.swift` → `FolderPickerPopover`

Replace the sidebar navigation call with an actual "add meeting to folder" action. If the folder
data model doesn't yet support explicit assignment (it appears folder membership is inferred via
`MeetingFolder.key`), either implement it or remove the UI entirely. A broken affordance is worse
than no affordance for an executive. This is a one-line label promise that the code does not
keep.

---

### Priority 2 — Fix the search race condition
**File:** `Views/Search/MeetingSearchView.swift`

Add task cancellation before each new search/load. Store the task handle in `@State`. Add a
debounce (~200ms) on the search query `onChange`. This is a 15-line fix that eliminates flickering
results and wrong-data scenarios. Without it, the search feature cannot be trusted.

---

### Priority 3 — Restore audio feedback in the live recording view
**File:** `Views/LiveMeeting/LiveMeetingView.swift` → `BottomBar`

Restore at minimum one `AudioLevelIndicator` for the microphone input. The executive must be
able to confirm that audio is flowing. The pulsing dot is not sufficient — it doesn't reflect
actual audio state. This was a regressive removal with a meaningful UX cost.

---

### Priority 4 — Default Related Meetings to expanded
**File:** `Views/Components/RelatedMeetingsSection.swift` line 11

Change `@State private var isExpanded = false` to `true`. Context enrichment is a headline feature.
Hiding it behind a collapsed chevron ensures most users will never discover it. This is a
one-character fix.

---

### Priority 5 — Add date context to the search empty state
**File:** `Views/Search/MeetingSearchView.swift` → empty branch of `meetingListSection`

When `!isSearching` and `results.isEmpty`, show:
`"Nothing on \(selectedDate.formatted(date: .abbreviated, time: .omitted))"` as the subtext.
"No meetings" alone is ambiguous between "empty day" and "app error." An executive needs to be
certain which it is.

---

## Appendix: Delight Moments

These are working well and should be protected in future iterations:

- **Home view "Coming Up" cards** — countdown timers, participant avatars, color-coded urgency,
  and inline "Record Now" CTA are exactly what a busy executive needs. Don't touch this.
- **"Join & Record" notification action** — the best new feature in v1.9.0. Single-tap to call
  + capture is the platonic ideal of this app's value proposition.
- **Context Brief in live meeting** — showing past meeting excerpts from the same participants
  *during* the call is genuinely useful. The feature works; it just needs to be more discoverable
  in the detail view (see Priority 4).
- **Persistent task queue for regeneration** — regeneration surviving navigation without local
  state is a solid architectural decision. The `SummaryView` implementation is clean.

---

*Report generated: April 10, 2026*
*Saved to: `$HOME/Documents/Meeting Manager/QA_REPORT.md`*

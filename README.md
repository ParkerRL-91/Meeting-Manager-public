# Meeting Manager

A native macOS app that records, transcribes, and summarizes your meetings — entirely on your Mac or via Claude AI.

## Download

[**Meeting-Manager-1.9.0.dmg**](https://github.com/ParkerRL-91/Meeting-Manager/releases/tag/v1.9.0) — macOS 14.4+

Open the DMG, drag Meeting Manager to Applications, and launch.

### First Launch — Gatekeeper Notice

Because Meeting Manager is not yet signed with an Apple Developer ID, macOS may block the app on first launch with a message like *"Apple could not verify Meeting Manager."*

**To open the app:**

1. **Right-click** (or Control-click) on Meeting Manager in Applications
2. Click **Open** from the context menu
3. If you still see a warning with only "Done" and "Move to Trash":
   - Click **Done**
   - Go to **System Settings → Privacy & Security**
   - Scroll down — you'll see *"Meeting Manager was blocked"*
   - Click **Open Anyway**
4. You only need to do this once — future launches will work normally

**Alternative (Terminal):**
```bash
xattr -cr "/Applications/Meeting Manager.app"
```
This removes the quarantine flag so the app opens without warnings.

---

## What's New in v1.9.0 — Meeting Detail UX Overhaul

### Search & Calendar
- **Full-width custom calendar** — modern dark-themed calendar grid with month navigation and "Today" button
- **Calendar + meeting list split** — calendar top half, meetings for selected date below
- **Live search** — typing in the search bar replaces the calendar with search results; clear to return to calendar
- **Search nav item** — dedicated magnifying glass icon in the sidebar

### Live Meeting View (Granola-inspired)
- **Large meeting title** at top with pill badges: "Today", attendee count, "Add to folder"
- **Attendee popover** — click the attendees badge to see the full list with initials avatars
- **Folder picker** — assign the meeting to a folder during recording
- **Context brief** — collapsible section at the bottom showing relevant past meetings with excerpts
- **Bottom bar** — stop button + "Ask anything" AI chat prompt (Cmd+J)
- **Transcript pane removed** — notes-only view during recording (transcription runs in background)

### Participants & Context
- **Participant bar** at top of every meeting detail (initials avatars + names, clickable to People view)
- **Related meetings section** — collapsible section showing past meetings with participant overlap
- **Calendar-first participant detection** — attendees from Google Calendar written to meetings at sync time
- **Screen fallback** — CGWindowList-based detection for meetings without calendar data

### Notifications
- **"Join & Record" button** — notification 1 minute before meeting includes a button that opens the video call URL AND starts recording simultaneously
- **Meet link storage** — video URLs from Google Calendar (Meet, Zoom, Teams) saved on meetings

### Sidebar
- Cleaned up — meeting list, search bar, and archive toggle removed
- Navigation: Home, Ask Anything, People, Search, Tasks, My Notes folders

### Crash Recovery
- Meetings no longer get permanently stuck as "Cancelled" after a crash
- Crashed recordings reset to "Scheduled" so you can re-record
- "Resume Recording" button on recoverable meetings

### Task Queue & Infrastructure
- Regeneration routed through persistent task queue (survives navigation)
- All long-running AI operations audited — exempt or queued
- `push-update.sh` hardened with fail-fast checks, atomic version bump, delta updates
- `git-update` Claude Code skill for guided releases

---

<details>
<summary><strong>Previous Releases</strong></summary>

#### v1.8.2 — Update Pipeline Test
- First release via hardened push-update.sh
- Sparkle appcast on GitHub Pages

#### v1.7.0 — Dynamic Model Selection & Recording Fixes
- Adaptive on-device summarization — auto-picks Ollama model by transcript size
- Batch transcription decoupled from stop-recording flow
- Calendar selection picker in Settings
- Silence auto-stop raised to 5 min

#### v1.6.0 — Stability & Efficiency
- Thread-safe audio pipeline, actor-isolated WhisperEngine
- Circular audio buffers, memory pressure monitoring
- Exponential backoff retry for Claude/Google APIs
- 22 test files, DatabasePool, log rotation

#### v1.5.0 — Stability Sprint
- Timer leaks & 36k Task spawns eliminated
- Crash recovery for orphaned recordings
- Batch database writes, FTS5 search

#### v1.4.0 — Swift 6 & Reliability
- All Swift 6 strict concurrency errors resolved
- WhisperKit cache-first loading

#### v1.1 — Dual Audio Capture
- Mic + system audio via ScreenCaptureKit
- Live audio level meters, smart notifications

</details>

---

## Features

### Recording & Transcription
- Detects active calls (Zoom, Meet, Teams) and prompts to record
- On-device transcription via [WhisperKit](https://github.com/argmaxinc/WhisperKit) Large v3 — no audio leaves your Mac
- Batch transcription after recording for maximum accuracy
- Supports both microphone and system audio capture

### AI Summarization
- Summaries, action items, and key decisions extracted from transcripts
- **Claude AI** (cloud) — highest quality, uses your Anthropic API key
- **On-Device AI** (Ollama) — fully local, no data leaves your Mac
- Auto-summary option: generate summaries automatically after transcription

### Recipes & Action Items
- Custom prompt templates (Recipes) for structured output
- AI-powered action item extraction with assignees and due dates
- Live meeting chat — ask questions about the ongoing meeting

### Calendar Integration
- Connects to Google Calendar to pull upcoming meetings
- Auto-names recordings from calendar events
- Attendees from calendar invites shown as participants
- Video call URLs (Meet, Zoom, Teams) stored for one-click join

### Search & Navigation
- **Calendar view** — browse meetings by date with a modern calendar grid
- **Text search** — find meetings by name across all history
- **People view** — see all meetings with a specific person
- **Folder grouping** — recurring meetings auto-grouped by series

---

## On-Device AI Setup

Enable **Settings → On-Device → Use On-Device Summarization**. The app will automatically:

1. Download and install [Ollama](https://ollama.com) (~60 MB)
2. Pull the default model `llama3.2:3b` (~2 GB)
3. Show progress inline — no terminal required

For best results with long meetings (>30 min), also install the 8B model:
```bash
ollama pull llama3.1:8b
```

The **Auto (Dynamic)** model setting (default) picks the right model for each meeting. For slower Macs (≤16GB RAM), select `llama3.2:3b` explicitly to force the lighter model.

---

## Requirements

- macOS 14.4 (Sonoma) or later
- Apple Silicon or Intel Mac
- ~3 GB RAM for WhisperKit Large v3 transcription model
- **For Claude summarization:** Anthropic API key (set in Settings → Claude)
- **For Google Calendar:** Google account with Calendar access

---

## Building from Source

```bash
git clone https://github.com/ParkerRL-91/Meeting-Manager.git
cd Meeting-Manager
swift build
```

**Release build:**
```bash
swift build -c release
```

### Dependencies (via Swift Package Manager)
- [GRDB](https://github.com/groue/GRDB.swift) — SQLite persistence
- [WhisperKit](https://github.com/argmaxinc/WhisperKit) — on-device speech-to-text (Large v3)
- [Sparkle](https://github.com/sparkle-project/Sparkle) — auto-updates

---

## Architecture

```
MeetingManager/
├── App/           — AppState (single observable source of truth), AppDelegate
├── Models/        — Meeting, Transcript, MeetingSummary, TaskQueueItem, AppSettings
├── Database/      — GRDB setup, migrations (v1-v16), repositories
├── Services/
│   ├── AI/        — ClaudeService, OllamaService, SummaryGenerator, RecipeEngine
│   ├── Audio/     — AudioCaptureService, AudioBufferManager
│   ├── Calendar/  — GoogleCalendarService, GoogleAuthManager, CalendarSyncManager
│   ├── Context/   — RelevantMeetingService (past meeting intelligence)
│   ├── TaskQueue/ — TaskQueueManager (persistent background processing)
│   ├── Transcription/ — WhisperKit batch transcriber
│   └── Notifications/ — NotificationService, NotificationActions
└── Views/
    ├── Sidebar/   — SidebarView (nav items, spaces, banners)
    ├── Search/    — MeetingSearchView (calendar + search)
    ├── MeetingDetail/ — SummaryView, TranscriptView, ParticipantBar
    ├── LiveMeeting/ — Granola-style recording view, NotepadPane, MeetingChat
    ├── Components/ — InitialsAvatar, ParticipantBar, RelatedMeetingsSection
    └── Settings/  — Per-tab settings views (8 tabs)
```

Data flow: `AudioCaptureService` → `BatchTranscriber` → `TranscriptRepository` → `TaskQueueManager` → `SummaryGenerator` → `SummaryRepository`

---

## Auto-Updates

Meeting Manager uses [Sparkle](https://sparkle-project.org) for automatic updates. The appcast is hosted at:

```
https://parkerrl-91.github.io/Meeting-Manager/appcast.xml
```

Updates are signed with an EdDSA key. Enable automatic checks in **Settings → Updates**.

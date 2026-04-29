# Meeting Manager

A native macOS app that records, transcribes, and summarizes your meetings — entirely on your Mac or via Claude AI.

## Download

[**MeetingManager-v3.2.0.dmg**](https://github.com/ParkerRL-91/Meeting-Manager/releases/tag/v3.2.0) — macOS 14.4+

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

## What's New in v3.2.0 — Skim-First UI Redesign

A complete visual overhaul tuned for people moving through 6–10 meetings a day. The new design lets you grok a meeting recap in seconds, find action items instantly, and triage across recent meetings without context-switching.

### Design System
- **New color palette** — darker, more focused backgrounds; indigo accent (from iOS blue)
- **Hairline borders and tinted surfaces** — Linear/Granola-style density instead of heavy cards
- **Consistent type scale** — Inter-inspired sizing with proper weight hierarchy throughout

### Sidebar
- **Active nav row** now uses a tinted background with accent text — was a saturated solid blue fill that read too heavy
- **New Meeting button** is now a restrained dashed outline style — no longer dominates the sidebar chrome
- Hover states step up one neutral surface level

### Meeting Header
- **Compact single row** — title · date · duration · status pill all on one line
- Removed the large card layout; a bottom border replaces the elevated card frame
- Status pill uses semantic colors (green for complete, indigo for in-progress)

### Tab Strip
- **Underlined tabs** replace the segmented control — cleaner, full-width
- Model and generation timestamp caption right-aligned in the strip

### Summary View — Skim-First
- **TL;DR card** at the top — gradient background with a sparkle icon; shows the first 1–2 lines of the AI summary at a glance
- **Two-column section grid** — Decisions, Follow-ups, Notes, Outcomes as flat lists with bold entity names, no walls of markdown text
- **Previous sessions strip** — quick links to prior meetings in the same series
- Falls back gracefully to the raw text editor for unstructured summaries

### Activity View
- **Collapsible failed rows** — errors are hidden by default, revealed on click; subtle red-tint border without shouting
- Completed rows are a clean flat list with relative timestamps
- Failed count shown in red in the header

### Daily Brief
- **Timeline layout** — vertical time rail, 56px monospaced time column, category color dots that punch through the rail
- Meeting cards have a 2px left color border matching their prep category (carry-over red, follow-up amber, new indigo)

---

## What's New in v3.1.0 — Speaker Recognition

- Speaker diarization (Layers 1 + 2 + 3): voice clustering, cross-session learning, custom rename sheet
- Deterministic series key hashing (SHA-256)

---

<details>
<summary><strong>Previous Releases</strong></summary>

#### v3.0.1 — Stability
- Crash fixes and database migration hardening

#### v3.0.0 — Major Release
- Full Granola-parity feature set

#### v1.9.0 — Meeting Detail UX Overhaul
- Calendar view with date picker, live meeting search
- Granola-style live recording view (notes-first, transcript background)
- Participant bar, related meetings section, calendar-first detection
- "Join & Record" notification button, Meet/Zoom/Teams URL storage
- Persistent task queue for regeneration; all AI ops audited

#### v1.8.2 — Update Pipeline
- First release via hardened `push-update.sh`; Sparkle appcast on GitHub Pages

#### v1.7.0 — Dynamic Model Selection
- Adaptive on-device summarization — auto-picks Ollama model by transcript size
- Batch transcription decoupled from stop-recording flow

#### v1.6.0 — Stability & Efficiency
- Thread-safe audio pipeline, actor-isolated WhisperEngine
- Exponential backoff, 22 test files, DatabasePool, log rotation

#### v1.5.0 — Stability Sprint
- Timer leaks eliminated, crash recovery, FTS5 search

#### v1.4.0 — Swift 6 & Reliability
- All Swift 6 strict concurrency errors resolved; WhisperKit cache-first loading

#### v1.1 — Dual Audio Capture
- Mic + system audio via ScreenCaptureKit; live audio level meters

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

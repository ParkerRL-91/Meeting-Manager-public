# Meeting Manager

A native macOS app that records, transcribes, and summarizes your meetings — entirely on your Mac or via Claude AI.

## Download

[**MeetingManager-v1.3.0.dmg**](./MeetingManager-v1.3.0.dmg) — macOS 14.4+

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

## What's New in v1.3.0 — Stability & Efficiency

A comprehensive stability and performance sprint touching 30+ areas across the entire codebase.

### Crash Prevention & Data Integrity
- **Thread-safe audio pipeline** — `SystemAudioTap`, `MicrophoneCapture`, and `AudioCaptureService` now use proper locking to eliminate data races during recording start/stop
- **Actor-isolated WhisperEngine** — replaced `@unchecked Sendable` + NSLock with Swift actor isolation
- **Atomic calendar upserts** — `CalendarSyncManager` wraps fetch-then-insert/update in a single GRDB transaction
- **Microphone permission flow** — checks authorization before starting capture; surfaces clear errors for denied/restricted states
- **Mic disconnect handling** — listens for audio engine config changes and gracefully stops capture when a device is unplugged
- **Write error propagation** — `AudioBufferManager` reports file write errors via callback and auto-stops after 5 consecutive failures

### Memory & Performance
- **Circular audio buffers** — fixed-capacity ring buffer (480K samples / 30s at 16kHz) replaces growable arrays
- **Memory pressure monitoring** — flushes audio buffers on warning, triggers auto-stop on critical memory pressure
- **Segment capping** — in-memory transcript segments capped at 500; older segments persist in SQLite
- **Batched MainActor updates** — coalesces segment updates into single render passes
- **Pooled ISO8601DateFormatter** — shared static instances replace 6 inline instantiations
- **Database indexes** — 6 new performance indexes for foreign keys and common query patterns
- **Pagination on all repositories** — every query has `LIMIT` clauses (50–200) with offset support
- **Debounced meeting loads** — rapid-fire `loadMeetings()` calls coalesce with 150ms debounce

### API Resilience
- **Exponential backoff retry** — Claude, Google Calendar, and Google Auth retry on network errors / 429 / 5xx with jitter
- **Client-side rate limiting** — 1-second minimum interval between Claude API requests
- **Response size limits** — rejects responses over 1MB before JSON decode
- **HTTP timeouts** — all outbound requests use 120-second timeout
- **Apple Speech fallback** — automatic fallback to `SFSpeechRecognizer` when WhisperKit fails to load

### UI Polish
- **Memoized sidebar filters** — filtered lists computed via `@State` + `onChange`, not on every render
- **Scroll performance** — transcript auto-scroll triggers on last segment ID change, not count
- **Task cancellation** — all views cancel in-flight async tasks on disappear
- **Timer/observer cleanup** — services invalidate timers and remove observers in `deinit`
- **Log rotation** — `app.log` rotates at 5MB

### Infrastructure
- **Comprehensive test suite** — 22 test files covering models, repositories, and services
- **Error alert system** — reusable `ErrorAlertModifier` with error hoisting from list rows

---

<details>
<summary><strong>Previous Releases</strong></summary>

#### v1.1.1
- Model download progress bar in menu bar popover
- Download error recovery with retry button
- Transcription readiness indicator
- Onboarding model status display
- Global error alerts for recording, transcription, and detection

#### v1.1
- Dual audio capture (mic + system audio via ScreenCaptureKit)
- Live audio level meters
- Smart macOS notifications for meeting events
- Large v3 transcription model
- Unified AI routing (Ollama + Claude)
- Calendar sync fix, auto-generate summaries
- Explicit mic device selection

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
- Upcoming meetings in the **Scheduled** sidebar; past meetings in **History**

### Sidebar
- **Scheduled** — upcoming meetings, collapsible
- **History** — past meetings with **Recorded** or **Completed** badges, collapsible
- Search across all meetings

---

## On-Device AI Setup

Enable **Settings → On-Device → Use On-Device Summarization**. The app will automatically:

1. Download and install [Ollama](https://ollama.com) (~60 MB)
2. Pull the default model `llama3.2:3b` (~2 GB)
3. Show progress inline — no terminal required

Once setup is complete, all summaries, recipes, action items, and chat are generated locally. You can switch back to Claude at any time by disabling the toggle.

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
├── Models/        — Meeting, Transcript, MeetingSummary, AppSettings
├── Database/      — GRDB setup, migrations, repositories
├── Services/
│   ├── AI/        — ClaudeService, OllamaService, SummaryGenerator, RecipeEngine, ActionItemExtractor
│   ├── Audio/     — AudioCaptureService, AudioBufferManager
│   ├── Calendar/  — GoogleCalendarService, GoogleAuthManager, CalendarSyncManager
│   ├── Transcription/ — WhisperKit batch transcriber
│   └── Updates/   — Sparkle UpdateService
└── Views/
    ├── Sidebar/   — SidebarView, MeetingListRow
    ├── MeetingDetail/ — SummaryView, TranscriptView, MeetingMetadataHeader
    ├── LiveMeeting/ — MeetingChatView, NotepadPaneView
    └── Settings/  — Per-tab settings views (8 tabs)
```

Data flow: `AudioCaptureService` → `BatchTranscriber` → `TranscriptRepository` → `SummaryGenerator` → `SummaryRepository`

---

## Auto-Updates

Meeting Manager uses [Sparkle](https://sparkle-project.org) for automatic updates. The appcast is hosted at:

```
https://parkerrl-91.github.io/Meeting-Manager/appcast.xml
```

Updates are signed with an EdDSA key. Enable automatic checks in **Settings → Updates**.

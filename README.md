# Meeting Manager

A native macOS app that records, transcribes, and summarizes your meetings — entirely on your Mac or via Claude AI.

## Download

[**MeetingManager-v1.1.dmg**](./MeetingManager-v1.1.dmg) — macOS 14.4+

Open the DMG, drag Meeting Manager to Applications, and launch.

---

## What's New in v1.1

- **Dual audio capture** — records both your microphone and system audio (remote participants) simultaneously using ScreenCaptureKit
- **Live audio level meters** — real-time mic and system audio indicators in the menu bar popover and recording control bar
- **Smart notifications** — macOS notifications when recording auto-starts, when a meeting is detected (with a "Start Recording" action), and when a meeting ends
- **Large v3 transcription model** — dramatically improved transcription accuracy using WhisperKit's largest model
- **Unified AI routing** — Recipes, Action Items, and Live Chat now support both Ollama (on-device) and Claude
- **Calendar sync fix** — recording a calendar event no longer shows wrong start time or inflated duration
- **Auto-generate summaries** — optionally generate a summary after recording ends, using your default prompt
- **Explicit mic device selection** — prevents aggregate device hijack from system audio tap; works with any USB/built-in microphone

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

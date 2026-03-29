# Meeting Manager

A native macOS app that records, transcribes, and summarizes your meetings — entirely on your Mac or via Claude AI.

## Download

[**Meeting-Manager-1.0.6.dmg**](./Meeting-Manager-1.0.6.dmg) — macOS 14.4+

Open the DMG, drag Meeting Manager to Applications, and launch.

---

## Features

### Recording & Transcription
- Detects active calls (Zoom, Meet, Teams) and prompts to record
- On-device transcription via [WhisperKit](https://github.com/argmaxinc/WhisperKit) — no audio leaves your Mac
- Real-time transcript display with speaker labels
- Supports both microphone and system audio capture

### AI Summarization
- Summaries, action items, and key decisions extracted from transcripts
- **Claude AI** (cloud) — highest quality, uses your Anthropic API key
- **On-Device AI** (Ollama) — fully local, no data leaves your Mac

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

Once setup is complete, all summaries are generated locally. You can switch back to Claude at any time by disabling the toggle.

---

## Requirements

- macOS 14.4 (Sonoma) or later
- Apple Silicon or Intel Mac
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

**Publish a release:**
```bash
./Scripts/push-update.sh 1.2.0
```

The release script builds, signs, packages a DMG, generates the Sparkle appcast, pushes to GitHub Pages, and creates a GitHub Release.

### Dependencies (via Swift Package Manager)
- [GRDB](https://github.com/groue/GRDB.swift) — SQLite persistence
- [WhisperKit](https://github.com/argmaxinc/WhisperKit) — on-device speech-to-text
- [Sparkle](https://github.com/sparkle-project/Sparkle) — auto-updates

---

## Architecture

```
MeetingManager/
├── App/           — AppState (single observable source of truth), AppDelegate
├── Models/        — Meeting, Transcript, MeetingSummary, AppSettings
├── Database/      — GRDB setup, migrations, repositories
├── Services/
│   ├── AI/        — ClaudeService, OllamaService, OllamaInstaller, SummaryGenerator
│   ├── Audio/     — AudioCaptureService, AudioBufferManager
│   ├── Calendar/  — GoogleCalendarService, GoogleAuthManager
│   ├── Transcription/ — WhisperKit streaming transcriber
│   └── Updates/   — Sparkle UpdateService
└── Views/
    ├── Sidebar/   — SidebarView, MeetingListRow
    ├── MeetingDetail/ — LiveMeetingView, SummaryView, TranscriptView
    └── Settings/  — Per-tab settings views
```

Data flow: `AudioCaptureService` → `StreamingTranscriber` → `TranscriptRepository` → `SummaryGenerator` → `SummaryRepository`

---

## Auto-Updates

Meeting Manager uses [Sparkle](https://sparkle-project.org) for automatic updates. The appcast is hosted at:

```
https://parkerrl-91.github.io/Meeting-Manager/appcast.xml
```

Updates are signed with an EdDSA key. Enable automatic checks in **Settings → Updates**.

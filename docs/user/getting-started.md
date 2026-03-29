# Getting Started

## Installation

1. Download **Meeting-Manager-1.0.5.dmg** from the [releases page](https://github.com/ParkerRL-91/Meeting-Manager/releases)
2. Open the DMG and drag **Meeting Manager** to your Applications folder
3. Launch Meeting Manager from Applications or Spotlight

On first launch, macOS may ask for microphone permission — grant it so Meeting Manager can record your meetings.

---

## First-Time Setup

### 1. Connect Your Calendar (Optional but Recommended)

**Settings → Calendar → Connect Google Calendar**

Meeting Manager will pull your upcoming events and automatically name recordings based on meeting titles. You'll need to grant Google Calendar read access.

### 2. Add Your Claude API Key (For AI Summaries)

**Settings → Claude → API Key**

Paste your Anthropic API key. Meeting Manager uses Claude to generate summaries, extract action items, and identify key decisions from your transcripts.

Get an API key at [console.anthropic.com](https://console.anthropic.com).

### 3. Choose a Transcription Model

**Settings → Transcription → Whisper Model**

- **Tiny** — fastest, lowest accuracy, good for quick notes
- **Base** — balanced (recommended for most users)
- **Small / Medium** — slower but significantly more accurate

The model downloads on first use (~70MB–500MB depending on size).

---

## Recording Your First Meeting

1. Start a call in Zoom, Google Meet, Teams, or any app
2. Meeting Manager detects the call and shows a banner in the sidebar
3. Click **Record** to begin
4. Talk naturally — the transcript updates in real time
5. Click **Stop** when the call ends

Meeting Manager records your microphone. For system audio (to capture other participants), enable it in **Settings → Audio**.

---

## After the Meeting

Once recording stops, Meeting Manager automatically:
1. Transcribes the audio using WhisperKit (on your Mac, no data sent anywhere)
2. Generates a summary using Claude or on-device AI
3. Extracts action items, key decisions, and next steps

You'll see the summary in the meeting detail view. You can regenerate it at any time, change the prompt, or switch between Claude and on-device AI.

---

## The Sidebar

- **Scheduled** — upcoming calendar events and meetings you haven't started yet
- **History** — completed meetings
  - **Recorded** badge — meeting has audio + transcript
  - **Completed** badge — meeting was logged but not recorded

Both sections are collapsible. Click the section header to expand or collapse.

---

## Next Steps

- [Recording Meetings](./recording-meetings.md) — auto-start, manual start, ad-hoc meetings
- [On-Device AI](./on-device-ai.md) — privacy-first local summarization with Ollama
- [Calendar Integration](./calendar-integration.md) — connecting Google Calendar
- [Settings Reference](./settings.md) — every setting explained

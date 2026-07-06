# Getting Started

A 5-minute walkthrough from download to your first recorded meeting.

## Install

1. Download the latest `MeetingManager-vX.Y.Z.dmg` from the [releases page](https://github.com/ParkerRL-91/Meeting-Manager-public/releases).
2. Open the DMG and drag **Meeting Manager** to **Applications**.
3. Launch from Applications or Spotlight (`⌘ Space` → "Meeting Manager").

### First-launch Gatekeeper notice

If macOS shows *"Apple could not verify Meeting Manager"*:

1. Right-click the app in Applications and choose **Open**.
2. If prompted again, click **Done**, then go to **System Settings → Privacy & Security**, scroll to *"Meeting Manager was blocked"*, and click **Open Anyway**.

You only need to do this once.

---

## First-Run Permissions

Meeting Manager asks for the macOS permissions it needs as you use them. Granting them up front saves dialogs mid-meeting:

| Permission | Why it's needed | Where to grant |
|---|---|---|
| **Microphone** | Record your voice | Auto-prompt on first record |
| **Screen Recording** | Capture system audio (other participants) + read meeting window titles | System Settings → Privacy & Security → Screen Recording |
| **Calendar** | Show upcoming meetings, pull attendee names | Settings → Calendar |
| **Reminders** *(optional)* | Push action items to Apple Reminders | Triggered when you enable the toggle |
| **Contacts** *(optional)* | Import names + emails for better speaker ID | People tab → import button |

If anything ever feels stuck after a permission change, **Settings → Troubleshooting → Reset App Permissions** clears the TCC cache for Meeting Manager. See [Troubleshooting](./troubleshooting.md).

---

## Connect Your Calendar (Recommended)

Calendar data is the single biggest accuracy lever for speaker identification.

**Google Calendar:** Settings → Calendar → **Connect Google Calendar** → sign in.
**Apple Calendar / iCloud / Outlook on Mac:** Settings → Calendar → switch source to **Apple Calendar** (uses macOS EventKit, no separate sign-in).

You can use either source, both, or neither. Multi-calendar selection is supported per provider — see [Calendar Integration](./calendar-integration.md).

---

## Set Up AI (One of these)

Meeting Manager generates summaries, action items, and follow-up emails with an LLM. You have three choices:

- **Claude** (recommended): Settings → AI (Claude) → paste your API key from [console.anthropic.com](https://console.anthropic.com). Best results, fastest, costs ~5¢/meeting.
- **Local (Ollama)**: Settings → AI (Local) → install Ollama, pick a model. Free, private, slower. See [On-Device AI](./on-device-ai.md).
- **None**: skip AI entirely; you'll still get the raw transcript.

---

## Record Your First Meeting

1. Start a call in Zoom / Google Meet / Teams / FaceTime.
2. The sidebar shows a "**\<App\> detected**" banner. Click **Record**.
3. Speak naturally. Notes you take live persist alongside the recording.
4. Click **Stop** when the call ends.

After stop, Meeting Manager automatically:
1. Transcribes the audio with WhisperKit (entirely on your Mac)
2. Identifies who spoke when (speaker diarization + attribution)
3. Generates a summary, action items, and a follow-up email

The first meeting takes longer because WhisperKit downloads its model (~1.5 GB). Subsequent meetings start instantly.

---

## What's Where

| UI | What it shows |
|---|---|
| **Home** | Today + upcoming meetings, quick actions |
| **Daily Brief** | One-page rundown of every meeting today with prep notes |
| **Ask Anything** | Chat across all your meetings + knowledge base |
| **People** | Every person you've met with, voice profiles, identity management |
| **Search** | Full-text across transcripts, summaries, and notes |
| **Analytics** | Talk time, meeting load, etc. |
| **Activity** | Background tasks (transcription, summarization) |
| **Spaces** | Auto-grouped meeting folders by attendee/topic |
| **Sidebar footer** | New Meeting button, action items, recording status |

---

## Next Steps

- [Recording Meetings](./recording-meetings.md) — auto-detection, ad-hoc, reopen
- [Calendar Integration](./calendar-integration.md) — Google, Apple, multi-select
- [Speaker Identification](./speaker-identification.md) — how voices are matched to names
- [People Directory](./people-directory.md) — managing identities, Contacts import
- [AI Summaries](./ai-summaries.md) — Claude vs Ollama, prompts, recipes
- [Settings Reference](./settings.md) — every option explained
- [Troubleshooting](./troubleshooting.md) — permissions, calendar, recording
- [Privacy](./privacy.md) — what stays local, what doesn't

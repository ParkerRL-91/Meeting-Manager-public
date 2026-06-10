# Meeting Manager

A native macOS app that records, transcribes, and summarizes your meetings — entirely on your Mac, via Claude AI, or both.

## Download

[**Latest release**](https://github.com/ParkerRL-91/Meeting-Manager/releases/latest) — macOS 14.4+

Open the DMG, drag Meeting Manager to Applications, and launch.

### First Launch — Gatekeeper Notice

Because Meeting Manager is not yet signed with an Apple Developer ID, macOS may block it on first launch with *"Apple could not verify Meeting Manager."*

1. **Right-click** Meeting Manager in Applications and pick **Open**
2. If you still see only "Done" / "Move to Trash":
   - Click **Done**
   - System Settings → Privacy & Security → scroll to *"Meeting Manager was blocked"* → **Open Anyway**

You only do this once.

---

## What's New in v4.2.0

**Stopping and resuming a recording no longer scrambles speaker identification.** When a meeting was recorded in more than one session, the second session's transcript rows could land on the first session's timeline, which let voice matching read the wrong audio and let a retry pass overwrite names you had already confirmed. Session timelines are now offset past the previous file's duration, anonymous speaker labels are namespaced per session, and re-runs fill empty slots without touching existing assignments.

**Recorded audio is cleaner and stays aligned across the meeting.** System audio is written at the position its presentation timestamp dictates instead of its arrival time, which removes the drift between the microphone and system tracks on long calls. A low-pass filter now runs before the microphone's downsample to 16 kHz, so content above 8 kHz no longer folds into the speech band that WhisperKit transcribes.

**Memory headroom on a 16 GB Mac is managed instead of assumed.** The transcription model (~1.5 GB) and the diarization models unload when the work queue goes idle and no meeting is coming up, then reload automatically when recording starts. Crash leftovers from interrupted recordings are detected by content rather than guesswork, and good sessions are kept for transcription instead of being deleted with the husks.

**Local AI summaries no longer stall the queue or come back empty on long meetings.** The Ollama context window is now sized to the machine's physical RAM and to the model's actual trained window (40,960 tokens for Qwen3 — not the 128K headline figure, which requires an extension Ollama doesn't ship), so an hour-plus meeting no longer pushes the model into swap where a 2-minute summary takes an hour. Transcripts that exceed the window are trimmed at the middle with an explicit notice, keeping the agenda and the decisions. Qwen3's reasoning phase gets its own token reserve so thinking can no longer consume the entire output budget, and thinking calls use the sampling values Qwen publishes for the mode.

**Claude models are current.** The default model is now Claude Sonnet 4.6, the Settings picker offers Haiku 4.5 / Sonnet 4.6 / Opus 4.8, and stored settings that referenced the retiring May-2025 snapshots are migrated automatically.

Full changelog at [GitHub Releases](https://github.com/ParkerRL-91/Meeting-Manager/releases).

---

## Documentation

| Doc | What's in it |
|---|---|
| [Getting Started](./docs/user/getting-started.md) | 5-minute install + first-meeting walkthrough |
| [Recording Meetings](./docs/user/recording-meetings.md) | Auto-detection, ad-hoc, reopen, troubleshooting recording |
| [Calendar Integration](./docs/user/calendar-integration.md) | Google + Apple, RSVP, multi-calendar selection |
| [Speaker Identification](./docs/user/speaker-identification.md) | How voice + calendar + AI combine to attribute clusters |
| [People Directory](./docs/user/people-directory.md) | Managing identities, voice profiles, Contacts import |
| [Daily Brief & Pre-Meeting Prep](./docs/user/daily-brief.md) | Pre-meeting context generation |
| [AI Summaries](./docs/user/ai-summaries.md) | Claude vs Ollama, prompts, recipes, action items |
| [On-Device AI](./docs/user/on-device-ai.md) | Ollama setup and tuning |
| [Knowledge Base](./docs/user/knowledge-base.md) | Folder index for cross-meeting context |
| [Settings Reference](./docs/user/settings.md) | Every option explained |
| [Keyboard Shortcuts](./docs/user/keyboard-shortcuts.md) | Quick reference card |
| [Troubleshooting](./docs/user/troubleshooting.md) | Permissions, calendar, recording, AI fixes |
| [Privacy](./docs/user/privacy.md) | What stays local, what goes to AI providers |

---

## Tech Stack

- **Swift 6** + **SwiftUI** + **macOS 14.4+**
- **GRDB** — local SQLite for meetings, transcripts, persons, voice profiles
- **WhisperKit** — on-device transcription (large-v3-turbo by default)
- **SpeakerKit** — pyannote-based speaker diarization (default path)
- **FluidAudio** — on-device diarization + voice identity on the Apple Neural Engine (opt-in preview)
- **Claude API** — optional, for summarization + attribution
- **Ollama** — optional, for fully local AI
- **GitHub Releases** — update distribution via manual download (self-signed DMG; no auto-update)
- **EventKit** — Apple Calendar / Outlook for Mac
- **Google Calendar REST** — Google Calendar
- **Contacts framework** — opt-in identity import

Architecture deep-dives in [docs/developer/](./docs/developer/).

---

## Privacy

Local-first by default. Audio, transcripts, voice fingerprints, and the Person directory all stay on your Mac. Anthropic / Google / Ollama / Apple are only contacted when you explicitly enable a feature that requires them.

Full data-flow breakdown: [docs/user/privacy.md](./docs/user/privacy.md).

---

## Contributing / Building from Source

See [docs/developer/building.md](./docs/developer/building.md) and [docs/developer/contributing.md](./docs/developer/contributing.md).

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

## What's New in v4.3.0

**Recording a meeting now reliably captures your microphone.** Starting a recording at meeting join — or from the pre-meeting notification before the call even exists — used to race the audio stack and could record the whole meeting without your voice, or end the recording after thirty seconds. The app now validates every capture path against real signal, keeps quietly retrying for the entire recording, and picks your microphone up the moment it becomes available. Two live level meters on the recording bar show microphone and call audio at a glance, so a silent input is visible in one second.

**A recording that produces nothing now says so.** Transcription failures used to mark the meeting complete with an empty page. Failures now surface with a plain-English explanation and a Retry button, meetings with audio but no transcript show a Transcribe Now action, and the Summary and Outline tabs report live queue progress instead of generic placeholders.

**Everything is searchable.** Press ⌘K to search across meeting titles, full transcript text, people, and open action items, and jump straight to the result.

**Action items come out of every meeting.** Items are extracted automatically after each summary, appear on the Home screen with completion toggles, roll up per recurring series on its folder page, and can be pushed to Apple Reminders from anywhere they appear.

**Recurring meetings group correctly.** Series folders now consider your whole history instead of a recent window — the sidebar went from five folders to every active series — and folders can be pinned. Restarting a recording mid-call re-attaches to the original meeting instead of creating an "Untitled Event," and all-day or attendee-less calendar blocks no longer collect recordings or trigger notifications.

**Smaller refinements.** Adding a participant suggests matching people from your directory as you type; a mis-attributed transcript segment can be reassigned from its context menu; local AI is tuned for 16 GB Apple Silicon (context windows sized to physical memory, official Qwen3 sampling); and Claude defaults moved to the current model generation.

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

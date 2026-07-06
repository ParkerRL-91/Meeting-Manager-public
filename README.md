# Meeting Manager

A native macOS app that records, transcribes, and summarizes your meetings — entirely on your Mac, via Claude AI, or both.

## Download

[**Latest release**](https://github.com/ParkerRL-91/Meeting-Manager-public/releases/latest) — macOS 14.4+

Open the DMG, drag Meeting Manager to Applications, and launch.

### First Launch — Gatekeeper Notice

Because Meeting Manager is not yet signed with an Apple Developer ID, macOS may block it on first launch with *"Apple could not verify Meeting Manager."*

1. **Right-click** Meeting Manager in Applications and pick **Open**
2. If you still see only "Done" / "Move to Trash":
   - Click **Done**
   - System Settings → Privacy & Security → scroll to *"Meeting Manager was blocked"* → **Open Anyway**

You only do this once.

---

## What's New in v4.13.0

**Ask "catch me up" mid-meeting and get a live summary.** A button in the AI Chat panel on the meeting screen summarizes everything discussed so far and names the current topic, drawing on the full live transcript as it's being captured — no need to type a question or wait for the meeting to end.

**Clear a wedged task inbox in one click.** The task triage Inbox now has a Reject All button alongside Accept All, so a backlog of AI-suggested action items can be dismissed in bulk. The action is reversible via the same Undo bar used for individual dismissals.

Full changelog at [GitHub Releases](https://github.com/ParkerRL-91/Meeting-Manager-public/releases).

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

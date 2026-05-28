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

## What's New in v3.15

**Meetings name themselves.** When you record an ad-hoc meeting and never give it a title, Meeting Manager generates a short name — eight words or fewer — from what was actually discussed. Generation runs on your local Ollama model first and falls back to Claude, so the transcript stays on your Mac whenever a local model is available. Calendar meetings keep the title from their event, and you can always rename any meeting yourself.

**The daily brief draws on your Knowledge Base.** Each meeting's brief can now pull relevant background from your own notes, quoted verbatim and cited to the source file. A deterministic verifier drops any quoted line it can't trace back to your notes, so the brief never attaches one meeting's context to another and never fabricates background.

**Reliability and test coverage.** This release adds an enterprise test suite of roughly 340 cases covering the anti-hallucination verifiers, speaker-identity keys, transcript cleanup, and the data layer, run in continuous integration on every change. The same work fixed a Swift 6 persistence bug in which a saved record's database id was not returned to the caller, which could leave newly created action items, notes, and transcripts referencing a missing row.

**+ everything from 3.11–3.14** (KB-grounded summaries and chat, the auto-generated daily brief, inline task progress, Apollo-powered attendee profiles, bulletproof note autosave, and audio-capture reliability fixes).

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
- **SpeakerKit** — pyannote-based speaker diarization
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

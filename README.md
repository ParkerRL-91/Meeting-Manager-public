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

## What's New in v4.0.0

**Transcription engine upgrade.** WhisperKit has graduated to the Argmax Open-Source SDK 1.0.0 (a major-version jump from the 0.9.x line we were pinned to). On the same audio that produced sparse, fragmented output before, the new engine produces dense coherent paragraphs — in side-by-side testing on a real meeting, the old pipeline returned a single fragment for a 90-second window, and the new one returned nine clean segments and 640 characters of useful text. The upgrade also dropped six transitive dependencies from the build, making the dependency graph dramatically simpler.

**Speaker diarization on the right audio.** Diarization now runs on the system-only audio buffer — the remote participants' voices — instead of the mixed buffer that included your own microphone. On overlapping speech, the old approach falsely split one speaker into several; the new path uses the calendar attendee count as a hint and gives Pyannote the cleaner input it was designed for. The accuracy gain shows up most on group calls.

**Network resilience for AI summaries.** Anthropic Claude, local Ollama, and Apollo lookups now retry transient 5xx errors with exponential backoff, and the Claude path honors the server's `Retry-After` hint on rate limits instead of falling back to a generic backoff. Ollama is also pinned to a known-good version (v0.24.0) with a runtime compatibility check, so an upstream breaking change can't silently strand a new install.

**Honest privacy permissions.** The macOS screen-capture permission prompt now states that Meeting Manager captures system audio during recording (the previous text claimed it did not — a real inaccuracy that the new copy fixes). Apple Events authorization was added so the in-app Chrome tab detection for meeting joins actually works on macOS 14+ instead of failing silently. Four legacy permission keys that were no longer required on macOS 14+ were removed.

**Smaller, faster build.** Intel Macs now route WhisperKit work to the GPU explicitly (the Apple Neural Engine doesn't exist there). The CI pipeline caches Swift Package Manager checkouts so each push is several minutes faster. A long-dormant streaming-transcription service that was never used by the live path was removed.

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

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

## What's New in v4.23.0

**Your weekly review now lives on the Home screen.** The standalone Weekly Review page and its sidebar entry are gone. The full review — the ◀ ▶ week picker, Generate/Refresh, and the queue states with Generate-now and Retry — is now a permanently expanded section on Home, opening on the current review week. Home's separate "Recent" list is removed, and the generated review no longer repeats a Commitments list that duplicated the live Open Action Items already on the same screen.

## Also New Since v4.13.0

A condensed list of the user-facing changes across v4.14.0–v4.22.1.

**Decision Log, expanded.** Decisions gained a triage inbox, correctable ownership, and search/recall. Each decision also records who or what it is *for* — distinct from who made it — surfaced as a "For …" chip, a filter, an editor field, and a subtitle in global search.

**Backup and restore.** A snapshot covers the database, sidecar files, readable markdown, and media (incrementally), restores on next launch, and can run automatically every week. Configured in a new Backup settings tab.

**A much smaller audio library.** Finished recordings are archived to ALAC — verified before the original is deleted — and Settings can backfill an existing library. Captured audio is stored as 16-bit, halving the size of new recordings.

**Quick voice capture.** Record a mic-only voice memo from ⇧⌘M, the menu bar, or a global ⌥⌘R hotkey. It is auto-titled and skips the meeting-only parts of the pipeline.

**Meeting-switch detection.** When the call you are on changes, the app notices and offers to move the recording — as a floating suggestion, a banner on the live-meeting screen, or a menu-bar entry.

**Series open loops in prep.** Pre-meeting prep for a recurring series lists the items still open from earlier instances, completable inline.

**Calendar sync you can trust.** The app now distinguishes revoked access, an unreadable calendar, and a changed connected account; shows an amber banner with Reconnect on Home and a warning row in the menu bar; and keeps its 15-minute refresh honest across sleep and sign-in changes.

**Clearer Home states.** Empty, stale, and error states are stated explicitly instead of a section silently rendering nothing, and an empty day no longer discards the cached daily brief.

**Silent-capture and no-speech visibility.** A recording where both channels stayed silent now says so, and a meeting with no detected speech reaches a final state instead of retrying indefinitely.

**Stability.** Fixed a recurring crash caused by microphone-engine lifecycle races, and release packaging no longer leaves multiple copies of the app behind for Spotlight to find.

**Daily Brief merged into Home** as a schedule rail plus a collapsible AI briefing, a redesigned menu bar popover, Zoom-link extraction from Google Calendar events, and a click-to-pick New Meeting button.

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

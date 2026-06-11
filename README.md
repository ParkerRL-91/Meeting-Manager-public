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

## What's New in v4.4.0

**Your meeting history is now searchable by meaning, not just words.** Every transcript, summary, and Knowledge Base note is indexed locally with an on-device embedding model (downloaded automatically, ~270 MB; nothing leaves your Mac). Asking about "pricing" finds the meeting that discussed "the \ tier," and the existing keyword search still works everywhere the index hasn't caught up.

**The chat answers from your actual meetings, with receipts.** The global chat retrieves the most relevant transcript and summary passages for each question, cites them as [1], [2] in its answer, and shows clickable source chips that open the meeting. When the sources don't contain the answer, it says what's missing instead of guessing.

**Meetings now produce durable knowledge.** After each summary, the app extracts decisions, commitments, and open questions into dossiers on People and Company pages, and every recurring series maintains a running thread — where things stand, the decisions log, carried items — shown on its folder page and fed into the next session's prep brief. A weekly digest summarizes each completed week from this structured record and appears on the Home screen.

**The Knowledge Base sync goes both ways safely.** Exported notes carry front-matter your other tools can link against, externally edited notes are never overwritten (updates land as dated addendum files), and edits in the folder re-index incrementally instead of re-parsing everything.

**Capture more than meetings.** A Quick Memo button in the menu bar records a microphone-only voice note that flows through the full pipeline — transcript, summary, action items — without touching system audio or requiring Screen Recording permission. During a live recording, a "Catch me up" button transcribes and recaps the last three minutes on demand using only the models already in memory.

**Optional cloud privacy shield.** When Claude is configured, a new setting substitutes names, emails, and phone numbers with reversible placeholders before anything is sent, and restores them in the response — applied to summaries, notes, briefs, and chat, with an honest exemption for speaker identification, which needs real names to work.

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

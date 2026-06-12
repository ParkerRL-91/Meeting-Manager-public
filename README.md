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

## What's New in v4.5.0

**Background AI now waits for the right moment.** History indexing, weekly digests, and the new nightly batches run through a governor that holds them while you're recording, when a meeting starts within 20 minutes, on battery (unless you opt in), and whenever you're waiting on an answer yourself — with a 24-hour cap so nothing starves. When the local model is busy, your questions and daily briefs queue visibly and deliver when it frees up instead of spinning forever, and every long-running AI activity — chat answers, briefs, embeddings, cloud calls — now appears in the Activities list so a slow moment always has an explanation.

**Back-to-back meetings stop bleeding into each other.** When the app you were meeting in quits while a recording is still running, Meeting Manager asks "still in this meeting?" and auto-ends the recording three minutes later if you don't answer — so the next call's audio doesn't pile into the previous meeting's record. It stays quiet when remote audio is still flowing.

**Prep cards know what happened since you last met.** Opening prep for a 1:1 shows what involves that person since your previous session: commitments they own, decisions and questions from their meetings, and mentions of them in meetings they didn't attend.

**Summaries learn how you edit.** The first time you rewrite a summary, the app keeps the original alongside your version, and future summaries are shown your before/after pairs so they arrive closer to your preferred structure. A settings toggle controls it, and with the local model the examples only fit alongside shorter meetings.

**Follow-up emails cite the recording.** Each commitment in the draft carries who made it and an approximate transcript moment ("Erica — near 14:32"), and questions left unanswered last session are re-raised automatically under "Still open from last time."

**Dossiers stay truthful as facts change.** A nightly pass links facts across meetings: duplicates get hidden so dossiers stay readable, and when a later meeting reverses a decision, the old bullet renders struck through with the current state underneath — on person dossiers, on folder threads, and as a "Reversals & conflicts" section in the weekly digest that only reports what the record proves.

**The directory flags relationships drifting off rhythm.** Person and Company pages show neutral signal chips when a relationship that usually meets weekly has gone quiet, when meeting cadence halves against its 90-day baseline, or when open action items age past due — with the numbers on hover. New contacts never flag; the math requires real history.

**Search answers more than "where was that said."** ⌘K now lists the colleagues who've already discussed your topic, ranked by relevance and recency. A "View timeline" row turns any query into a chronological record — every meeting that touched the topic, oldest first, with short AI labels naming the position at each point so you can see when a stance changed. Glossary matches surface too: acronyms and project names used in three or more meetings get defined overnight from actual usage, and junk terms are one right-click from permanent removal.

**Company pages keep an FAQ and objection log.** Questions and objections raised by an account are listed with who raised them, in which meeting, and when — exportable as a citable document into your Knowledge Base folder. A background pass backfills these insights from your entire summarized history.

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

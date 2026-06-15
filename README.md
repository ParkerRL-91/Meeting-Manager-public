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

## What's New in v4.6.2

**The app now finds a working microphone instead of giving up on a busy one.** When a recording starts, Meeting Manager tries every available input device in turn — your selected mic, the system default, the built-in microphone, then any others — until one actually starts capturing, and it logs which device it landed on. Earlier versions retried a single device (a problem when your selected mic and system default were the same Bluetooth headset that the meeting app was holding), which could leave a recording with no microphone audio. Bluetooth earbuds in listening mode can't provide microphone input, so the app falls back to the built-in mic automatically — your call audio quality is never downgraded, and your voice is still captured. This release also carries the earlier fix that re-checks the audio format against the hardware before starting, preventing a class of -10868 capture failures after a device switch.

## What's New in v4.6.1

**Capture a slide while it's on screen, find it months later.** A camera button on the recording bar grabs the call window, extracts its text on-device with Apple's Vision OCR, and stores it searchably — nothing is photographed permanently and nothing leaves your Mac. Captured slides appear as a timestamped strip on the meeting's transcript tab and in ⌘K search, so "find the meeting where they showed the pricing slide" works by keyword or by meaning. Capture is strictly manual — one click per slide, no automatic screen monitoring — and the button fails closed: when it can't confidently identify the call window, it captures nothing rather than the wrong thing. Slide text is deliberately kept out of chat answers, where OCR fragments would crowd out transcript content on local models.

## What's New in v4.6.0

**Tell the app what you need from a meeting, and it tells you whether you got it.** Expanding a meeting's prep card reveals a one-line intent field ("agreement on the pilot start date"). After the meeting is summarized, the app compares your intent against what actually happened and posts a neutral verdict at the top of the summary — Got it, Partly, Not this time, or Unclear — with one factual sentence. Folder pages show which recurring series produce decisions (decisions per recorded hour) and how often you leave with what you came for, and the weekly digest aggregates the same numbers.

**One click produces a handover brief for any recurring series.** The Handover button on a folder page generates a six-section document — what this is, where things stand, key decisions, open items, who's who, watch out for — built strictly from the series' recorded threads, facts, and summaries. It is viewable and regenerable in place, and lands in your Knowledge Base folder when sync is on.

**Rehearse the hard conversation before you have it.** Practice mode on Person and Company pages opens a clearly-labeled simulation that argues only from that party's recorded positions — their objections lead — citing each numbered record item so you can audit every claim. When you raise something the record doesn't cover, the persona says so instead of inventing. Conversations are ephemeral and never touch your chat history.

**Contracts and email threads are now first-class knowledge.** Drop a .pdf or .eml file into your Knowledge Base folder and it indexes like everything else — searchable, embedded, and citable in prep briefs and chat answers. PDF text extracts on-device (files over 20 MB are skipped); emails keep sender, subject, and body while attachments and encoding noise are stripped.

**Private speaking trends, if you want them.** An opt-in card on your own People page shows your talk share, question rate, filler density, conversational overlaps, and longest monologue across recent meetings, with a per-series trend line on folder pages. The numbers are computed on-device from transcripts you already have — no AI model ever sees them, nothing leaves the machine, and the card hides with one click.

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

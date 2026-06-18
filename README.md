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

## What's New in v4.7.2

This release recovers a silently-failing microphone on its own and polishes the Key Quotes and Topics screens.

**Your microphone now recovers by itself when it goes silent mid-meeting.** When another app reconfigures a shared microphone and Meeting Manager's capture wedges on a silent stream, the app now detects within seconds that the mic was live and has gone dead-silent, and re-acquires it in place — keeping one continuous recording instead of capturing silence until you notice. A microphone you have deliberately muted, or are simply not speaking into, is never disturbed: it is recognized as healthy and left alone.

**The Topics screen no longer looks empty while it is still working.** Expanding a topic shows that its mentions are loading rather than briefly reading "No mentions yet," and a topic you just added scans your history and updates its own count instead of sitting at zero. Editing a topic from a long list now brings the editor into view.

**Saved quotes and topics are protected from accidental loss, and both screens are more accessible.** Deleting a key quote or a topic now asks for confirmation first, every control on both screens carries a VoiceOver label, and a failed save surfaces a clear message instead of silently doing nothing.

## What's New in v4.7.1

This release refines the features introduced in v4.7.0 with reliability fixes across model setup, playback, and on-device analysis.

**You can now choose your on-device model during onboarding, and its download shows real progress.** The model-selection step is wired into the setup flow, and the runtime download reports its actual percentage as it runs instead of appearing to jump straight to finished. A model you choose is also the one that gets downloaded, rather than being overridden by a default.

**Replaying a finished clip or meeting now works as expected.** Pressing play after a recording has reached its end rewinds to the start and plays, instead of doing nothing.

**Each meeting's tone now reads negated statements correctly.** The on-device sentiment pass recognizes contractions such as "doesn't" and "won't," so a sentence like "this doesn't work" is no longer scored as positive.

This release also serializes optional video capture so two back-to-back meetings can never overlap a recording, makes the active transcript line track playback smoothly on long meetings, and gives clearer messages when an action can't be saved.

## What's New in v4.7.0

**Meeting Manager can now run a private language model entirely on your Mac, set up during onboarding.** A new onboarding step lets you choose and download an on-device model, so summaries, the daily brief, chat, and the other AI features work without an internet connection or an API key, and no meeting content ever leaves your machine. You can still point the app at Claude or your own provider if you prefer.

**You can play a meeting's audio back in sync with its transcript.** A playback bar on the meeting detail view lets you scrub the recording, tap any transcript line to jump straight to that moment, and watch the current line highlight and follow along as the audio plays.

**You can save the exact moments that matter and revisit them as clips and key quotes.** Select a passage in the transcript to keep it as a clip you can replay, mark a line as a key quote with an optional note, and review every quote you have saved across all your meetings in one global list. Clips and quotes stay on your Mac and are never shared anywhere.

**Each meeting now carries a coarse, on-device read of its overall tone.** A lexicon-based sentiment pass runs entirely on your Mac, with no model and no network, and labels each meeting's tone in neutral terms so you can gauge how a conversation went at a glance.

**You can define the topics you care about and see how often they come up across your meetings.** Topic trackers let you name a subject once, and the app then counts and links every meeting where that topic was discussed, so recurring themes are easy to follow over time.

**Meeting Manager can optionally capture the screen or video of a call, and this stays turned off until you enable it.** When you opt in, the app records screen or video alongside the audio through a separate capture path that fails safe — if it cannot start, it never disturbs the audio recording you depend on.

This release also fixes a reliability issue in background maintenance: the weekly digest, glossary, sentiment and topic backfills, and semantic indexing no longer stall behind interactive AI requests, so they finish during quiet periods as intended.

## What's New in v4.6.5

**The daily brief no longer shows the model's reasoning in its output.** When the on-device model occasionally spent its entire budget thinking and produced no final answer, the app fell back to displaying the raw reasoning text — so the brief showed the model "thinking out loud" instead of the briefing. The app now retries to get a clean answer, never surfaces the reasoning field as output, and strips any cut-off reasoning, so the brief always reads as a finished briefing. The same hardening applies to summaries and other on-device generations.

## What's New in v4.6.4

**Slide capture now finds your meeting window even when you use the Google Meet app.** The capture button identifies the meeting window by its title (for example "Google Meet") rather than only by a hardcoded list of apps, so the Google Meet desktop app — which runs as a Chrome web app and was previously unrecognized — is now captured correctly, alongside meetings in a browser tab, Zoom, and Teams. If the window genuinely can't be identified, the app still declines to capture rather than grabbing your whole desktop, and it now records what it saw so the case can be diagnosed.

## What's New in v4.6.3

**Meeting Manager now captures from the microphone your meeting is actually using.** When a recording starts, it looks at which input device the meeting app already has open and tries that one first — so if you're on an external mic or headset, that's what gets recorded. The built-in laptop microphone is now tried last rather than as a fallback anchor, because with the lid closed (clamshell mode) the built-in mic is disabled and would capture silence. Combined with the device-cycling from v4.6.2, the app reliably finds a working mic across closed-lid, external-mic, and Bluetooth setups instead of getting stuck on an unusable default.

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

# Settings Reference

Every settings tab and what it does. Open: `⌘,` or **Meeting Manager → Settings**.

## General

- **Theme** — dark / light. Light mode supported on macOS 14+.
- **Launch at login** — start Meeting Manager when you sign in.
- **Notification lead time** — minutes before a meeting starts to fire a desktop notification (default 5).
- **Morning brief** — daily macOS notification with the day's schedule. Off by default.
- **Auto-generate summary** — fire summary AI after recording stops. On by default.
- **Auto-generate follow-up email** — draft email after summary. Off by default.
- **Auto-push action items to Reminders** — push extracted items to Apple Reminders. Off by default.

## Audio

- **Microphone** — pick which input device to record from. Auto-switches when devices change.
- **System audio** — toggle whether to capture system audio (other participants). Requires Screen Recording permission.

## Transcription

- **Whisper model** — `large-v3-turbo` (default), `large-v3`, `medium`, `small`. Switching downloads the new model on first use.
- **Language** — BCP-47 hint for transcription (default `en`).

Transcription runs after the recording stops (batch); there is no live
transcript during the meeting.

## Calendar

- **Source** — Google / Apple / Both / None.
- **Connect Google Calendar** — OAuth sign-in.
- **Apple Calendar permission** — opens System Settings if denied.
- **Calendar selection** — multi-select per provider.
- **Sync interval** — 5 / 15 / 30 / 60 minutes (default 15).

See [Calendar Integration](./calendar-integration.md).

## AI (Claude)

- **API key** — paste from [console.anthropic.com](https://console.anthropic.com). Stored in Keychain.
- **Default model** — `claude-sonnet-4-6` (default); Claude Haiku 4.5 (Fast) and Claude Opus 4.8 (Premium) are also selectable.
- **Status** — green when valid, red on auth failure.

## AI (Local)

- **Use local LLM** — toggle to use Ollama as default provider.
- **Ollama status** — reachable / unreachable + latency.
- **Default model** — pick from installed Ollama models.
- **Auto-pick model** — let the app choose per-task.

See [On-Device AI](./on-device-ai.md).

## Prompts

Editable templates for:

- Meeting summary
- Pre-meeting brief
- Follow-up email
- Default chat system prompt

Each has a **Reset to default** button.

## Templates

- **Meeting templates** — pre-fill the notepad with structure (1:1, Standup, Planning Session, custom).
- **Recipes** — one-off AI prompts with custom output (LinkedIn posts, Jira tickets, etc.). See [AI Summaries](./ai-summaries.md#recipes).

## Voices

- **Stored profiles** — every voice fingerprint with sample count + last updated.
- **Delete profile** — remove a single fingerprint.
- **Rebuild from history** — wipe and re-extract from confirmed-name transcripts.

The People tab in the main app is a richer view — see [People Directory](./people-directory.md).

## Knowledge Base

- **Choose folder** — point at a folder of `.md`/`.txt`/`.html`/`.docx` files.
- **Re-index** — force a full rebuild.
- **Watch for changes** — FSEvents-based, on by default.
- **Write meeting notes back** — exports completed meetings as Markdown into the KB folder.

See [Knowledge Base](./knowledge-base.md).

## Integrations

- **Apollo.io API key** — paste to enable attendee profile prep (titles,
  employer, LinkedIn) on meeting and people views. Stored in Keychain;
  a Test button validates it. Off until you enable the toggle.

## About

A static panel:

- App version + build
- **Open GitHub Releases** — updates are manual: the button opens the
  releases page in your browser and you download the new version yourself
  (no auto-update; Sparkle was removed)

**Reset App Permissions** (clears macOS TCC entries for Meeting Manager)
lives in Settings → **General**.

---

## Settings Storage

Settings live in `~/Library/Application Support/MeetingManager/db.sqlite` (single GRDB row). API keys are in macOS Keychain. To back up: copy the database file plus the `Audio/` folder. See [Privacy → Local Storage Locations](./privacy.md#local-storage-locations).

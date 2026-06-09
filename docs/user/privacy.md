# Privacy

What stays on your Mac, what doesn't, and the controls you have over both.

## Local-First by Design

Meeting Manager is built around the assumption that meeting content is sensitive. By default:

- **Audio recordings** stay on your Mac. They're never uploaded.
- **Transcripts** stay on your Mac (WhisperKit runs locally).
- **Speaker fingerprints** stay on your Mac.
- **Notes, calendar data, person directory** stay on your Mac.
- **Knowledge base index** stays on your Mac.

Nothing leaves until you explicitly enable an AI feature that requires it.

---

## What Goes to Anthropic (Claude API)

Only when you've configured Claude in Settings → AI (Claude) **and** trigger a feature that uses it:

| Feature | What's sent | What's NOT sent |
|---|---|---|
| Summary | Cleaned transcript + your prompt template + meeting metadata (title, date, attendees) | Other meetings, voice fingerprints, raw audio |
| Speaker attribution | First ~20 turns per cluster + attendee names + the user's first name | Full transcript, audio, voice fingerprints |
| Pre-meeting brief | Meeting metadata + summaries from related past meetings + relevant KB chunks | Audio, full transcripts |
| Follow-up email | Cleaned transcript + summary + meeting metadata | — |
| Action items | Cleaned transcript + meeting metadata | — |
| Ask Anything chat | The selected meetings' summaries + relevant KB chunks + your message | Audio, voice fingerprints |
| Recipes | Whatever the recipe template includes (you control this) | Whatever you don't include |

Anthropic's API does not train on user data per their default API policy. Their data retention policy applies (typically 30 days for abuse review). See [Anthropic's privacy policy](https://www.anthropic.com/privacy).

API keys are stored in your macOS Keychain.

---

## What Goes to Ollama (On-Device)

Nothing leaves your Mac. Ollama runs as a local HTTP server on `localhost:11434`. The app sends prompts and reads responses over loopback only. No network.

The same content that would go to Claude goes to Ollama for the same features — but it stays on your machine.

---

## What Goes to Google (Calendar)

Only if you connect Google Calendar:

- An OAuth token is stored in your Keychain
- The app reads (only) calendar events you've authorized
- Read-only — the app never writes to your calendar

You can revoke access any time in your Google Account → Security → Third-party apps. Disconnecting from Settings → Calendar does the same locally.

---

## What Goes to Apple

Only if you grant Calendar / Reminders / Contacts access:

- **Calendar:** read-only, via macOS EventKit — Apple sees the same access pattern as Calendar.app
- **Reminders:** the app writes action items into the Reminders database. Apple syncs Reminders across your devices via iCloud per your iCloud settings.
- **Contacts:** read-only, only when you trigger Contacts import in the People tab. Names + emails only.

Audio capture, screen window-title reading, and microphone are all macOS-mediated. Apple doesn't see the content (the app reads them locally), only the permission grants.

---

## What Goes to Apollo.io (Optional Enrichment)

Off by default. Only when you paste an Apollo API key in Settings →
Integrations **and** enable attendee profile prep does the app call
Apollo's `people/match` endpoint (`api.apollo.io`).

- **What's sent:** the attendee's email address, nothing else. Company
  cards reuse the same lookup with a representative member's email.
  Personal-email and phone reveal flags are explicitly set to false.
- **What's NOT sent:** meeting content — no transcripts, no summaries, no
  notes, no audio, ever.
- Results are cached locally (7-day TTL); consumer email domains (gmail
  etc.) are never looked up. Remove the key or turn the toggle off and no
  Apollo calls are made.

---

## Update Channel

There is no auto-update framework (Sparkle was removed). The app makes
**no update-check network calls**. Updates are manual: Settings → About →
"Open GitHub Releases" opens the releases page in your browser, and you
download the new DMG yourself.

---

## Telemetry

There is no telemetry. The app does not phone home. There's no analytics SDK, no crash reporter (yet), no usage tracking. The only outbound calls are:

- AI provider you configured (Claude or Ollama on localhost)
- Calendar provider you configured (Google or Apple)
- Apollo.io attendee lookups, only if you configured an Apollo API key

If you want to verify, run:

```bash
sudo lsof -i -P -n | grep -i meeting
```

while the app is running. You'll see only the connections above.

---

## Local Storage Locations

| Data | Path |
|---|---|
| Database (meetings, persons, profiles, settings) | `~/Library/Application Support/MeetingManager/db.sqlite` |
| Audio recordings | `~/Library/Application Support/MeetingManager/Audio/` |
| WhisperKit models | `~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/` |
| API keys (Claude, Google OAuth, Apollo) | macOS Keychain (separate from database) |
| Logs | `~/Library/Application Support/MeetingManager/app.log` (+ rotated `app-YYYY-MM-DD.log`) |

---

## Deleting Everything

To fully remove Meeting Manager and all its data:

1. Move the app to Trash from `/Applications`.
2. Delete the data directory (logs live inside it):
   ```bash
   rm -rf ~/Library/Application\ Support/MeetingManager
   ```
3. Open Keychain Access and delete entries containing "meetingmanager" or "Meeting Manager".
4. Revoke Google Calendar access at [myaccount.google.com](https://myaccount.google.com/permissions).
5. Reset macOS permission grants: Terminal → `tccutil reset All com.meetingmanager.app`.

Empty Trash to free disk space.

---

## Backups

The single source of truth is the `db.sqlite` file plus the `Audio/` folder. Time Machine backs both up automatically if your `~/Library/Application Support` is included in your backup scope.

For a manual backup:

```bash
cp -R ~/Library/Application\ Support/MeetingManager ~/Desktop/MeetingManager-backup-$(date +%Y%m%d)
```

To restore: copy back over a closed app.

---

## Reporting Concerns

If you find a privacy bug — data leaving the device unintentionally, a feature that sends more than it should — open an issue at [github.com/ParkerRL-91/Meeting-Manager/issues](https://github.com/ParkerRL-91/Meeting-Manager/issues) with reproduction steps. We treat these as critical.

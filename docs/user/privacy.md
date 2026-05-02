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

## Update Channel

Sparkle (the auto-update framework) makes one outbound HTTPS call to:

```
https://parkerrl-91.github.io/Meeting-Manager/appcast.xml
```

This fetches the appcast XML to check for new versions. The request is anonymous — no telemetry, no identifying headers.

When an update is available, Sparkle downloads the DMG from a GitHub releases URL. Same anonymity.

---

## Telemetry

There is no telemetry. The app does not phone home. There's no analytics SDK, no crash reporter (yet), no usage tracking. The only outbound calls are:

- AI provider you configured (Claude or Ollama on localhost)
- Calendar provider you configured (Google or Apple)
- Sparkle update check (one URL, no payload)

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
| Audio recordings | `~/Library/Application Support/MeetingManager/recordings/` |
| WhisperKit models | `~/Library/Application Support/MeetingManager/models/` |
| API keys | macOS Keychain (separate from database) |
| Sparkle EdDSA verification key | macOS Keychain |
| Logs | `~/Library/Logs/MeetingManager/` |

---

## Deleting Everything

To fully remove Meeting Manager and all its data:

1. Move the app to Trash from `/Applications`.
2. Delete the data directory:
   ```bash
   rm -rf ~/Library/Application\ Support/MeetingManager
   rm -rf ~/Library/Logs/MeetingManager
   ```
3. Open Keychain Access and delete entries containing "meetingmanager" or "Meeting Manager".
4. Revoke Google Calendar access at [myaccount.google.com](https://myaccount.google.com/permissions).
5. Reset macOS permission grants: Terminal → `tccutil reset All com.meetingmanager.app`.

Empty Trash to free disk space.

---

## Backups

The single source of truth is the `db.sqlite` file plus the `recordings/` folder. Time Machine backs both up automatically if your `~/Library/Application Support` is included in your backup scope.

For a manual backup:

```bash
cp -R ~/Library/Application\ Support/MeetingManager ~/Desktop/MeetingManager-backup-$(date +%Y%m%d)
```

To restore: copy back over a closed app.

---

## Reporting Concerns

If you find a privacy bug — data leaving the device unintentionally, a feature that sends more than it should — open an issue at [github.com/ParkerRL-91/Meeting-Manager/issues](https://github.com/ParkerRL-91/Meeting-Manager/issues) with reproduction steps. We treat these as critical.

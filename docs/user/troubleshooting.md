# Troubleshooting

The most common issues and their fixes, in roughly the order they tend to come up.

## Permissions

### "App needs permission" prompt won't go away even after I granted

macOS's TCC (Transparency, Consent & Control) cache occasionally gets stuck — the system says you've granted permission but the app's TCC entry is missing or stale.

**Fix:** Settings → **General** → **Reset App Permissions**.

This clears every TCC entry for Meeting Manager. macOS will re-prompt the next time you do something that requires the permission, and you can grant fresh.

If reset doesn't help: System Settings → Privacy & Security → toggle Meeting Manager off and on for the relevant permission category.

### Microphone permission keeps disappearing on rebuild

Local development only — applies if you build from source. macOS treats every code-sign change as a different app. Use the persistent `MeetingManager-Dev` cert via `Scripts/install-local.sh` so TCC grants stick across rebuilds.

### Apple Calendar shows "no calendars" after granting

The classic stuck-instance bug. The app rebuilds the EventKit store automatically when it detects this, but if it persists:

1. Settings → Calendar → switch source to **Google Calendar** then back to **Apple Calendar**.
2. If still empty, fully quit the app (`⌘ Q`) and relaunch.
3. If still empty, **Reset App Permissions**, regrant.

---

## Recording

### No system audio in the transcript (only my voice)

Screen Recording permission is missing. System Settings → Privacy & Security → Screen Recording → toggle Meeting Manager.

### Recording stopped early

Possible causes:

- **Mac slept** — macOS suspends Screen Capture Kit on sleep. Use a Caffeinate utility or set energy saver to never sleep during meetings.
- **Microphone disconnected** — AirPods went out of range, USB device unplugged. Check Settings → Audio → Microphone for the current input.
- **Disk full** — recordings need ~10MB per minute of audio. Check available space.

### No transcript appearing during the call

That's expected — there is no live transcript. Transcription runs after
you stop the recording. If the transcript doesn't appear after stopping:

- **WhisperKit model not loaded yet** — Settings → Transcription. Wait for the download to finish (progress shown in menu bar). The transcription is queued and runs once the model loads.
- **CPU pinned by another app** — close heavy background apps; the queued task retries.

### Can't reopen a completed meeting

The reopen button only appears when:

- Status is Complete or Cancelled
- Not all-day
- Within the meeting's scheduled window OR up to 60 minutes after the scheduled end

If you need to append audio outside that window, create a new meeting from the **+ New Meeting** button and paste any context into the notes.

---

## Calendar

### Google Calendar shows "Access revoked"

The OAuth token has expired or been revoked from Google's side (often after a Google security event).

**Fix:** Settings → Calendar → **Disconnect**, then **Connect Google Calendar** again.

### Apple Calendar events disappear randomly

Usually an iCloud sync issue, not Meeting Manager. Open Calendar.app and confirm the events are visible there. If not, fix iCloud sync in System Settings → Internet Accounts.

### Outlook for Mac events not showing up

You need Apple Calendar as your source — Outlook for Mac publishes events into the macOS calendar store. Settings → Calendar → Source → **Apple Calendar** (or Both).

---

## AI

### "Ollama unreachable" but I have it installed

`ollama serve` isn't running. Either:
- Click the Ollama menu bar icon to start the background service
- Or in Terminal: `ollama serve`

### Claude calls fail with "Invalid API key"

The key in Settings → AI (Claude) doesn't match a valid key on Anthropic's side. Generate a new one at [console.anthropic.com](https://console.anthropic.com), paste, and retry.

### Summary takes forever

- Claude: should be 5–15 seconds. Longer = network issue or Anthropic API congestion.
- Ollama: depends on model. 70B can take 1–3 minutes. Switch to a smaller model in Settings → AI (Local) if speed matters.

### Action items always come back empty

Either:
- The transcript is too short (fewer than ~5 turns) — AI declines to extract
- The meeting was monologue-only — no clear action commitments
- The action item prompt was edited and broken — Settings → Prompts → reset to default

---

## Speaker Identification

### Wrong names showing up in the transcript

- Click the wrong label, pick the right name. The voice profile retrains immediately for the next meeting.
- If a single Person record is collecting two different humans (rare), open the People tab → person → Manage Identity → remove the wrong aliases.

### Same person showing up as two People records

Domain disambiguation thought they were different (e.g., they switched jobs and the email domain changed). People tab → open one → Manage Identity → **Merge duplicate** → pick the other.

### Amber dots on every speaker label

You're using local Ollama for attribution and the app is honestly signaling that those attributions are lower-trust than Claude. This is by design — the dots flag clusters worth a glance, not errors. If they're correct, you can ignore them; the next time you confirm/rename them, the dot disappears.

If you'd rather have Claude do attribution: Settings → AI (Claude) → paste an API key. The next meeting attribution uses Claude haiku (no dots).

---

## Updates

Updates are manual — there is no auto-update prompt. Settings → About →
**Open GitHub Releases** opens the releases page; download the new DMG and
replace the app. If macOS quarantine flags the downloaded version, you'll
see Gatekeeper warnings — right-click the app → **Open** to bypass.

---

## Database / Storage

### App crashes immediately on launch with "Database could not be opened"

A migration failed. The most common cause is corrupted task queue rows from earlier versions.

**Fix:** quit the app, delete:
```
~/Library/Application Support/MeetingManager/db.sqlite
```
Relaunch. The app rebuilds the database from scratch. **You will lose all meeting history and summaries** — only do this if there's no other option, and back up the file first.

### App is slow / unresponsive over time

Likely the database is huge from years of meetings. There is no in-app compaction button; with the app quit you can compact it manually:

```bash
sqlite3 ~/Library/Application\ Support/MeetingManager/db.sqlite 'VACUUM;'
```

### Migrating to a new Mac

Copy these to the same paths on the new Mac:

- `~/Library/Application Support/MeetingManager/` — entire folder (database + audio files)
- macOS Keychain entries for `com.meetingmanager` (Claude API key, Google OAuth, Apollo key). Use Keychain Access → File → Export to back up.

---

## Still stuck?

- File an issue at [github.com/ParkerRL-91/Meeting-Manager/issues](https://github.com/ParkerRL-91/Meeting-Manager/issues), attaching the relevant log file from `~/Library/Application Support/MeetingManager/` (`app.log`, plus rotated `app-YYYY-MM-DD.log` files).
- The logs don't include transcript text, though they may mention meeting titles and attendee names — strip anything sensitive before posting.

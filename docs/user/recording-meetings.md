# Recording Meetings

How recording works, what's captured, and how to fix common problems.

## Three Ways to Start a Recording

### 1. Auto-detection (default)

When Zoom, Google Meet, Teams, FaceTime, or another video-call app opens a meeting window, Meeting Manager surfaces a **"\<App\> detected"** banner in the sidebar. Click **Record** to begin.

Detection uses the active window title — no screen content is captured or transmitted. The app polls window titles roughly once per second when no meeting is active.

### 2. Manual start from a calendar event

Open the meeting from the sidebar or Home. Click **Record** in the meeting detail view. Use this when auto-detection didn't fire (e.g., the call started in a browser tab).

### 3. Ad-hoc

Click **+ New Meeting** at the bottom of the sidebar. A blank meeting is created and recording starts immediately. You can rename the title and add participants from the meeting detail view.

---

## What Gets Captured

Two audio streams, mixed and saved to disk:

- **Microphone** — your voice, tagged as the `mic` stream in the transcript
- **System audio** — everything coming out of your speakers (other participants, music, etc.), tagged as the `system` stream

System-audio capture uses macOS Screen Capture Kit and requires Screen Recording permission. Without it, you'll only see your own voice in the transcript.

Both streams are written to a single mixed `.wav` file plus a separate `_system.wav` file used for speaker fingerprinting later.

---

## During the Recording

The Live Meeting view splits into:

- **Pre-meeting brief** at the top — the AI-generated context for this meeting (related past meetings, attendees, agenda hints).
- **Notepad** in the middle — type freely. Notes are saved continuously and survive a crash.
- **Chat panel** on the right — ask questions across the meeting + your knowledge base while it's happening.
- **Recording strip** at the bottom — elapsed time, participant chips, and the **Stop** button.

You can also stop recording from the sidebar bar that appears whenever a meeting is active.

---

## After Stop

A pipeline of background tasks fires automatically:

1. **Transcription** — WhisperKit converts audio to text on your Mac.
2. **Speaker diarization** — SpeakerKit clusters voices into Speaker 1, Speaker 2, etc.
3. **Speaker attribution** — combines voice fingerprints, vocative mining, calendar attendees, and an LLM call to map clusters to real names. See [Speaker Identification](./speaker-identification.md).
4. **Transcript cleanup** — produces a clean readable version of the segment-by-segment transcript.
5. **Second-pass attribution** — if any clusters are still unresolved, retries against the full transcript.
6. **Summary, action items, follow-up email** — using your default prompt and provider.

Watch progress in the **Activity** sidebar entry. Most meetings finish within 2–5 minutes of stop.

---

## Editing Speakers

Speakers can be renamed at any time:

1. Open the **Full Transcript** view.
2. Click any speaker label. A menu appears with the meeting's attendees.
3. Pick the right person, or click **Add custom...** to type a name.

Renames update **everywhere at once**:

- Every raw transcript row for that cluster
- The cleaned transcript view (the readable post-processed version)
- The meeting's `speakerMap` and confidence map (manually-renamed = 1.0 confidence)
- The voice fingerprint database, so future meetings recognise this person automatically
- The series-level alias memory, so the next recurring meeting pre-seeds the rename

A small **amber dot** next to a speaker label means the attribution confidence was low — consider verifying it. The dot disappears as soon as you confirm or rename.

---

## Reopening a Meeting

If you stopped recording too early or your Mac crashed mid-call, you can reopen the meeting and append more audio. Reopen is available when:

- Status is **Complete** or **Cancelled** (crashed)
- Not all-day
- Current time is within the scheduled window or up to 60 minutes after the scheduled end

Click **Reopen** from the meeting detail view. Recording resumes; appended audio is transcribed and merged with the existing transcript.

---

## Notes Behavior

- Notes auto-save every keystroke
- Notes are independent of the transcript — you control what goes in them
- Markdown is rendered in the meeting detail view but stored as plain text
- A meeting template (Settings → Templates) can pre-fill structure (e.g., "Wins / Blockers / Action items")

---

## Common Issues

- **No system audio:** Screen Recording permission missing. System Settings → Privacy & Security → Screen Recording.
- **Microphone empty:** Settings → Audio → Microphone. macOS sometimes routes to a Bluetooth device that's powered off.
- **WhisperKit model won't download:** Settings → Transcription → **Re-download model**, or pick a smaller model variant.
- **Recording stopped early after sleep:** macOS suspends Screen Capture Kit on sleep. Disable sleep during meetings.

More fixes: [Troubleshooting](./troubleshooting.md).

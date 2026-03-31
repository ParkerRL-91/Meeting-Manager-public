# Recording Meetings

## Automatic Detection

Meeting Manager watches for active call applications and shows a banner in the sidebar when one is detected:

> **Zoom detected** · Tap to begin recording

Supported apps: Zoom, Google Meet (browser), Microsoft Teams, FaceTime, and any app that uses your microphone.

Click **Record** in the banner to start. The recording is associated with the nearest upcoming calendar event if one exists within 15 minutes.

---

## Manual Start

To start a recording without a detected call:

1. Click **+ New Meeting** at the top of the sidebar
2. An ad-hoc meeting is created and recording begins immediately
3. You can rename it from the meeting detail view

---

## During Recording

While recording, the sidebar shows a compact recording bar:

```
● Recording   00:12:34   [■ Stop]
```

The elapsed timer updates every second. Click **Stop** to end the recording.

You can navigate freely — view past meetings, open settings — while the recording continues in the background.

---

## Audio Sources

**Settings → Audio** controls what gets recorded:

| Source | What it captures |
|--------|-----------------|
| Microphone | Your voice only |
| System Audio | All audio on your Mac (other participants, music, etc.) |
| Both | Combined — recommended for call recordings |

System audio capture requires a virtual audio device. Meeting Manager will prompt you to install one if it's not present.

---

## After Recording Stops

Meeting Manager automatically starts the post-processing pipeline:

1. **Transcribing** — WhisperKit converts audio to text (on-device, ~1–3× real time)
2. **Summarizing** — Claude or Ollama generates the summary
3. **Complete** — The meeting appears in History with a **Recorded** badge

You can open the meeting at any point to watch the transcript appear in real time.

---

## Ad-Hoc Meetings

Ad-hoc meetings (created with **+ New Meeting**) are not linked to calendar events. They appear in History as "New Meeting" by default — rename them from the meeting detail view by clicking the title.

---

## Tips

- **Long meetings:** WhisperKit processes audio in chunks. For meetings over 2 hours, transcription may take several minutes after recording stops.
- **Poor transcript quality:** Try a larger Whisper model in **Settings → Transcription**. Base is the default; Small or Medium are significantly more accurate.
- **Overlapping speakers:** The transcript shows speaker labels when the model can distinguish voices. Quality varies by recording conditions.

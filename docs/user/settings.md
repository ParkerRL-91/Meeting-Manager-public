# Settings Reference

## General

| Setting | Description |
|---------|-------------|
| **Theme** | Dark, Light, or System (follows macOS appearance) |
| **Launch at Login** | Start Meeting Manager when you log in |
| **Remind me N min before meetings** | Desktop notification before scheduled meetings start |

---

## Audio

| Setting | Description |
|---------|-------------|
| **Input Device** | Microphone to use for recording |
| **System Audio** | Capture all Mac audio (other call participants, etc.) |
| **Auto-Record** | Start recording automatically when a call app is detected |

---

## Transcription

| Setting | Description |
|---------|-------------|
| **Whisper Model** | Tiny / Base / Small / Medium — larger = more accurate, slower |
| **Language** | Auto-detect or specify a language |

Whisper models are downloaded on first use and stored locally. They run entirely on your Mac — no audio is sent anywhere.

---

## Calendar

| Setting | Description |
|---------|-------------|
| **Connect Google Calendar** | OAuth flow to link your Google account |
| **Calendars** | Select which calendars to show in the Scheduled sidebar |
| **Auto-Invite** | Automatically join detected meetings from calendar events |

Meeting Manager requests read-only Calendar access. It never modifies your calendar.

---

## Claude

| Setting | Description |
|---------|-------------|
| **API Key** | Your Anthropic API key (stored in macOS Keychain, never logged) |
| **Model** | Claude model to use for summaries (claude-sonnet-4-6 recommended) |

---

## On-Device

| Setting | Description |
|---------|-------------|
| **Use On-Device Summarization** | Route summaries to local Ollama instead of Claude |
| **Model** | Which Ollama model to use (requires model to be pulled) |

Enabling this toggle automatically downloads and installs Ollama if it's not present, then pulls the default model. See [On-Device AI](./on-device-ai.md) for details.

---

## Prompts

Customize the system prompt used when generating summaries. The default prompt instructs the AI to produce:
- A 3–5 sentence executive summary
- A bulleted list of action items with owners
- Key decisions made
- Topics discussed

You can edit this to match your team's preferred format, add company context, or change the output structure.

---

## Updates

| Setting | Description |
|---------|-------------|
| **Automatically check for updates** | Let Sparkle check for new versions in the background |
| **Check for Updates Now** | Manually trigger an update check |

Updates are downloaded and verified with an EdDSA signature before installation. The update feed is at `https://parkerrl-91.github.io/Meeting-Manager/appcast.xml`.

# AI Summaries, Action Items, and Recipes

How the post-meeting AI pipeline works, and how to bend it to your workflow.

## What Gets Generated

After every recording, Meeting Manager runs an AI pipeline that produces:

1. **Summary** — a structured one-page summary using your default prompt template
2. **Action items** — extracted with assignee + due date when stated
3. **Follow-up email draft** — `Subject:` + body, ready to send (if enabled)
4. **Cleaned transcript** — readable version of the raw segment-by-segment WhisperKit output

You can regenerate any of these any time without re-recording.

---

## Pick a Provider

Meeting Manager supports two AI backends:

### Claude (recommended)

Settings → **AI (Claude)** → paste your API key from [console.anthropic.com](https://console.anthropic.com).

- Best summary quality
- Fastest (typically 5–15 seconds)
- ~3–8¢ per meeting depending on length and model
- Default model: `claude-sonnet-4-6`. Change via Settings → AI (Claude) → Model.

The API key is stored in your macOS Keychain. The app sends only the meeting transcript + the prompt template — no metadata, no cross-meeting context unless that's explicitly part of the prompt (e.g., the pre-meeting brief).

### Ollama (on-device)

Settings → **AI (Local)** → install Ollama from [ollama.com](https://ollama.com), pick a model.

- Runs on your Mac, nothing sent to a remote server
- Free
- Slower (30s–3min depending on model and hardware)
- Quality varies by model — `llama3.2:8b` is a reasonable starter; larger models do better summaries

See [On-Device AI](./on-device-ai.md) for the full setup.

---

## Summary Prompts

Settings → **Prompts** has the editable prompt templates:

- **Meeting summary** — used for the default one-page summary. Tuned to produce clear arc-of-discussion summaries with decisions and unresolved threads called out.
- **Pre-meeting brief** — used by the brief feature.
- **Follow-up email** — produces `Subject: ...` + body so the app can split it cleanly.

Templates use `{{variable}}` placeholders. Available placeholders:

- `{{meetingTitle}}`, `{{date}}`
- `{{transcript}}` — the cleaned full transcript
- `{{notes}}` — your notepad content
- `{{participants}}` — comma-separated attendee list

**Reset to default** at the bottom of each editor restores the shipped prompt.

---

## Recipes

A **recipe** is a one-off prompt you can run on any meeting from the meeting detail view. Examples:

- "Draft 3 LinkedIn posts based on this meeting's themes"
- "Convert action items to Jira tickets in this format"
- "Pull out every metric mentioned and put it in a markdown table"

Settings → **Templates** → **+ New Recipe** → name it, paste a prompt template (with the same `{{}}` placeholders), save.

Run from the meeting detail's recipe menu. Output is saved with the meeting and re-runnable.

Built-in recipes:

- **Follow-up email** (`builtin-follow-up-email`)
- **Action items** (`builtin-action-items`)
- **Coaching feedback** (`builtin-coaching-feedback`) — for 1:1s

---

## Action Items

Action items are extracted into a dedicated table per meeting. Each item has:

- Title
- Optional assignee (the AI infers from "Bob will..." patterns)
- Optional due date

**Push to Apple Reminders:** Settings → General → Auto-push action items. Requires Reminders permission. Items push immediately after extraction.

The aggregate view across all meetings is in the sidebar's **Action Items** button (bottom dock). Filter by completed / pending / assigned to you.

---

## Auto-Generation Toggles

Settings → **General** has the master toggles:

- **Auto-generate summary** — runs after every recording. On by default.
- **Auto-generate follow-up email** — drafts an email after summary completes. Off by default.
- **Auto-push action items to Reminders** — only fires for items with an assignee or due date. Off by default.

When off, you can run any of these manually from the meeting detail view's action menu.

---

## Re-running

Any AI output can be regenerated:

- **Summary:** click **Regenerate** in the summary card. Optionally pick a recipe to use instead of the default prompt.
- **Action items:** menu → Regenerate Action Items.
- **Cleaned transcript:** menu → Re-clean Transcript.
- **Speaker attribution:** menu → Re-run Speaker AI.

Regenerations queue as background tasks (visible in **Activity**). You can keep working — old output stays visible until the new one completes.

---

## Cost Reference (Claude)

| Operation | Tokens | Approx cost (Sonnet 4.6) |
|---|---|---|
| Pre-meeting brief | 1–3k | $0.005–$0.015 |
| Summary (30-min meeting) | 4–10k input | $0.01–$0.04 |
| Speaker attribution | 1–2k | $0.003–$0.008 |
| Follow-up email | 4–10k | $0.01–$0.04 |
| Action items | 4–10k | $0.01–$0.04 |

A typical 30-minute meeting end-to-end: ~5–8¢. A heavy day of 6 meetings: ~30–50¢.

The "two-tier" attribution call uses Claude haiku for the cheap pass (sub-cent) and only escalates to Sonnet when the cheap pass returns "Unknown".

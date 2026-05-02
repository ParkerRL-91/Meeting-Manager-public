# Speaker Identification

How Meeting Manager figures out *who said what* — and what to do when it gets it wrong.

## The Problem

Speech recognition tells you *what* was said. Diarization clusters those words into "Speaker 1, Speaker 2, ..." groups. Neither tells you **which group is Alice and which is Bob**. That's identification, and it's the hard problem.

## Signal Stack

Meeting Manager combines five independent signals to attribute clusters to real names. Each has a different cost / accuracy / hallucination profile, and the pipeline is designed so the strongest signal wins:

| Signal | Source | Confidence range |
|---|---|---|
| **Manual rename** | You renamed a speaker label | 1.00 |
| **Voice fingerprint match** | Cosine similarity vs stored 40-dim mel-spectrum embedding | 0.82 – 0.99 |
| **Vocative mining** | "Hey Alice" / "Thanks Bob" patterns near cluster transitions | 0.55 – 0.85 |
| **Auto-2-person** | 1:1 meeting with one un-named cluster | 0.95 |
| **LLM attribution** | Cluster transcript + attendee list → Claude / Ollama | 0.62 – 0.78 |

## Two Important Gates

Before any of those signals fire, two filters narrow the candidate pool:

**1. RSVP gate.** Anyone who declined the calendar invite is excluded from candidates. If Dave declined, a voice can't be attributed to Dave, even if the fingerprint matches (a poisoned fingerprint from an earlier wrong attribution wouldn't fire here).

**2. Attendance gate.** Even when a voice fingerprint matches, if the matched name isn't a calendar attendee for *this* meeting, the match is dropped. Worst case: you miss attributing a real drop-in (rare). Best case: you avoid hallucinating someone into a meeting they weren't in.

---

## Voice Profiles

A **voice profile** is a 40-dimensional mel-spectrum embedding averaged across every audio sample where a person was confirmed to be speaking. It's stored once per Person (see [People Directory](./people-directory.md)).

Profiles are built progressively:

- Manual rename → high-trust sample (α 0.40 EMA, increments `manualSampleCount`)
- Voice match in a later meeting → high-trust sample (α 0.25)
- LLM attribution → low-trust sample (α 0.10, increments `llmSampleCount`)

A profile that has *only ever* been confirmed by LLM is matched at a stricter cosine threshold (0.87 vs 0.82) — protects against drift onto similar-sounding voices.

### Per-utterance sample bank

In addition to the EMA centroid, every voice sample is stored as a row in `voiceSample` with its meeting ID and timestamp range. This enables future provenance / rollback features (e.g., "this profile drifted because of a bad attribution in meeting X — let me undo it").

---

## Confidence Indicator

Every attributed speaker label carries a confidence score. The transcript view shows a small **amber dot** next to labels with confidence below 0.60 — these are the labels worth verifying.

Hover the label to see the exact percentage. Click the label to open a rename menu with the meeting's attendees pre-listed.

You won't see a dot for:
- Manual renames (1.0)
- Voice-matched clusters (≥ 0.82 by definition)
- Claude-haiku LLM attributions (0.72) and escalated Sonnet (0.78)
- 2-person auto-assigned clusters (0.95)

You **will** see a dot for:
- Single-vote vocative matches (0.55)
- Local-Ollama LLM attributions (0.62) — by design, Ollama is lower trust than Claude
- Anything else explicitly marked low-confidence

---

## Cluster Count Hint

The diarizer (SpeakerKit / pyannote) does better work when it knows how many distinct voices to expect. Meeting Manager passes:

```
max(2, accepted attendee count + 1)
```

The `+1` is you on the microphone stream. Capping at a minimum of 2 covers solo / monologue meetings where the diarizer would otherwise refuse to split.

If RSVP data is missing (some Outlook calendars), this falls back to nil — clustering heuristics only.

---

## Second-Pass Attribution

When the post-meeting transcript cleanup task completes, Meeting Manager checks whether any clusters are still labelled "Speaker N". If so, a `retryAttribution` task runs against the *full* transcript (not just the first 20 turns the initial LLM pass uses).

The retry **only fills empty clusters** — it never overwrites an existing mapping, even if the new confidence would be higher. Silent name swaps are worse than slightly stale labels.

The retry runs once per meeting per app session. Manual cleanup re-runs reset the gate.

---

## Person Directory and Domain Disambiguation

All voice profiles attach to stable `Person` UUIDs, not name strings. So `dave@acme.com`, `Dave Smith`, and `dave.smith@acme.com` resolve to one person and one fingerprint that compounds across all three formats.

But two `Dave`s at different orgs stay separate. The domain disambiguation step:

- Extracts email domain from the candidate's alias list
- When a new candidate name has a different domain than an existing person with the same first-name key, a new Person record is created instead of merging

You'll see an org chip (e.g., **Acme**) next to each person in the People list.

See [People Directory](./people-directory.md) for management UI.

---

## What to Do When It Gets a Name Wrong

1. **Click the wrong label** in the Full Transcript view.
2. Pick the right name from the menu, or click **Add custom...**.
3. Every transcript row for that cluster updates immediately.
4. The voice fingerprint learns from the rename — the next meeting recognises the voice automatically.
5. If the meeting is part of a recurring series, the rename is remembered for future meetings in that series.

You can also manage identities directly in the **People** tab. Renaming a person there updates the canonical name everywhere.

---

## What Still Doesn't Work Well

- **Two people with very similar voices** (same gender, similar accent) can fool the 40-dim mel-spectrum fingerprint. Manual rename + the stricter 0.87 threshold mitigates drift, but doesn't fix initial confusion.
- **Brand-new attendees with no prior voice profile** fall back to LLM attribution against the first 20 turns of their cluster, which can be wrong. After one manual rename, future meetings work.
- **Heavy crosstalk / overlapping speech** breaks diarization at the boundary — clusters get fragmented. Less common with high-quality conferencing audio.

Active investigations: SpeakerKit native embeddings (higher discrimination), behavioral priors for recurring meetings (speaking-order memory), indirect-reference vocative ("what does Dave think?").

---

## Diagnostics

- **Settings → Voices** lists every voice profile with sample count and last-updated date. You can delete individual profiles or rebuild from history.
- **People tab → \<person\> → Manage Identity → Voice fingerprint** shows the same per-person.
- **Activity tab** shows the speaker-related background tasks (diarization, retry attribution).

If a meeting's speaker labels are persistently wrong, the most reliable fix is: open the transcript, manually rename one or two speaker labels for that person, and the next meeting will get them right automatically.

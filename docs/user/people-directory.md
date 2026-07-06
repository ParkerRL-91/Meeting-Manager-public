# People Directory

The **People** tab is the front door to Meeting Manager's identity system — every person you've met with, their meeting history, and the controls for fixing identity issues.

## What's a Person?

A `Person` is a stable identity record:

- **Canonical name** — the display name (e.g., "Dave Smith")
- **Aliases** — every other name/email format that resolves to the same person (e.g., `dave@acme.com`, `dave.smith@acme.com`, `Dave`)
- **Voice fingerprint** — a single per-person embedding that survives format changes
- **Domain** — the email domain (used for org chip + disambiguation)

People are auto-created from your meeting history on first launch and incrementally as new attendees appear.

---

## The People List

The left pane of the People tab shows every Person, sorted by canonical name. Each row shows:

- Initials avatar
- Canonical name
- **Org chip** (Acme, Globex, etc.) — derived from email domain
- Number of meetings + last meeting date
- A waveform icon when a voice fingerprint is stored

Click a person to open their detail pane.

---

## Detail Pane

The right pane has three sections:

### 1. Header

- 72-pt initials avatar
- Canonical name
- Org + domain (if known)
- Meeting count, last meeting, voice fingerprint badge

### 2. Manage Identity (expandable)

Click **Manage Identity** to expand:

- **Display name** — the canonical name. Click the pencil to rename. The new name becomes the primary alias.
- **Known aliases** — every other format (emails, alternate display names). Add new ones via the field at the bottom; remove with the minus icon. The canonical name itself is always present and can't be removed (it's the primary).
- **Voice fingerprint** — sample count, last updated, delete button. Deleting forces re-learning from future meetings.
- **Merge duplicate** — pick another Person record to merge this one into. All aliases and the voice profile transfer to the target; this record is deleted. Confirmation required.

### 3. Meeting History

Every meeting where this person appeared as a participant. Click any row to open the meeting.

---

## How People are Built

### Auto-bootstrap on first launch

After v3.9.0 install, the app scans every meeting's participant list, groups by canonical first-name key (with email-domain disambiguation), and creates Person records.

Example: if your past meetings have `Dave Smith`, `dave@acme.com`, and `dave.smith@acme.com` all attending, you get **one** Person with three aliases.

### Incremental from new meetings

Every new calendar event's attendees flow through the same `findOrCreate` logic. A new format for an existing person is added as an alias; a new person creates a new record.

### Domain disambiguation

If a new candidate `dave@acme.com` arrives but a Person already exists for `dave@acme.com`, the domains differ → a *new* Person record is created (not a merge). Same first name, different organisations, separate identities.

---

## Contacts Import (Opt-in)

A **person.crop.circle.badge.plus** icon in the People tab header imports names + emails from your macOS Contacts.

What's imported:
- Display name (`givenName + familyName`)
- Email addresses

What's **not** imported:
- Phone numbers
- Photos
- Addresses
- Notes / custom fields

The first time you tap the import button you'll be prompted for Contacts access. Subsequent taps re-sync (idempotent — existing Persons get new aliases merged, no duplicates).

Disable any time: revoke Contacts access in System Settings → Privacy & Security → Contacts. Existing imported records stay; new imports stop.

---

## When to Manually Edit

The most common manual action is fixing a misidentified person:

- **A speaker is consistently labelled the wrong name in transcripts.** Rename the speaker once in any meeting transcript. The voice profile retrains immediately, the next meeting gets it right.
- **Two Person records are actually the same human** (e.g., domain disambiguation was wrong because they switched companies). Open one, scroll to **Merge duplicate**, pick the other, confirm. The aliases and voice profile combine into the target.
- **A Person record collected aliases from multiple actual humans** (rare; usually because two same-first-name people without distinguishing emails). Remove the wrong aliases via the minus icon.

---

## What Happens to Voice Profiles When You Merge

The source's voice profile rows are re-pointed to the target Person ID. The target's existing fingerprint stays as-is — merges don't blend embeddings, because that would be modelling the assumption "two profiles for the same person have the same true voice," which isn't always true (different recording conditions, etc.).

If you want to rebuild the merged person's fingerprint from clean samples, delete the existing voice fingerprint from their detail pane and let it re-learn from the next few meetings.

---

## Privacy

- All Person data is local. Aliases, voice fingerprints, and meeting associations never leave your Mac unless you actively send them to Claude as part of a summary or chat prompt.
- Contacts import is opt-in and reads only the name and email fields you'd see on a paper rolodex.
- Deleting a Person record deletes the voice fingerprint and unlinks all sample-bank rows.

See [Privacy](./privacy.md) for the full data flow.

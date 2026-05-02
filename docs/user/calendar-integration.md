# Calendar Integration

Meeting Manager can read events from Google Calendar, Apple Calendar (which also covers iCloud and Outlook for Mac), or both at once.

## Pick a Source

**Settings → Calendar → Source**

- **Google Calendar** — OAuth-based; needs a Google sign-in. Pulls every calendar your Google account can see, then you choose which to include.
- **Apple Calendar** — uses macOS EventKit; needs Calendar permission. Reads whatever Calendar.app reads (iCloud, Outlook on Mac via Microsoft's local sync, Google via macOS, etc.).
- **Both** — pulls from both providers. Events are namespaced internally so duplicates from the same calendar across providers don't collide.
- **None** — turns off calendar integration. You can still record ad-hoc meetings.

---

## Google Calendar

### Connect

1. Settings → Calendar → **Connect Google Calendar**
2. A browser window opens for OAuth.
3. Approve the read-only calendar scope.
4. The app receives a token and starts syncing.

The token is stored in your macOS Keychain. To disconnect: Settings → Calendar → **Disconnect**.

### Multi-calendar selection

After connecting, you'll see a list of every calendar attached to your Google account. Toggle which to include. Unchecked calendars are skipped at sync time and never persisted.

### What's pulled

For each event, Meeting Manager reads:

- Title, start, end, all-day flag
- Description (used for prep context)
- Attendee names + emails + RSVP status (`accepted` / `declined` / `tentative` / `needsAction`)
- The conference URL (Meet link, Zoom link via `conferenceData`, Teams link)

**RSVP gate:** declined attendees are excluded from speaker attribution. If Dave declined and a voice that sounds like Dave appears in the recording, Meeting Manager will not attribute it to Dave just because the calendar says he was invited.

### Sync cadence

Default is every 15 minutes (Settings → Calendar → Sync interval). Manual sync is available via the refresh button. The app also syncs on launch.

---

## Apple Calendar

### Grant access

Settings → Calendar → **Source: Apple Calendar** → grant calendar permission when macOS prompts.

If the permission prompt doesn't appear or you accidentally denied it: System Settings → Privacy & Security → Calendars → toggle Meeting Manager.

### Multi-calendar selection

Same as Google — pick which iCloud / On My Mac / Outlook calendars to include. Unchecked calendars are skipped at sync time.

### Reliability features (v3.8.0+)

Apple Calendar on macOS has historically been finicky. Meeting Manager guards against six known failure modes:

- **Store rebuild on grant** — `EKEventStore` is recreated when access transitions to authorized, so a store created before TCC resolved doesn't keep returning empty calendar lists.
- **External-grant detection** — listens for `EKEventStoreChanged` and `NSApplication.didBecomeActive` so grants applied via System Settings (without quitting the app) take effect immediately.
- **Sticky auth state** — once `.authorized` is observed, a transient `.notDetermined` from EventKit's static query is treated as a stall and ignored for 5 seconds (avoids UI bouncing).
- **Verify-before-read** — every read call validates the store is healthy and rebuilds if it's stuck.
- **Source-change restart** — flipping the calendar source in Settings restarts the sync loop without an app relaunch.

If Apple Calendar still won't sync after granting permission, **Settings → Troubleshooting → Reset App Permissions** wipes the TCC cache for Meeting Manager and lets you grant fresh.

---

## Outlook on Mac

Outlook for Mac publishes its events into the macOS calendar store. **Use Apple Calendar as your source** and Outlook events show up automatically.

Outlook attendee RSVP is exposed through EventKit; the RSVP gate works for Outlook events too.

---

## What Calendar Data is Used For

Beyond just listing meetings, calendar data drives:

- **Speaker attribution candidates** — only invited (and not declined) attendees are considered when mapping voices to names
- **Diarization speaker-count hint** — `accepted attendees + 1` (you on the mic) tells the diarizer how many voices to expect, preventing over-segmentation
- **Pre-meeting brief** — attendees, agenda from description, and related past meetings
- **Person directory** — every attendee becomes (or merges into) a Person record over time

---

## Privacy

- Calendar data is read-only. The app never writes events back.
- Tokens are stored in macOS Keychain.
- Meeting bodies / attendee lists never leave your Mac unless you explicitly enable an AI feature that requires sending the relevant slice to Claude (summarization, follow-up email, etc.).

See [Privacy](./privacy.md) for details on what goes where.

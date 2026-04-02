# Database Schema

Meeting Manager uses SQLite via GRDB. The database lives at:
```
~/Library/Application Support/MeetingManager/db.sqlite
```

---

## Tables

### `meeting`

| Column | Type | Notes |
|--------|------|-------|
| `id` | TEXT PK | UUID string |
| `title` | TEXT | Meeting name |
| `startDate` | DATETIME | Actual start (nil until recording begins) |
| `endDate` | DATETIME | Actual end |
| `scheduledStartDate` | DATETIME | From calendar event |
| `scheduledEndDate` | DATETIME | From calendar event |
| `status` | TEXT | See status values below |
| `calendarEventId` | TEXT | Google Calendar event ID (nullable) |
| `audioFilePath` | TEXT | Path to recorded audio file (nullable) |
| `participants` | TEXT | JSON-encoded `[String]` |
| `createdAt` | DATETIME | |
| `updatedAt` | DATETIME | |

**Status values:** `scheduled`, `notified`, `recording`, `transcribing`, `summarizing`, `complete`, `cancelled`, `archived`

`audioFilePath != nil` means a recording exists — used to show "Recorded" vs "Completed" badges in the sidebar.

---

### `transcript`

| Column | Type | Notes |
|--------|------|-------|
| `id` | INTEGER PK AUTOINCREMENT | |
| `meetingId` | TEXT FK → meeting.id | CASCADE DELETE |
| `speakerLabel` | TEXT | Speaker identifier (nullable) |
| `text` | TEXT | Transcribed speech segment |
| `startTime` | DOUBLE | Seconds from recording start |
| `endTime` | DOUBLE | Seconds from recording start |
| `confidence` | DOUBLE | WhisperKit confidence score (0–1) |
| `createdAt` | DATETIME | |

Index: `idx_transcript_meeting` on `(meetingId, startTime)`

---

### `meetingSummary`

| Column | Type | Notes |
|--------|------|-------|
| `id` | INTEGER PK AUTOINCREMENT | |
| `meetingId` | TEXT FK → meeting.id | CASCADE DELETE |
| `summary` | TEXT | Full summary text |
| `actionItems` | TEXT | JSON-encoded action items |
| `keyDecisions` | TEXT | JSON-encoded decisions |
| `topics` | TEXT | JSON-encoded topics |
| `model` | TEXT | Model used (e.g., `claude-sonnet-4-6`, `ollama/llama3.2:3b`) |
| `createdAt` | DATETIME | |

Multiple summaries can exist per meeting (regeneration history). `latestSummary(meetingId:)` returns the most recent.

---

### `actionItem`

| Column | Type | Notes |
|--------|------|-------|
| `id` | INTEGER PK AUTOINCREMENT | |
| `meetingId` | TEXT FK → meeting.id | |
| `summaryId` | INTEGER FK → meetingSummary.id | |
| `text` | TEXT | Action item description |
| `owner` | TEXT | Assigned person (nullable) |
| `dueDate` | DATETIME | (nullable) |
| `isComplete` | BOOLEAN | Default false |
| `createdAt` | DATETIME | |

---

### `appSettings`

Single-row table — always exactly one row.

| Column | Type | Default |
|--------|------|---------|
| `id` | INTEGER PK | 1 |
| `claudeApiKey` | TEXT | '' |
| `claudeModel` | TEXT | 'claude-sonnet-4-6' |
| `whisperModel` | TEXT | 'base' |
| `autoRecord` | BOOLEAN | false |
| `autoInvite` | BOOLEAN | false |
| `notificationLeadTimeMinutes` | INTEGER | 2 |
| `theme` | TEXT | 'system' |
| `systemPrompt` | TEXT | (default prompt) |
| `launchAtLogin` | BOOLEAN | false |
| `useLocalLLM` | BOOLEAN | false |
| `ollamaModel` | TEXT | 'llama3.2:3b' |

---

## Migrations

All schema changes are additive — never drop, rename, or alter columns. Add a new migration in `Migrations.swift`:

```swift
migrator.registerMigration("v10-new-feature") { db in
    try db.alter(table: "meeting") { t in
        t.add(column: "myNewColumn", .text).defaults(to: "")
    }
}
```

Current version: **v12** (`v12-performance-indexes`)

Migration history:
- v1: initial schema
- v2–v8: incremental feature additions
- v9: Ollama settings columns (`useLocalLLM`, `ollamaModel`)
- v10: onboarding and audio device settings
- v11: audioFilePaths array, isAllDay flag on meeting table
- v12: performance indexes on foreign keys and common query patterns

### v12 Indexes

| Index | Columns | Purpose |
|-------|---------|---------|
| `idx_meetingSummary_meeting` | `meetingSummary(meetingId)` | Fast summary lookups by meeting |
| `idx_chatMessage_meeting` | `chatMessage(meetingId)` | Fast chat history loads |
| `idx_meetingNote_meeting` | `meetingNote(meetingId)` | Fast note lookups |
| `idx_meeting_calendarEventId` | `meeting(calendarEventId)` | Calendar sync upsert matching |
| `idx_meeting_status` | `meeting(status)` | Filtered meeting lists |
| `idx_actionItem_meeting_extracted` | `actionItem(meetingId, extractedAt)` | Action item queries with sort |

---

## Useful Queries

```bash
# Open the database
sqlite3 ~/Library/Application\ Support/MeetingManager/db.sqlite

# List recent meetings
SELECT title, status, startDate FROM meeting ORDER BY startDate DESC LIMIT 20;

# Count transcript segments per meeting
SELECT m.title, COUNT(t.id) as segments
FROM meeting m LEFT JOIN transcript t ON t.meetingId = m.id
GROUP BY m.id ORDER BY m.startDate DESC LIMIT 10;

# Check current settings
SELECT useLocalLLM, ollamaModel, claudeModel FROM appSettings;
```

# Knowledge Base

Optional folder index that gives Meeting Manager context outside of meeting transcripts. Use it for company docs, project specs, glossaries — anything you'd want the AI to know when summarising or chatting.

## What it is

Point Meeting Manager at a folder. The app:

1. Recursively walks the folder
2. Reads `.md`, `.txt`, `.html`, and `.docx` files
3. Splits each into chunks (Markdown sections / paragraphs)
4. Indexes the chunks in a local SQLite FTS5 table
5. Watches the folder via FSEvents so external edits update the index

Chunks are then retrieved at meeting-prep time and during Ask Anything chat.

---

## Setup

**Settings → Knowledge Base → Choose Folder**

Pick any folder. Common patterns:

- A clone of your team's wiki (Notion export, Bear export, Obsidian vault)
- An iCloud Drive or Dropbox folder of internal docs
- A repo's `docs/` directory if you're using markdown-based docs

After selection, the app:

1. Indexes everything in the folder (foreground task; ~1 sec per 100 files)
2. Starts watching for changes
3. Shows the file count + last-indexed time in Settings

---

## What's Indexed

| Format | Chunking |
|---|---|
| `.md` / Markdown | One chunk per heading section, max ~1000 chars |
| `.txt` | Paragraphs, max ~1000 chars |
| `.html` | Stripped to plain text, then paragraph chunks |
| `.docx` | Body text extracted, paragraph chunks |

Other formats (PDF, DOC, XLSX, images) are skipped.

Files larger than 5MB are skipped to keep the index fast.

---

## How it's Used

### Pre-meeting brief
When generating a brief, the app retrieves the top-K relevant chunks based on attendee names + meeting title + agenda keywords. Those chunks are inlined into the brief prompt.

### Ask Anything chat
The chat pane is a global, multi-meeting Q&A surface. KB chunks are retrieved alongside meeting summaries to answer questions like:
- "What's our policy on customer refunds?"
- "Who's on the platform team and what are they working on this quarter?"

Both are RAG-style — retrieved chunks are added to the prompt context for that one call. Nothing about the KB is sent to the AI provider for queries that don't need it.

### Recipes / summary prompts
You can include `{{kbContext}}` in any prompt template (e.g., a summary recipe) to retrieve relevant chunks for that meeting.

---

## Write-back (Optional)

**Settings → Knowledge Base → Write meeting notes back to KB folder**

When enabled, every completed meeting writes a Markdown file to:

```
<KB folder>/Meeting Notes/YYYY/MM-Month/DD/Title.md
```

The file contains:

- Frontmatter (date, attendees, meeting ID)
- The summary
- Notes
- Action items

Useful when you want your meeting notes to live alongside your team's docs and feed back into the index for future retrieval.

The write-back is idempotent — re-running on the same meeting overwrites the file. No two-way sync; the canonical copy is in Meeting Manager.

---

## Privacy

- The KB index is a local SQLite database. Nothing about it leaves your Mac unless an AI call retrieves chunks and includes them in a prompt.
- The watcher reads file content on disk — files outside the chosen folder are never read.
- Write-back creates new files only inside the KB folder; nothing outside is touched.

---

## Troubleshooting

- **Index appears empty after pointing at a folder.** Check Settings → Knowledge Base → file count. If it's 0, the folder probably contains only unsupported formats. Add a `.md` test file and re-index.
- **External edits aren't picked up.** FSEvents needs the folder to be on a local volume. iCloud-synced folders work; SMB/NFS shares don't reliably emit events. Use the **Re-index** button manually.
- **Re-index button is greyed out.** A re-index is already running — check **Activity**.
- **Performance issues.** Very large folders (>10k files) make Ask Anything slower. Move the largest unrelated files out of the indexed folder.

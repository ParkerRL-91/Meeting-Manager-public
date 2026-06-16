import Foundation
import GRDB

enum Migrations {
    static func registerAll(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v1") { db in
            // Meetings
            try db.create(table: "meeting") { t in
                t.column("id", .text).primaryKey()
                t.column("title", .text).notNull()
                t.column("startDate", .datetime)
                t.column("endDate", .datetime)
                t.column("scheduledStartDate", .datetime)
                t.column("scheduledEndDate", .datetime)
                t.column("status", .text).notNull().defaults(to: "scheduled")
                t.column("calendarEventId", .text)
                t.column("audioFilePath", .text)
                t.column("createdAt", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
                t.column("updatedAt", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
            }

            // Transcript segments
            try db.create(table: "transcript") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("meetingId", .text).notNull()
                    .references("meeting", onDelete: .cascade)
                t.column("speakerLabel", .text)
                t.column("text", .text).notNull()
                t.column("startTime", .double).notNull()
                t.column("endTime", .double).notNull()
                t.column("confidence", .double)
                t.column("createdAt", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
            }

            try db.create(
                index: "idx_transcript_meeting",
                on: "transcript",
                columns: ["meetingId", "startTime"]
            )

            // Meeting notes
            try db.create(table: "meetingNote") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("meetingId", .text).notNull()
                    .references("meeting", onDelete: .cascade)
                t.column("content", .text).notNull()
                t.column("createdAt", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
            }

            // Meeting summaries
            try db.create(table: "meetingSummary") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("meetingId", .text).notNull()
                    .references("meeting", onDelete: .cascade)
                t.column("promptUsed", .text).notNull()
                t.column("summaryText", .text).notNull()
                t.column("modelUsed", .text)
                t.column("generatedAt", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
            }

            // App settings (singleton row)
            try db.create(table: "appSettings") { t in
                t.column("id", .integer).primaryKey().check { $0 == 1 }
                t.column("whisperModel", .text).notNull().defaults(to: "openai_whisper-large-v3")
                t.column("summaryPromptTemplate", .text).notNull()
                t.column("claudeModel", .text).notNull().defaults(to: "claude-sonnet-4-20250514")
                t.column("calendarSyncIntervalMinutes", .integer).notNull().defaults(to: 15)
                t.column("notificationLeadTimeMinutes", .integer).notNull().defaults(to: 2)
                t.column("launchAtLogin", .boolean).notNull().defaults(to: false)
                t.column("theme", .text).notNull().defaults(to: "dark")
            }

            // Insert default settings. Uses OR REPLACE so the migration is idempotent
            // — if a prior migration attempt populated the row before crashing, we
            // won't now fail the CHECK(id==1) constraint trying to insert a duplicate.
            try db.execute(sql: """
                INSERT OR REPLACE INTO appSettings (id, summaryPromptTemplate)
                VALUES (1, ?)
                """, arguments: [AppSettings.default.summaryPromptTemplate])
        }

        migrator.registerMigration("v2") { db in
            try db.create(table: "chatMessage") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("meetingId", .text).notNull()
                    .references("meeting", onDelete: .cascade)
                t.column("role", .text).notNull()
                t.column("content", .text).notNull()
                t.column("createdAt", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
            }
        }

        migrator.registerMigration("add-isEdited") { db in
            try db.alter(table: "meetingSummary") { t in
                t.add(column: "isEdited", .boolean).notNull().defaults(to: false)
            }
        }

        migrator.registerMigration("v3") { db in
            try db.create(table: "actionItem") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("meetingId", .text).notNull()
                    .references("meeting", onDelete: .cascade)
                t.column("title", .text).notNull()
                t.column("assignee", .text)
                t.column("dueDate", .datetime)
                t.column("isCompleted", .boolean).notNull().defaults(to: false)
                t.column("extractedAt", .datetime).notNull()
            }

            try db.create(
                index: "idx_actionItem_meeting",
                on: "actionItem",
                columns: ["meetingId"]
            )
        }
        migrator.registerMigration("v4") { db in
            // Recipes table
            try db.create(table: "recipe") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("description", .text).notNull()
                t.column("promptTemplate", .text).notNull()
                t.column("category", .text).notNull()
                t.column("isBuiltIn", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
            }

            // Recipe results table
            try db.create(table: "recipeResult") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("meetingId", .text).notNull()
                    .references("meeting", onDelete: .cascade)
                t.column("recipeId", .text).notNull()
                    .references("recipe", onDelete: .cascade)
                t.column("outputText", .text).notNull()
                t.column("generatedAt", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
            }

            try db.create(
                index: "idx_recipeResult_meeting",
                on: "recipeResult",
                columns: ["meetingId"]
            )

            try db.create(
                index: "idx_recipeResult_recipe",
                on: "recipeResult",
                columns: ["recipeId"]
            )

            // Seed built-in recipes
            let builtInRecipes: [(id: String, name: String, description: String, promptTemplate: String, category: String)] = [
                (
                    id: "builtin-follow-up-email",
                    name: "Follow-Up Email",
                    description: "Draft a professional follow-up email summarizing decisions and next steps",
                    promptTemplate: """
                    Based on the following meeting, draft a professional follow-up email to send to all attendees.

                    Meeting: {{meetingTitle}}
                    Date: {{date}}

                    ## Transcript:
                    {{transcript}}

                    ## Notes:
                    {{notes}}

                    Please write a concise, professional email that:
                    1. Thanks attendees for their time
                    2. Summarizes the key decisions made
                    3. Lists next steps and action items with owners
                    4. Notes any upcoming deadlines or follow-up meetings
                    5. Ends with a professional closing

                    Format the email with a subject line, greeting, body, and sign-off.
                    """,
                    category: "email"
                ),
                (
                    id: "builtin-action-items",
                    name: "Action Items List",
                    description: "Extract all action items with owners and deadlines",
                    promptTemplate: """
                    Analyze the following meeting and extract all action items.

                    Meeting: {{meetingTitle}}
                    Date: {{date}}

                    ## Transcript:
                    {{transcript}}

                    ## Notes:
                    {{notes}}

                    For each action item, provide:
                    - **Task**: Clear description of what needs to be done
                    - **Owner**: Who is responsible (use names from the transcript, or "Unassigned")
                    - **Deadline**: Any mentioned deadline, or "TBD"
                    - **Priority**: High / Medium / Low (inferred from context)

                    Format as a numbered list. If no action items were identified, state that clearly.
                    """,
                    category: "summary"
                ),
                (
                    id: "builtin-decisions-summary",
                    name: "Decisions Summary",
                    description: "List all decisions made with context",
                    promptTemplate: """
                    Review the following meeting and identify all decisions that were made.

                    Meeting: {{meetingTitle}}
                    Date: {{date}}

                    ## Transcript:
                    {{transcript}}

                    ## Notes:
                    {{notes}}

                    For each decision, provide:
                    - **Decision**: What was decided
                    - **Context**: Brief background on why this decision was needed
                    - **Alternatives Considered**: Any other options that were discussed
                    - **Impact**: Who or what is affected

                    Format as a numbered list. If no clear decisions were made, summarize the key discussion points that are pending resolution.
                    """,
                    category: "summary"
                ),
                (
                    id: "builtin-meeting-brief",
                    name: "Meeting Brief",
                    description: "One-paragraph executive summary",
                    promptTemplate: """
                    Write a concise executive summary of the following meeting in a single paragraph (3-5 sentences).

                    Meeting: {{meetingTitle}}
                    Date: {{date}}

                    ## Transcript:
                    {{transcript}}

                    ## Notes:
                    {{notes}}

                    The summary should capture the purpose of the meeting, the most important outcomes, and any critical next steps. Write in a professional tone suitable for sharing with senior leadership.
                    """,
                    category: "summary"
                ),
                (
                    id: "builtin-prd-brainstorm",
                    name: "PRD from Brainstorm",
                    description: "Generate a product requirements document from a brainstorming session",
                    promptTemplate: """
                    Based on the following brainstorming meeting, generate a Product Requirements Document (PRD).

                    Meeting: {{meetingTitle}}
                    Date: {{date}}

                    ## Transcript:
                    {{transcript}}

                    ## Notes:
                    {{notes}}

                    Structure the PRD with the following sections:
                    1. **Overview** - Brief description of the product/feature
                    2. **Problem Statement** - What problem this solves
                    3. **Goals & Success Metrics** - What success looks like
                    4. **User Stories** - Key user stories in "As a [user], I want [goal] so that [benefit]" format
                    5. **Requirements** - Functional and non-functional requirements
                    6. **Out of Scope** - What is explicitly not included
                    7. **Open Questions** - Unresolved items needing further discussion

                    Infer details from the discussion. Mark assumptions clearly.
                    """,
                    category: "planning"
                ),
                (
                    id: "builtin-coaching-feedback",
                    name: "Coaching Feedback",
                    description: "Provide coaching feedback based on discussion dynamics",
                    promptTemplate: """
                    Analyze the following meeting discussion and provide constructive coaching feedback.

                    Meeting: {{meetingTitle}}
                    Date: {{date}}

                    ## Transcript:
                    {{transcript}}

                    ## Notes:
                    {{notes}}

                    Please provide feedback on:
                    1. **Participation Balance** - Were all participants engaged? Did anyone dominate or stay silent?
                    2. **Communication Clarity** - Were ideas communicated clearly? Any confusion or misunderstandings?
                    3. **Meeting Effectiveness** - Did the meeting stay on track? Was time used efficiently?
                    4. **Decision-Making Process** - How were decisions reached? Was there healthy debate?
                    5. **Suggestions for Improvement** - Specific, actionable tips for better meetings

                    Be constructive and specific. Reference particular moments from the transcript where appropriate.
                    """,
                    category: "feedback"
                ),
            ]

            for recipe in builtInRecipes {
                try db.execute(
                    sql: """
                        INSERT INTO recipe (id, name, description, promptTemplate, category, isBuiltIn, createdAt)
                        VALUES (?, ?, ?, ?, ?, 1, CURRENT_TIMESTAMP)
                        """,
                    arguments: [recipe.id, recipe.name, recipe.description, recipe.promptTemplate, recipe.category]
                )
            }
        }

        migrator.registerMigration("v5-ai-enabled") { db in
            try db.alter(table: "appSettings") { t in
                t.add(column: "aiEnabled", .boolean).notNull().defaults(to: true)
            }
        }

        migrator.registerMigration("v6-auto-record-invite") { db in
            try db.alter(table: "appSettings") { t in
                t.add(column: "autoRecord", .boolean).notNull().defaults(to: false)
                t.add(column: "autoInvite", .boolean).notNull().defaults(to: true)
            }
        }

        migrator.registerMigration("v7-meeting-participants") { db in
            try db.alter(table: "meeting") { t in
                t.add(column: "participants", .text)
            }
        }

        migrator.registerMigration("v8-calendar-selection") { db in
            try db.alter(table: "appSettings") { t in
                t.add(column: "selectedCalendarId", .text)
            }
        }

        migrator.registerMigration("v9-local-llm") { db in
            try db.alter(table: "appSettings") { t in
                t.add(column: "useLocalLLM", .boolean).notNull().defaults(to: false)
                t.add(column: "ollamaModel", .text).notNull().defaults(to: "llama3.2:3b")
            }
        }

        migrator.registerMigration("v10-auto-generate-summary") { db in
            try db.alter(table: "appSettings") { t in
                t.add(column: "autoGenerateSummary", .boolean).notNull().defaults(to: false)
                t.add(column: "defaultRecipeId", .text)
            }
        }

        migrator.registerMigration("v11-reopen") { db in
            // Add audioFilePaths (JSON-encoded array) and isAllDay flag.
            try db.alter(table: "meeting") { t in
                t.add(column: "audioFilePaths", .text).notNull().defaults(to: "[]")
                t.add(column: "isAllDay", .boolean).notNull().defaults(to: false)
            }
            // Migrate existing single audioFilePath value into the array column.
            let rows = try Row.fetchAll(db, sql: "SELECT id, audioFilePath FROM meeting WHERE audioFilePath IS NOT NULL")
            for row in rows {
                let id: String = row["id"]
                let path: String = row["audioFilePath"]
                if let jsonData = try? JSONEncoder().encode([path]),
                   let jsonString = String(data: jsonData, encoding: .utf8) {
                    try db.execute(sql: "UPDATE meeting SET audioFilePaths = ? WHERE id = ?",
                                   arguments: [jsonString, id])
                }
            }
        }

        migrator.registerMigration("v12-performance-indexes") { db in
            try db.create(index: "idx_meetingSummary_meeting", on: "meetingSummary", columns: ["meetingId"])
            try db.create(index: "idx_chatMessage_meeting", on: "chatMessage", columns: ["meetingId"])
            try db.create(index: "idx_meetingNote_meeting", on: "meetingNote", columns: ["meetingId"])
            try db.create(index: "idx_meeting_calendarEventId", on: "meeting", columns: ["calendarEventId"])
            try db.create(index: "idx_meeting_status", on: "meeting", columns: ["status"])
            try db.create(index: "idx_actionItem_meeting_extracted", on: "actionItem", columns: ["meetingId", "extractedAt"])
        }

        migrator.registerMigration("v13-transcript-fts") { db in
            try db.create(virtualTable: "transcript_fts", using: FTS5()) { t in
                t.synchronize(withTable: "transcript")
                t.column("text")
                t.column("meetingId").notIndexed()
            }
        }

        migrator.registerMigration("v14-task-queue") { db in
            try db.create(table: "taskQueue") { t in
                t.column("id", .text).primaryKey()
                t.column("type", .text).notNull()
                t.column("meetingId", .text).notNull()
                    .references("meeting", onDelete: .cascade)
                t.column("status", .text).notNull().defaults(to: "pending")
                t.column("priority", .integer).notNull().defaults(to: 5)
                t.column("retryCount", .integer).notNull().defaults(to: 0)
                t.column("maxRetries", .integer).notNull().defaults(to: 3)
                t.column("error", .text)
                t.column("createdAt", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
                t.column("startedAt", .datetime)
                t.column("completedAt", .datetime)
                t.column("metadata", .text)
            }
            // Index for the processor: fetch next pending task by priority
            try db.create(
                index: "idx_taskQueue_status_priority",
                on: "taskQueue",
                columns: ["status", "priority", "createdAt"]
            )
            // Index for looking up tasks by meeting
            try db.create(
                index: "idx_taskQueue_meetingId",
                on: "taskQueue",
                columns: ["meetingId"]
            )
        }

        migrator.registerMigration("v15-context-json") { db in
            try db.alter(table: "meeting") { t in
                t.add(column: "contextJSON", .text)
            }
        }

        migrator.registerMigration("v16-meet-link") { db in
            try db.alter(table: "meeting") { t in
                t.add(column: "meetLink", .text)
            }
        }

        migrator.registerMigration("v17-whisper-turbo-default") { db in
            // Migrate existing users from large-v3 to the faster turbo variant.
            // Users who explicitly want large-v3 can switch back in Settings.
            try db.execute(sql: """
                UPDATE appSettings
                SET whisperModel = ?
                WHERE whisperModel IN ('openai_whisper-large-v3', 'large-v3')
                """,
                arguments: [WhisperModel.largev3turbo.rawValue]
            )
        }

        migrator.registerMigration("v18-meeting-templates") { db in
            // Create meetingTemplate table
            try db.create(table: "meetingTemplate") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("noteTemplate", .text).notNull().defaults(to: "")
                t.column("recipeId", .text)
                t.column("createdAt", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
            }

            // Add templateId to meeting table
            try db.alter(table: "meeting") { t in
                t.add(column: "templateId", .text)
            }

            // Seed built-in starter templates
            let oneOnOneNote = "Wins this week:\n- \n\nBlockers / needs help:\n- \n\nAction items:\n- \n\nCareer growth / feedback:\n- "
            let standupNote = "Yesterday:\n- \n\nToday:\n- \n\nBlockers:\n- "
            let planningNote = "Agenda:\n- \n\nKey decisions needed:\n- \n\nAction items:\n- \n\nParking lot:\n- "

            let templates: [(id: String, name: String, noteTemplate: String, recipeId: String?)] = [
                (
                    id: "builtin-template-one-on-one",
                    name: "1:1 Meeting",
                    noteTemplate: oneOnOneNote,
                    recipeId: "builtin-coaching-feedback"
                ),
                (
                    id: "builtin-template-standup",
                    name: "Standup",
                    noteTemplate: standupNote,
                    recipeId: nil
                ),
                (
                    id: "builtin-template-planning",
                    name: "Planning Session",
                    noteTemplate: planningNote,
                    recipeId: "builtin-action-items"
                ),
            ]

            for template in templates {
                try db.execute(
                    sql: """
                        INSERT INTO meetingTemplate (id, name, noteTemplate, recipeId, createdAt)
                        VALUES (?, ?, ?, ?, CURRENT_TIMESTAMP)
                        """,
                    arguments: [template.id, template.name, template.noteTemplate, template.recipeId]
                )
            }
        }

        migrator.registerMigration("v19-auto-follow-up-email") { db in
            try db.alter(table: "appSettings") { t in
                t.add(column: "autoFollowUpEmail", .boolean).notNull().defaults(to: false)
            }
        }

        migrator.registerMigration("v20-morning-brief") { db in
            try db.alter(table: "appSettings") { t in
                t.add(column: "morningBriefEnabled", .boolean).notNull().defaults(to: false)
                t.add(column: "morningBriefHour", .integer).notNull().defaults(to: 8)
                t.add(column: "morningBriefMinute", .integer).notNull().defaults(to: 30)
            }
        }

        // P2-DATA-03: transcript dedup by time, not text.
        // Existing code guarded against duplicate transcripts with a text-only filter
        // at the Swift layer, which both dropped legitimate repeats and missed dupes
        // that crossed batch boundaries. The database-level guarantee here is
        // (meetingId, startTime, endTime) — WhisperKit re-emitting the same segment
        // hits the unique constraint and INSERT OR IGNORE is a no-op at the call site.
        //
        // Existing rows may contain duplicates from before this migration; dedupe
        // them first by keeping the highest-confidence row per (meeting, start, end).
        migrator.registerMigration("v21-transcript-dedup-index") { db in
            // Drop lower-confidence duplicates, if any. Keeps the row with the
            // highest confidence in each time bucket; ties broken by rowid asc.
            try db.execute(sql: """
                DELETE FROM transcript
                WHERE rowid NOT IN (
                    SELECT rowid
                    FROM (
                        SELECT rowid,
                               ROW_NUMBER() OVER (
                                   PARTITION BY meetingId, startTime, endTime
                                   ORDER BY COALESCE(confidence, 0) DESC, rowid ASC
                               ) AS rn
                        FROM transcript
                    )
                    WHERE rn = 1
                );
                """)
            try db.create(
                index: "idx_transcript_unique_time",
                on: "transcript",
                columns: ["meetingId", "startTime", "endTime"],
                options: .unique
            )
        }

        // v22: rebuild the FTS index so search results match the transcript table.
        // transcript_fts uses FTS5 content-sync triggers added in v13; users who
        // had transcripts before v13 (or whose FTS triggers were skipped due to a
        // crash) may have a stale index. The 'rebuild' command forces a full resync.
        migrator.registerMigration("v22-fts-rebuild") { db in
            try db.execute(sql: "INSERT INTO transcript_fts(transcript_fts) VALUES('rebuild')")
        }

        // P3-T03: tighten the follow-up email recipe so the response begins
        // with a parseable "Subject:" line that EmailDraftResultView can split.
        migrator.registerMigration("v23-follow-up-email-prompt-v2") { db in
            let updatedPrompt = """
            Write a concise follow-up email based on this meeting.

            Format the response EXACTLY as:
            Subject: <one-line subject>

            <email body>

            Body guidance: thank the attendees, recap the 3 most important decisions or discussion points, list action items with owners (if known), and close with next steps. Keep it under 200 words. Professional but warm tone.

            Meeting: {{meetingTitle}}
            Date: {{date}}

            ## Transcript:
            {{transcript}}

            ## Notes:
            {{notes}}
            """
            try db.execute(
                sql: """
                    UPDATE recipe
                    SET promptTemplate = ?,
                        description = ?
                    WHERE id = ?
                    """,
                arguments: [
                    updatedPrompt,
                    "Draft a parseable follow-up email with a Subject line and concise body",
                    "builtin-follow-up-email"
                ]
            )
        }

        // v3.1 Layer 2: persist the per-meeting cluster -> attendee-name map
        // produced by SpeakerAttributionService. JSON-encoded dictionary,
        // e.g. {"Speaker 1": "Alex Chen"}. NULL when no attribution ran.
        migrator.registerMigration("v24-speaker-map") { db in
            try db.alter(table: "meeting") { t in
                t.add(column: "speakerMap", .text)
            }
        }

        // v3.1 Layer 3: remember user-confirmed speaker renames so future
        // meetings in the same series can pre-seed the LLM attribution prompt.
        // The unique (seriesKey, clusterId) index gives us upsert semantics —
        // SpeakerAliasRepository deletes any existing row before insert so
        // "rename Speaker 1 to Alex, then later to Sam" replaces, not stacks.
        migrator.registerMigration("v25-speaker-alias") { db in
            try db.create(table: "speakerAlias") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("seriesKey", .text).notNull()
                t.column("clusterId", .text).notNull()
                t.column("resolvedName", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(
                index: "idx_speakerAlias_unique_pair",
                on: "speakerAlias",
                columns: ["seriesKey", "clusterId"],
                options: .unique
            )
            try db.create(
                index: "idx_speakerAlias_seriesKey",
                on: "speakerAlias",
                columns: ["seriesKey"]
            )
        }

        // v3.3 Phase 3: persistent per-person voice fingerprints.
        // Each row is a 40-dim mel-spectrum embedding averaged over all meetings
        // where this person was identified. Keyed by personName (unique). Used
        // by VoiceProfileService to recognise known participants before the LLM
        // attribution step, so familiar voices are assigned instantly.
        migrator.registerMigration("v26-voice-profile") { db in
            try db.create(table: "voiceProfile") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("personName", .text).notNull().unique()
                t.column("embeddingData", .blob).notNull()
                t.column("sampleCount", .integer).notNull().defaults(to: 0)
                t.column("lastUpdatedAt", .datetime).notNull()
            }
        }

        // v3.6 Knowledge Base — index user's chosen folder of .md/.txt/.html/
        // .docx files for retrieval-augmented context in meeting prep + chat.
        // Each row is a chunk (typically a Markdown section or paragraph), not
        // a whole file, so retrieval can pull just the relevant slices.
        migrator.registerMigration("v27-knowledge-base") { db in
            try db.create(table: "kbDocument") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("filePath", .text).notNull()       // absolute path on disk
                t.column("fileName", .text).notNull()       // for display + scoring
                t.column("relativePath", .text).notNull()   // path relative to KB root
                t.column("chunkIndex", .integer).notNull()  // 0-based within file
                t.column("heading", .text)                  // section heading if any
                t.column("body", .text).notNull()           // chunk text
                t.column("indexedAt", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
            }
            try db.create(index: "idx_kbDocument_filePath", on: "kbDocument", columns: ["filePath"])

            try db.create(virtualTable: "kbDocument_fts", using: FTS5()) { t in
                t.synchronize(withTable: "kbDocument")
                t.column("body")
                t.column("heading")
                t.column("fileName").notIndexed()
                t.column("relativePath").notIndexed()
            }
        }

        migrator.registerMigration("v28-kb-write-back") { db in
            try db.alter(table: "appSettings") { t in
                t.add(column: "kbWriteBack", .boolean).notNull().defaults(to: false)
            }
        }

        // Multi-calendar selection. Both columns are nullable text holding
        // a comma-separated list of calendar IDs. NULL/empty means "use the
        // legacy single-select fallback" (Google) or "all enabled" (Apple).
        migrator.registerMigration("v29-multi-calendar-selection") { db in
            try db.alter(table: "appSettings") { t in
                t.add(column: "selectedGoogleCalendarIds", .text)
                t.add(column: "selectedAppleCalendarIds", .text)
            }
        }

        // Cleaned per-meeting transcript blob. The raw per-segment transcript
        // rows are preserved untouched (search/action-items/voice-profiles
        // depend on them); this table stores the post-processed readable
        // version that the UI shows by default and that KB write-back exports.
        migrator.registerMigration("v30-cleaned-transcript") { db in
            try db.create(table: "cleanedTranscript") { t in
                t.column("meetingId", .text).primaryKey()
                t.column("text", .text).notNull()
                t.column("generatedAt", .datetime).notNull()
                t.column("method", .text).notNull()
            }
        }

        // v3.9 Phase 1: stable Person identity table. A Person is the canonical
        // anchor for a real human across all name/email format variants.
        // aliasesJSON stores every observed raw string (emails, display names)
        // as a JSON array. VoiceProfile gains a personId FK so voice learning
        // survives renames and email-format drift.
        migrator.registerMigration("v31-person-identity") { db in
            // Guard: remove any taskQueue rows whose meetingId contains newlines
            // (a bulk-insert bug from the v3.8 session stored multiple UUIDs
            // as one value). These violate the taskQueue→meeting FK and block
            // the migration transaction from committing. Safe to delete: each
            // affected meeting already has valid individual task rows.
            try db.execute(sql: """
                DELETE FROM taskQueue WHERE instr(meetingId, char(10)) > 0
                """)

            try db.create(table: "person") { t in
                t.column("id", .text).primaryKey()
                t.column("canonicalName", .text).notNull()
                t.column("aliasesJSON", .text).notNull().defaults(to: "[]")
                t.column("createdAt", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
                t.column("updatedAt", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
            }
            try db.create(
                index: "idx_person_canonicalName",
                on: "person",
                columns: ["canonicalName"]
            )

            // Add personId to voiceProfile so profiles can be looked up by
            // stable identity rather than by the fragile name string.
            // NOTE: SQLite ALTER TABLE ADD COLUMN does not support ON DELETE
            // foreign key actions — this is a plain nullable text column. The
            // application layer (PersonRepository.merge) handles orphan cleanup.
            try db.alter(table: "voiceProfile") { t in
                t.add(column: "personId", .text)
            }
            try db.create(
                index: "idx_voiceProfile_personId",
                on: "voiceProfile",
                columns: ["personId"]
            )
        }

        // v3.9 Phase 4: per-utterance voice sample bank. Stores individual
        // embeddings alongside the EMA centroid in VoiceProfile so bad
        // attributions can be rolled back and profiles rebuilt from scratch.
        migrator.registerMigration("v32-voice-sample-bank") { db in
            try db.create(table: "voiceSample") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("personId", .text).notNull()
                t.column("meetingId", .text).notNull()
                t.column("startTime", .double).notNull()
                t.column("endTime", .double).notNull()
                t.column("embeddingData", .blob).notNull()
                t.column("source", .text).notNull().defaults(to: "unknown")
                t.column("createdAt", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
            }
            try db.create(
                index: "idx_voiceSample_personId",
                on: "voiceSample",
                columns: ["personId", "createdAt"]
            )
            try db.create(
                index: "idx_voiceSample_meetingId",
                on: "voiceSample",
                columns: ["meetingId"]
            )
        }

        // v3.9 Phase 5: opt-in Contacts import toggle.
        migrator.registerMigration("v33-contacts-import-setting") { db in
            try db.alter(table: "appSettings") { t in
                t.add(column: "contactsImportEnabled", .boolean).notNull().defaults(to: false)
            }
        }

        // v3.10: speaker-ID signal upgrades.
        //   - declinedAttendees: comma-separated names of invitees who declined,
        //     so attribution and cluster-count hints can exclude them
        //   - speakerConfidenceMap: JSON {cluster: float} produced by attribution,
        //     so the UI can mark low-confidence attributions for review
        //   - voiceProfile.manualSampleCount / llmSampleCount: source-quality
        //     telemetry that lets matching raise the bar on profiles that have
        //     only ever been confirmed by LLM (and would otherwise drift)
        migrator.registerMigration("v34-speaker-signals") { db in
            try db.alter(table: "meeting") { t in
                t.add(column: "declinedAttendees", .text)
                t.add(column: "speakerConfidenceMap", .text)
            }
            try db.alter(table: "voiceProfile") { t in
                t.add(column: "manualSampleCount", .integer).notNull().defaults(to: 0)
                t.add(column: "llmSampleCount", .integer).notNull().defaults(to: 0)
            }
            // Backfill: existing profiles were trained under the old single-α
            // model with no source tagging — treat them all as confirmed
            // (manualSampleCount = sampleCount). Without this, every legacy
            // profile would suddenly need 0.87 cosine instead of 0.82 to
            // match, silently breaking cross-meeting voice recognition for
            // every existing user on the upgrade.
            try db.execute(sql: """
                UPDATE voiceProfile SET manualSampleCount = sampleCount WHERE sampleCount > 0
                """)
        }

        // v35: detailed outline blob per meeting + editable prompt template
        // for it. Mirrors `cleanedTranscript` storage. The outline sits
        // between the one-page summary and the full transcript on the
        // density spectrum: time-stamped, topic-segmented, prose with
        // optional fact bullets. See `Services/AI/DetailedOutlineService.swift`.
        migrator.registerMigration("v35-detailed-outline") { db in
            try db.create(table: "detailedOutline") { t in
                t.column("meetingId", .text).primaryKey()
                t.column("text", .text).notNull()
                t.column("generatedAt", .datetime).notNull()
                t.column("method", .text).notNull()
                t.column("modelUsed", .text)
            }
            try db.alter(table: "appSettings") { t in
                t.add(column: "detailedOutlinePromptTemplate", .text)
            }
        }

        // v36: shift the local-LLM ladder from Llama 3.x to Qwen3 (ADR-007).
        // Users who never opened Settings have `ollamaModel='llama3.2:3b'`
        // (the v9 default). Flip them to `'auto'` so they pick up the new
        // ladder automatically. Users who explicitly chose llama3.1:8b,
        // qwen3:*, or any other model are left untouched. Append-only per
        // the migrations rule — v9-local-llm is not edited.
        migrator.registerMigration("v36-qwen3-default") { db in
            try db.execute(sql: """
                UPDATE appSettings SET ollamaModel = 'auto' WHERE ollamaModel = 'llama3.2:3b'
                """)
        }

        // The pre-v37 default summary prompt produced Markdown tables with
        // <br> tags on Qwen3 because it asked for a "## Topic Timeline" with
        // [HH:MM–HH:MM] sub-blocks — the model collapsed that into a table.
        // Reset stored templates that still match the old default to the new
        // bullet-based default. Detect by the unique "## Topic Timeline"
        // heading; any user who customised their prompt won't have that exact
        // string and is left untouched.
        migrator.registerMigration("v37-summary-prompt-rewrite") { db in
            try db.execute(sql: """
                UPDATE appSettings
                SET summaryPromptTemplate = ?
                WHERE summaryPromptTemplate LIKE '%## Topic Timeline%'
                """, arguments: [AppSettings.default.summaryPromptTemplate])
        }

        // v37 only matched the most recent old default ("## Topic Timeline").
        // Some installs still carry the much older "1. **Key Discussion Points**"
        // numbered-list default, which is what was producing the table layout
        // on Qwen3. Match both legacy fingerprints and reset to the new default.
        migrator.registerMigration("v38-summary-prompt-rewrite-legacy") { db in
            try db.execute(sql: """
                UPDATE appSettings
                SET summaryPromptTemplate = ?
                WHERE summaryPromptTemplate LIKE '%1. **Key Discussion Points**%'
                   OR summaryPromptTemplate LIKE '%## Topic Timeline%'
                """, arguments: [AppSettings.default.summaryPromptTemplate])
        }

        // v39: Outline prompt redesign — topic-based chunking instead of
        // minute-by-minute segments. Matches old default by fingerprint
        // ("typically 5–15 sections") and resets to new default.
        migrator.registerMigration("v39-outline-prompt-topic-chunking") { db in
            try db.execute(sql: """
                UPDATE appSettings
                SET detailedOutlinePromptTemplate = ?
                WHERE detailedOutlinePromptTemplate LIKE '%typically 5–15 sections%'
                   OR detailedOutlinePromptTemplate LIKE '%typically 5-15 sections%'
                """, arguments: [DefaultPrompts.detailedOutline])
        }

        // v40: durable transcription-attempt marker. The startup orphan scan
        // re-enqueues a transcription task for every complete/transcribing
        // meeting that has audio but no transcript rows, guarding only against
        // meetings that still had a transcription task ROW. The Tasks view's
        // "Clear completed" button deletes those rows, so clearing completed
        // tasks made the scan re-enqueue every such meeting on the next launch
        // (the "~50 tasks on reopen" report). Persist the attempt on the
        // meeting itself so it survives task-row deletion.
        migrator.registerMigration("v40-transcription-attempt-marker") { db in
            try db.alter(table: "meeting") { t in
                t.add(column: "transcriptionAttemptedAt", .datetime)
            }
            // Backfill meetings that already have transcripts — they've
            // demonstrably been transcribed, so mark them attempted. (They
            // don't match the orphan candidate query anyway since it requires
            // zero transcript rows; this just keeps the column honest.)
            // Meetings with audio but no transcripts are intentionally left
            // NULL so the scan still transcribes them once.
            try db.execute(sql: """
                UPDATE meeting SET transcriptionAttemptedAt = updatedAt
                WHERE EXISTS (SELECT 1 FROM transcript t WHERE t.meetingId = meeting.id)
                """)
        }

        // v41: Apollo-backed attendee profile prep (v3.13.0). Three settings
        // columns gate the feature — toggle, key-validated flag, last-validated
        // timestamp. The actual API key lives in the Keychain, not the DB.
        migrator.registerMigration("v41-apollo-profile-prep") { db in
            try db.alter(table: "appSettings") { t in
                t.add(column: "apolloProfilePrepEnabled", .boolean).notNull().defaults(to: false)
                t.add(column: "apolloKeyValidated", .boolean).notNull().defaults(to: false)
                t.add(column: "apolloKeyLastValidatedAt", .datetime)
            }
        }

        migrator.registerMigration("v42-mic-override") { db in
            try db.alter(table: "appSettings") { t in
                t.add(column: "micOverrideEnabled", .boolean).notNull().defaults(to: false)
                t.add(column: "micOverrideDeviceID", .text).notNull().defaults(to: "")
            }
        }

        // v43: FluidAudio diarization engine flag (speaker-id re-architecture
        // Phase 1). Default off — SpeakerKit stays the diarizer until the flag
        // is flipped, so this is a no-op for existing installs.
        migrator.registerMigration("v43-fluidaudio-diarization") { db in
            try db.alter(table: "appSettings") { t in
                t.add(column: "useFluidAudioDiarization", .boolean).notNull().defaults(to: false)
            }
        }

        // v44: cross-meeting voice identity (speaker-id re-architecture Phase 2).
        // Stores one FluidAudio speaker reference per Person — a 256-dim wespeaker
        // embedding (l2-normalized, little-endian Float32) aggregated from that
        // person's highest-confidence diarization segments. Before diarizing a
        // meeting, SpeakerEnrollmentService loads these references for the RSVP-
        // accepted attendees and seeds them into FluidAudio via
        // initializeKnownSpeakers so matching clusters come back already named.
        // Keyed by personId so the reference survives renames/email drift, just
        // like voiceProfile. Distinct from the v26 mel-spectrum voiceProfile
        // table (kept compiled-but-unused until Phase 8) — the embeddings have
        // different dimensions and semantics, so they cannot share a table.
        migrator.registerMigration("v44-voice-reference") { db in
            try db.create(table: "voiceReference") { t in
                t.column("personId", .text).primaryKey()
                t.column("personName", .text).notNull()
                t.column("embeddingData", .blob).notNull()
                t.column("segmentCount", .integer).notNull().defaults(to: 0)
                t.column("updatedAt", .datetime).notNull()
            }
        }

        migrator.registerMigration("v45-attribution-flags") { db in
            try db.alter(table: "meeting") { t in
                t.add(column: "attributionFlags", .text)
            }
        }

        // v46: "Enhance Notes" (PRJ-007 TASK-020, ADR-013). A derived AI
        // artifact that rewrites the user's raw notes into a polished version
        // in *their own* structure — kept distinct from `meetingNote` (user
        // ground truth, never overwritten) and `meetingSummary` (fixed
        // TL;DR/Decisions format). One row per meeting, replace-on-write —
        // mirrors `detailedOutline` (v35).
        //
        // `sourceNotesHash` stores a stable hash (CryptoKit SHA256) of the
        // notes the enhancement was built from; the viewer compares it to the
        // current combined notes and offers "Re-enhance" on mismatch. NOT
        // `String.hashValue`, which is salted per process and would falsely
        // flag every enhancement as stale on the next launch.
        migrator.registerMigration("v46-enhanced-note") { db in
            try db.create(table: "enhancedNote") { t in
                t.column("meetingId", .text).primaryKey()
                t.column("content", .text).notNull()
                t.column("modelUsed", .text)
                t.column("generatedAt", .datetime).notNull()
                t.column("sourceNotesHash", .text).notNull().defaults(to: "")
                t.column("sourceNotesLength", .integer).notNull().defaults(to: 0)
            }
            // Editable in Settings → Prompts → Enhance Notes. Nullable so the
            // column can be added without backfill — readers resolve nil to
            // `DefaultPrompts.enhanceNotes` at call time.
            try db.alter(table: "appSettings") { t in
                t.add(column: "enhanceNotesPromptTemplate", .text)
            }
            // Persisted at generation time so the summary's "Shaped by your
            // notes" cue survives the user editing or deleting notes after the
            // summary was produced. Re-deriving at view time would lie.
            try db.alter(table: "meetingSummary") { t in
                t.add(column: "notesInformedSummary", .boolean).notNull().defaults(to: false)
            }
        }

        // v47: persisted Apollo enrichment cache (PRJ-007 TASK-023, ADR-014).
        // ApolloService only caches profiles in memory for the session, so
        // enrichment re-fetches on every launch — burning API credits and
        // adding latency. This table persists each person/company lookup so
        // the Companies lens and richer profile cards load instantly across
        // launches, bounded to roughly one fetch per email/domain per week by
        // a 7-day TTL.
        //
        // `cacheKey` is the lowercased email for people and `domain:<domain>`
        // for companies — the prefix keeps the two namespaces from colliding.
        // `found = 0` is a negative cache: Apollo returned no match, so the
        // coordinator must not re-fetch until the row goes stale.
        //
        // No FK: the key is an email/domain, not a `person.id`, so there's
        // nothing to cascade. Orphaned rows are harmless and age out via
        // `purgeStale` — same rationale as `voiceReference` (v44).
        migrator.registerMigration("v47-apollo-profile") { db in
            try db.create(table: "apolloProfile") { t in
                t.column("cacheKey", .text).primaryKey()
                t.column("kind", .text).notNull()
                t.column("payloadJSON", .text).notNull()
                t.column("fetchedAt", .datetime).notNull()
                t.column("found", .boolean).notNull().defaults(to: true)
            }
        }

        // v48: Claude model refresh (TASK-028). The launch-era models
        // `claude-sonnet-4-20250514` / `claude-opus-4-20250514` are deprecated
        // and retire on 2026-06-15 — every API call with them 404s after that.
        // Changing the code default (AppSettings.default / Constants.Defaults)
        // only covers fresh installs; rows that already persisted a deprecated
        // ID must be rewritten here, each to its Anthropic-recommended
        // replacement alias. Date-suffix-free aliases track Anthropic's
        // current snapshot, so the stored value can't strand users this way
        // again. `meetingSummary.modelUsed` is deliberately left alone — it
        // records which model produced a past summary (provenance, not
        // configuration).
        migrator.registerMigration("v48-claude-model-refresh") { db in
            try db.execute(sql: """
                UPDATE appSettings
                SET claudeModel = 'claude-sonnet-4-6'
                WHERE claudeModel = 'claude-sonnet-4-20250514'
                """)
            try db.execute(sql: """
                UPDATE appSettings
                SET claudeModel = 'claude-opus-4-8'
                WHERE claudeModel = 'claude-opus-4-20250514'
                """)
        }

        // PRJ-009: knowledge-base & AI extension tables. One migration for
        // all four waves — the release ships after wave 4, and empty tables
        // are harmless in the interim. Vector BLOBs are 768xFloat32 LE
        // (nomic-embed-text); kbExport tracks write-back state per meeting
        // (content hash, NOT mtime — atomic renames make mtime unreliable);
        // weeklyDigest persists digests so Home can render them without the
        // KB write-back setting being on.
        migrator.registerMigration("v49-knowledge-ai") { db in
            try db.create(table: "embedding") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("sourceType", .text).notNull()   // transcriptChunk|summary|kbDoc
                t.column("sourceId", .text).notNull()     // meetingId or filePath
                t.column("meetingId", .text)
                t.column("chunkIndex", .integer).notNull().defaults(to: 0)
                t.column("contentHash", .text).notNull().defaults(to: "")
                t.column("text", .text).notNull()
                t.column("vector", .blob).notNull()
                t.column("model", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(index: "idx_embedding_source", on: "embedding",
                          columns: ["sourceType", "sourceId"])
            try db.create(index: "idx_embedding_meeting", on: "embedding",
                          columns: ["meetingId"])

            try db.create(table: "entityFact") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("entityType", .text).notNull()   // person|company|series
                t.column("entityKey", .text).notNull()
                t.column("meetingId", .text).notNull()
                t.column("kind", .text).notNull()         // decision|commitment|question|status
                t.column("text", .text).notNull()
                t.column("owner", .text)
                t.column("dueDate", .datetime)
                t.column("extractedAt", .datetime).notNull()
            }
            try db.create(index: "idx_entityFact_entity", on: "entityFact",
                          columns: ["entityType", "entityKey"])
            try db.create(index: "idx_entityFact_meeting", on: "entityFact",
                          columns: ["meetingId"])

            try db.create(table: "seriesThread") { t in
                t.column("folderKey", .text).primaryKey() // MeetingFolder.normaliseTitle key
                t.column("content", .text).notNull()
                t.column("updatedAt", .datetime).notNull()
            }

            try db.create(table: "kbExport") { t in
                t.column("meetingId", .text).primaryKey()
                t.column("filePath", .text).notNull()
                t.column("exportedAt", .datetime).notNull()
                t.column("contentHash", .text).notNull()
            }

            try db.create(table: "weeklyDigest") { t in
                t.column("isoWeek", .text).primaryKey()   // "2026-W24"
                t.column("content", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
        }

        // PRJ-010 phases 0-2 (v51 carries phases 3-4 — split at the release
        // boundary per the review's append-only ruling). runAfter powers the
        // background-work governor; sourceStartTime is denormalized so a
        // re-transcription (which rewrites transcript rowids) degrades fact
        // anchors to stale-but-honest timestamps instead of dangling.
        migrator.registerMigration("v50-governor-and-knowledge") { db in
            try db.alter(table: "taskQueue") { t in
                t.add(column: "runAfter", .datetime)
            }
            try db.alter(table: "entityFact") { t in
                t.add(column: "hiddenAt", .datetime)
                t.add(column: "sourceTranscriptId", .integer)
                t.add(column: "sourceStartTime", .double)
            }
            try db.alter(table: "meetingSummary") { t in
                t.add(column: "originalText", .text)
            }
            try db.create(table: "factLink") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("fromFact", inTable: "entityFact", onDelete: .cascade).notNull()
                t.belongsTo("toFact", inTable: "entityFact", onDelete: .cascade).notNull()
                t.column("relation", .text).notNull()   // duplicate|supersedes|contradicts
                t.column("detectedAt", .datetime).notNull()
            }
            try db.create(table: "glossaryTerm") { t in
                t.column("term", .text).primaryKey()
                t.column("definition", .text).notNull()
                t.column("exampleMeetingId", .text)
                t.column("hiddenAt", .datetime)         // tombstone: miner respects deletes
                t.column("updatedAt", .datetime).notNull()
            }
        }

        // taskQueue.meetingId carried an FK to meeting(id) with CASCADE.
        // Sentinel rows ("__embed_backfill__", "__weekly_digest__",
        // "__kb_index__") violate it, and every such enqueue failed
        // SILENTLY (os_log only) — discovered 2026-06-11 when the embed
        // backfill vanished without trace (TASK-073's enqueue logging
        // caught it). Rebuild without the FK: handlers already tolerate
        // missing meetings, and completed-row pruning handles hygiene.
        // CASCADE cleanup for real meetings is replaced by an explicit
        // delete in MeetingRepository.delete.
        migrator.registerMigration("v51-taskqueue-sentinels") { db in
            try db.create(table: "taskQueue_new") { t in
                t.column("id", .text).primaryKey()
                t.column("type", .text).notNull()
                t.column("meetingId", .text).notNull()
                t.column("status", .text).notNull().defaults(to: "pending")
                t.column("priority", .integer).notNull().defaults(to: 5)
                t.column("retryCount", .integer).notNull().defaults(to: 0)
                t.column("maxRetries", .integer).notNull().defaults(to: 3)
                t.column("error", .text)
                t.column("createdAt", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
                t.column("startedAt", .datetime)
                t.column("completedAt", .datetime)
                t.column("metadata", .text)
                t.column("runAfter", .datetime)
            }
            try db.execute(sql: """
                INSERT INTO taskQueue_new
                SELECT id, type, meetingId, status, priority, retryCount,
                       maxRetries, error, createdAt, startedAt, completedAt,
                       metadata, runAfter
                FROM taskQueue
                """)
            try db.drop(table: "taskQueue")
            try db.rename(table: "taskQueue_new", to: "taskQueue")
            try db.create(
                index: "idx_taskQueue_status_priority",
                on: "taskQueue",
                columns: ["status", "priority", "createdAt"]
            )
            try db.create(
                index: "idx_taskQueue_meetingId",
                on: "taskQueue",
                columns: ["meetingId"]
            )
        }

        // TASK-066: receipts-grade follow-ups. The built-in follow-up email
        // recipe gains the {{commitmentsWithReceipts}} and {{carriedQuestions}}
        // variables (resolved from anchored entityFact rows + the prior
        // series instance). Same unconditional-UPDATE pattern as v23.
        migrator.registerMigration("v52-follow-up-receipts") { db in
            let updatedPrompt = """
            Write a concise follow-up email based on this meeting.

            Format the response EXACTLY as:
            Subject: <one-line subject>

            <email body>

            Body guidance: thank the attendees, recap the 3 most important decisions or discussion points, then list the confirmed commitments. For each commitment that has a "(… — near MM:SS)" reference below, keep that reference in the email so the recap is verifiable against the recording — always phrase it as approximate ("near 14:32"), never as an exact moment. If questions were carried over unanswered from the previous session, re-raise them in a short "Still open from last time" line or list. Close with next steps. Keep it under 250 words. Professional but warm tone. Never invent commitments, owners, or timestamps that are not listed below.

            Meeting: {{meetingTitle}}
            Date: {{date}}

            ## Confirmed commitments (with transcript references):
            {{commitmentsWithReceipts}}

            ## Unanswered from the previous session:
            {{carriedQuestions}}

            ## Transcript:
            {{transcript}}

            ## Notes:
            {{notes}}
            """
            try db.execute(
                sql: """
                    UPDATE recipe
                    SET promptTemplate = ?,
                        description = ?
                    WHERE id = ?
                    """,
                arguments: [
                    updatedPrompt,
                    "Draft a follow-up email that cites the transcript moment for each commitment and re-raises last session's open questions",
                    "builtin-follow-up-email"
                ]
            )
        }

        // PRJ-010 Phase 3 (TASK-065 + TASK-062). meetingIntent rows attach
        // to real meetings only (FK CASCADE); generatedDoc anchors on a
        // string key (folder key today) because folders are runtime-derived
        // — no table to reference.
        migrator.registerMigration("v53-intent-and-docs") { db in
            try db.create(table: "meetingIntent") { t in
                t.column("meetingId", .text).primaryKey()
                    .references("meeting", onDelete: .cascade)
                t.column("intent", .text).notNull()
                t.column("outcomeScore", .text)     // met | partial | not | unclear
                t.column("outcomeNote", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("scoredAt", .datetime)
            }
            try db.create(table: "generatedDoc") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("kind", .text).notNull()       // "handover"
                t.column("anchorKey", .text).notNull()  // MeetingFolder key
                t.column("content", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(index: "idx_generatedDoc_anchor", on: "generatedDoc",
                          columns: ["kind", "anchorKey"])
        }

        // TASK-059: per-meeting speaking metrics (user only, on-device,
        // no LLM). Derived data — recomputable from transcripts.
        migrator.registerMigration("v54-speech-stats") { db in
            try db.create(table: "speechStats") { t in
                t.column("meetingId", .text).primaryKey()
                    .references("meeting", onDelete: .cascade)
                t.column("talkShare", .double).notNull()
                t.column("interruptions", .integer).notNull()
                t.column("fillerPer100", .double).notNull()
                t.column("questionRate", .double).notNull()
                t.column("longestMonologueSec", .double).notNull()
                t.column("userWordCount", .integer).notNull()
                t.column("computedAt", .datetime).notNull()
            }
        }

        // TASK-069 (manual-capture shape): slide texts OCR'd on demand
        // during recording. Search/browse surface only — deliberately
        // excluded from chat retrieval (qwen-first decision, see ledger).
        migrator.registerMigration("v55-meeting-slides") { db in
            try db.create(table: "meetingSlide") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("meetingId", .text).notNull()
                    .references("meeting", onDelete: .cascade)
                t.column("atSeconds", .double).notNull()
                t.column("text", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(index: "idx_meetingSlide_meeting", on: "meetingSlide",
                          columns: ["meetingId", "atSeconds"])
        }

        // TASK-078 (PRJ-011): saved clips / key quotes — a time range + the
        // verbatim quote snapshot + speakers. Search/keep/listen only; no
        // sharing. Derived from a meeting; CASCADE on delete.
        migrator.registerMigration("v56-clips") { db in
            try db.create(table: "clip") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("meetingId", .text).notNull()
                    .references("meeting", onDelete: .cascade)
                t.column("startTime", .double).notNull()
                t.column("endTime", .double).notNull()
                t.column("quoteText", .text).notNull()
                t.column("speakerLabels", .text)
                t.column("note", .text)
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(index: "idx_clip_meeting", on: "clip",
                          columns: ["meetingId", "startTime"])
        }
    }
}
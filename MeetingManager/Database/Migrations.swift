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
    }
}

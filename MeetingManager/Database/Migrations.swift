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

            // Insert default settings
            try db.execute(sql: """
                INSERT INTO appSettings (id, summaryPromptTemplate)
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
    }
}

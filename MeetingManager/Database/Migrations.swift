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
                t.column("whisperModel", .text).notNull().defaults(to: "tiny-en")
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
    }
}

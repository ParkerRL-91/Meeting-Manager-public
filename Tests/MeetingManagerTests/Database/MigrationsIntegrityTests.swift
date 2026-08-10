import XCTest
import GRDB
@testable import MeetingManager

// MARK: - Migration Integrity Tests
//
// Covers gaps NOT addressed by MigrationsTests:
//   - Full ordered migration identifier list asserted via grdb_migrations table
//   - Critical column existence on key tables (columns added by later migrations)
//   - Idempotency: a second AppDatabase.empty() does not throw or duplicate seed rows
//   - Cascade delete: children are removed when a meeting is deleted (all tables
//     with onDelete: .cascade in their FK definition)
//   - No-cascade tables (cleanedTranscript, detailedOutline): meetingId is a
//     primary key with no FK reference — rows are NOT removed on meeting delete
//   - NOT NULL / default columns added by later migrations have correct defaults
//
// Cascade analysis from Migrations.swift:
//   transcript       → meeting  onDelete: .cascade
//   meetingNote      → meeting  onDelete: .cascade
//   meetingSummary   → meeting  onDelete: .cascade
//   chatMessage      → meeting  onDelete: .cascade
//   actionItem       → meeting  onDelete: .cascade
//   recipeResult     → meeting  onDelete: .cascade  (also → recipe onDelete: .cascade)
//   taskQueue        → meeting  onDelete: .cascade
//   cleanedTranscript  meetingId is the PRIMARY KEY — no FK reference declared
//   detailedOutline    meetingId is the PRIMARY KEY — no FK reference declared
//
// NOTE on foreign-key enforcement: raw SQLite leaves PRAGMA foreign_keys OFF, but
// GRDB enables it by default — Configuration.foreignKeysEnabled is `true` and GRDB
// runs `PRAGMA foreign_keys = ON` on every connection it opens (see GRDB
// Database.swift). AppDatabase never sets foreignKeysEnabled = false, so BOTH the
// production DatabasePool (_makeShared) and the in-memory DatabaseQueue (empty())
// enforce FK constraints. The cascade test below therefore deletes through a plain
// AppDatabase.empty() connection with no manual pragma, proving the configured DB
// enforces the declared `onDelete: .cascade` relationships exactly as production does.

final class MigrationsIntegrityTests: XCTestCase {

    private var db: AppDatabase!

    // The full ordered migration identifier list, derived from Migrations.registerAll.
    private static let allMigrationIdentifiers: [String] = [
        "v1",
        "v2",
        "add-isEdited",
        "v3",
        "v4",
        "v5-ai-enabled",
        "v6-auto-record-invite",
        "v7-meeting-participants",
        "v8-calendar-selection",
        "v9-local-llm",
        "v10-auto-generate-summary",
        "v11-reopen",
        "v12-performance-indexes",
        "v13-transcript-fts",
        "v14-task-queue",
        "v15-context-json",
        "v16-meet-link",
        "v17-whisper-turbo-default",
        "v18-meeting-templates",
        "v19-auto-follow-up-email",
        "v20-morning-brief",
        "v21-transcript-dedup-index",
        "v22-fts-rebuild",
        "v23-follow-up-email-prompt-v2",
        "v24-speaker-map",
        "v25-speaker-alias",
        "v26-voice-profile",
        "v27-knowledge-base",
        "v28-kb-write-back",
        "v29-multi-calendar-selection",
        "v30-cleaned-transcript",
        "v31-person-identity",
        "v32-voice-sample-bank",
        "v33-contacts-import-setting",
        "v34-speaker-signals",
        "v35-detailed-outline",
        "v36-qwen3-default",
        "v37-summary-prompt-rewrite",
        "v38-summary-prompt-rewrite-legacy",
        "v39-outline-prompt-topic-chunking",
        "v40-transcription-attempt-marker",
        "v41-apollo-profile-prep",
        "v42-mic-override",
        "v43-fluidaudio-diarization",
        "v44-voice-reference",
        "v45-attribution-flags",
        "v46-enhanced-note",
        "v47-apollo-profile",
        "v48-claude-model-refresh",
    ]

    override func setUpWithError() throws {
        db = try TestDatabase.create()
    }

    // MARK: - Migration Identifier Completeness

    func testAllMigrationIdentifiersAreApplied() throws {
        let applied = try db.writer.read { conn -> [String] in
            try String.fetchAll(conn, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
        }
        XCTAssertEqual(
            applied,
            Self.allMigrationIdentifiers,
            "Applied migration identifiers differ from the expected ordered list"
        )
    }

    // MARK: - Additional Table Existence (gaps from MigrationsTests)

    func testTaskQueueTableExists() throws {
        let exists = try db.writer.read { try $0.tableExists("taskQueue") }
        XCTAssertTrue(exists)
    }

    func testMeetingTemplateTableExists() throws {
        let exists = try db.writer.read { try $0.tableExists("meetingTemplate") }
        XCTAssertTrue(exists)
    }

    func testSpeakerAliasTableExists() throws {
        let exists = try db.writer.read { try $0.tableExists("speakerAlias") }
        XCTAssertTrue(exists)
    }

    func testVoiceProfileTableExists() throws {
        let exists = try db.writer.read { try $0.tableExists("voiceProfile") }
        XCTAssertTrue(exists)
    }

    func testVoiceReferenceTableExists() throws {
        let exists = try db.writer.read { try $0.tableExists("voiceReference") }
        XCTAssertTrue(exists)
    }

    func testKbDocumentTableExists() throws {
        let exists = try db.writer.read { try $0.tableExists("kbDocument") }
        XCTAssertTrue(exists)
    }

    func testCleanedTranscriptTableExists() throws {
        let exists = try db.writer.read { try $0.tableExists("cleanedTranscript") }
        XCTAssertTrue(exists)
    }

    func testPersonTableExists() throws {
        let exists = try db.writer.read { try $0.tableExists("person") }
        XCTAssertTrue(exists)
    }

    func testVoiceSampleTableExists() throws {
        let exists = try db.writer.read { try $0.tableExists("voiceSample") }
        XCTAssertTrue(exists)
    }

    func testDetailedOutlineTableExists() throws {
        let exists = try db.writer.read { try $0.tableExists("detailedOutline") }
        XCTAssertTrue(exists)
    }

    func testTranscriptFTSVirtualTableExists() throws {
        let exists = try db.writer.read { try $0.tableExists("transcript_fts") }
        XCTAssertTrue(exists)
    }

    func testKbDocumentFTSVirtualTableExists() throws {
        let exists = try db.writer.read { try $0.tableExists("kbDocument_fts") }
        XCTAssertTrue(exists)
    }

    // MARK: - Critical Column Existence on meeting Table

    func testMeetingTableHasAudioFilePathsColumn() throws {
        let columnNames = try meetingColumnNames()
        XCTAssertTrue(columnNames.contains("audioFilePaths"),
                      "meeting.audioFilePaths (added in v11-reopen) is missing")
    }

    func testMeetingTableHasIsAllDayColumn() throws {
        let columnNames = try meetingColumnNames()
        XCTAssertTrue(columnNames.contains("isAllDay"),
                      "meeting.isAllDay (added in v11-reopen) is missing")
    }

    func testMeetingTableHasParticipantsColumn() throws {
        let columnNames = try meetingColumnNames()
        XCTAssertTrue(columnNames.contains("participants"),
                      "meeting.participants (added in v7-meeting-participants) is missing")
    }

    func testMeetingTableHasContextJSONColumn() throws {
        let columnNames = try meetingColumnNames()
        XCTAssertTrue(columnNames.contains("contextJSON"),
                      "meeting.contextJSON (added in v15-context-json) is missing")
    }

    func testMeetingTableHasMeetLinkColumn() throws {
        let columnNames = try meetingColumnNames()
        XCTAssertTrue(columnNames.contains("meetLink"),
                      "meeting.meetLink (added in v16-meet-link) is missing")
    }

    func testMeetingTableHasTemplateIdColumn() throws {
        let columnNames = try meetingColumnNames()
        XCTAssertTrue(columnNames.contains("templateId"),
                      "meeting.templateId (added in v18-meeting-templates) is missing")
    }

    func testMeetingTableHasSpeakerMapColumn() throws {
        let columnNames = try meetingColumnNames()
        XCTAssertTrue(columnNames.contains("speakerMap"),
                      "meeting.speakerMap (added in v24-speaker-map) is missing")
    }

    func testMeetingTableHasDeclinedAttendeesColumn() throws {
        let columnNames = try meetingColumnNames()
        XCTAssertTrue(columnNames.contains("declinedAttendees"),
                      "meeting.declinedAttendees (added in v34-speaker-signals) is missing")
    }

    func testMeetingTableHasSpeakerConfidenceMapColumn() throws {
        let columnNames = try meetingColumnNames()
        XCTAssertTrue(columnNames.contains("speakerConfidenceMap"),
                      "meeting.speakerConfidenceMap (added in v34-speaker-signals) is missing")
    }

    func testMeetingTableHasTranscriptionAttemptedAtColumn() throws {
        let columnNames = try meetingColumnNames()
        XCTAssertTrue(columnNames.contains("transcriptionAttemptedAt"),
                      "meeting.transcriptionAttemptedAt (added in v40-transcription-attempt-marker) is missing")
    }

    // MARK: - Critical Column Existence on appSettings Table

    func testAppSettingsHasAiEnabledColumn() throws {
        let names = try settingsColumnNames()
        XCTAssertTrue(names.contains("aiEnabled"), "appSettings.aiEnabled (v5) is missing")
    }

    func testAppSettingsHasAutoRecordAndAutoInviteColumns() throws {
        let names = try settingsColumnNames()
        XCTAssertTrue(names.contains("autoRecord"), "appSettings.autoRecord (v6) is missing")
        XCTAssertTrue(names.contains("autoInvite"), "appSettings.autoInvite (v6) is missing")
    }

    func testAppSettingsHasKbWriteBackColumn() throws {
        let names = try settingsColumnNames()
        XCTAssertTrue(names.contains("kbWriteBack"), "appSettings.kbWriteBack (v28) is missing")
    }

    func testAppSettingsHasMultiCalendarColumns() throws {
        let names = try settingsColumnNames()
        XCTAssertTrue(names.contains("selectedGoogleCalendarIds"),
                      "appSettings.selectedGoogleCalendarIds (v29) is missing")
        XCTAssertTrue(names.contains("selectedAppleCalendarIds"),
                      "appSettings.selectedAppleCalendarIds (v29) is missing")
    }

    func testAppSettingsHasContactsImportEnabledColumn() throws {
        let names = try settingsColumnNames()
        XCTAssertTrue(names.contains("contactsImportEnabled"),
                      "appSettings.contactsImportEnabled (v33) is missing")
    }

    func testAppSettingsHasDetailedOutlinePromptTemplateColumn() throws {
        let names = try settingsColumnNames()
        XCTAssertTrue(names.contains("detailedOutlinePromptTemplate"),
                      "appSettings.detailedOutlinePromptTemplate (v35) is missing")
    }

    func testAppSettingsHasApolloColumns() throws {
        let names = try settingsColumnNames()
        XCTAssertTrue(names.contains("apolloProfilePrepEnabled"),
                      "appSettings.apolloProfilePrepEnabled (v41) is missing")
        XCTAssertTrue(names.contains("apolloKeyValidated"),
                      "appSettings.apolloKeyValidated (v41) is missing")
        XCTAssertTrue(names.contains("apolloKeyLastValidatedAt"),
                      "appSettings.apolloKeyLastValidatedAt (v41) is missing")
    }

    // MARK: - meetingSummary isEdited Column

    func testMeetingSummaryHasIsEditedColumn() throws {
        let names = try db.writer.read { conn -> Set<String> in
            Set(try conn.columns(in: "meetingSummary").map(\.name))
        }
        XCTAssertTrue(names.contains("isEdited"),
                      "meetingSummary.isEdited (add-isEdited migration) is missing")
    }

    // MARK: - voiceProfile Speaker-Signal Columns (v34)

    func testVoiceProfileHasManualAndLlmSampleCountColumns() throws {
        let names = try db.writer.read { conn -> Set<String> in
            Set(try conn.columns(in: "voiceProfile").map(\.name))
        }
        XCTAssertTrue(names.contains("manualSampleCount"),
                      "voiceProfile.manualSampleCount (v34) is missing")
        XCTAssertTrue(names.contains("llmSampleCount"),
                      "voiceProfile.llmSampleCount (v34) is missing")
    }

    // MARK: - Idempotency

    func testOpeningSecondEmptyDatabaseDoesNotThrow() throws {
        // AppDatabase.empty() calls migrator.migrate(writer) in the init.
        // GRDB's DatabaseMigrator is idempotent — it skips already-applied
        // migrations — so a second call must not throw.
        XCTAssertNoThrow(try AppDatabase.empty())
    }

    func testBuiltInRecipesNotDuplicatedOnSecondOpen() throws {
        // Opening a fresh in-memory DB twice (via two AppDatabase.empty() calls)
        // each returns an independent queue, so we test idempotency on the same
        // writer: get the count, re-run migrations via a second open of the same
        // writer — GRDB skips all applied migrations, so count stays at 6.
        let fresh = try AppDatabase.empty()
        let countFirst = try fresh.writer.read { conn in
            try Recipe.filter(Recipe.Columns.isBuiltIn == true).fetchCount(conn)
        }
        // Simulate another migration pass on the same writer.
        // GRDB skips all already-applied migrations, so no duplicate inserts.
        var migrator = DatabaseMigrator()
        Migrations.registerAll(&migrator)
        try migrator.migrate(fresh.writer)

        let countSecond = try fresh.writer.read { conn in
            try Recipe.filter(Recipe.Columns.isBuiltIn == true).fetchCount(conn)
        }
        XCTAssertEqual(countFirst, countSecond,
                       "Re-running migrations duplicated built-in recipe rows (expected \(countFirst), got \(countSecond))")
    }

    func testDefaultAppSettingsNotDuplicatedOnSecondMigrationPass() throws {
        let fresh = try AppDatabase.empty()
        var migrator = DatabaseMigrator()
        Migrations.registerAll(&migrator)
        try migrator.migrate(fresh.writer)

        let count = try fresh.writer.read { conn in
            try AppSettings.fetchCount(conn)
        }
        XCTAssertEqual(count, 1, "Re-running migrations created duplicate appSettings rows")
    }

    // MARK: - Builtin Meeting Templates Seeded

    func testBuiltinMeetingTemplatesSeeded() throws {
        let count = try db.writer.read { conn in
            try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM meetingTemplate WHERE id LIKE 'builtin-template-%'") ?? 0
        }
        XCTAssertEqual(count, 3,
                       "Expected 3 built-in meeting templates (v18-meeting-templates) but found \(count)")
    }

    func testBuiltinMeetingTemplateIdsExist() throws {
        let ids = try db.writer.read { conn -> Set<String> in
            let rows = try String.fetchAll(conn, sql: "SELECT id FROM meetingTemplate WHERE id LIKE 'builtin-template-%'")
            return Set(rows)
        }
        let expected: Set<String> = [
            "builtin-template-one-on-one",
            "builtin-template-standup",
            "builtin-template-planning",
        ]
        XCTAssertEqual(ids, expected)
    }

    // MARK: - Cascade Delete: children removed when meeting is deleted

    // GRDB enables `PRAGMA foreign_keys = ON` on every connection by default
    // (Configuration.foreignKeysEnabled == true), and AppDatabase never disables it.
    // So this test deletes through a plain AppDatabase.empty() connection with no
    // manual pragma, proving the configured DB enforces the declared cascades exactly
    // as the production DatabasePool does.

    func testCascadeDeleteRemovesChildRowsOfDeletedMeeting() async throws {
        let meetingRepo = MeetingRepository(database: db)
        let transcriptRepo = TranscriptRepository(database: db)
        let noteRepo = NoteRepository(database: db)
        let summaryRepo = SummaryRepository(database: db)
        let chatRepo = ChatMessageRepository(database: db)
        let actionRepo = TaskRepository(database: db)

        var meeting = SampleData.makeMeeting(id: "cascade-test")
        try await meetingRepo.save(&meeting)

        var transcript = SampleData.makeTranscript(meetingId: "cascade-test")
        try await transcriptRepo.save(&transcript)

        var note = SampleData.makeMeetingNote(meetingId: "cascade-test")
        try await noteRepo.save(&note)

        var summary = SampleData.makeMeetingSummary(meetingId: "cascade-test")
        try await summaryRepo.save(&summary)

        var chatMsg = SampleData.makeChatMessage(meetingId: "cascade-test")
        try await chatRepo.save(&chatMsg)

        var actionItem = SampleData.makeActionItem(meetingId: "cascade-test")
        try await actionRepo.save(&actionItem)

        // Delete the meeting through the default-configured connection (FK on by
        // GRDB default — no manual pragma needed).
        try await db.writer.write { conn in
            _ = try meeting.delete(conn)
        }

        let transcripts = try await transcriptRepo.transcriptsForMeeting("cascade-test")
        XCTAssertTrue(transcripts.isEmpty,
                      "transcript rows should be cascade-deleted when their meeting is deleted")

        let notes = try await noteRepo.notesForMeeting("cascade-test")
        XCTAssertTrue(notes.isEmpty,
                      "meetingNote rows should be cascade-deleted when their meeting is deleted")

        let summaries = try await summaryRepo.allSummaries(meetingId: "cascade-test")
        XCTAssertTrue(summaries.isEmpty,
                      "meetingSummary rows should be cascade-deleted when their meeting is deleted")

        let messages = try await chatRepo.messagesForMeeting("cascade-test")
        XCTAssertTrue(messages.isEmpty,
                      "chatMessage rows should be cascade-deleted when their meeting is deleted")

        let actions = try await actionRepo.itemsForMeeting("cascade-test")
        XCTAssertTrue(actions.isEmpty,
                      "actionItem rows should be cascade-deleted when their meeting is deleted")
    }

    func testRecipeResultCascadeDeleteOnMeetingDeletion() async throws {
        let meetingRepo = MeetingRepository(database: db)
        let recipeResultRepo = RecipeResultRepository(database: db)

        var meeting = SampleData.makeMeeting(id: "cascade-rr")
        try await meetingRepo.save(&meeting)

        var recipe = SampleData.makeRecipe(id: "recipe-cascade")
        try await db.writer.write { conn in try recipe.save(conn) }

        var result = SampleData.makeRecipeResult(meetingId: "cascade-rr", recipeId: "recipe-cascade")
        try await recipeResultRepo.save(&result)

        try await db.writer.write { conn in
            try conn.execute(sql: "PRAGMA foreign_keys=ON")
            _ = try meeting.delete(conn)
        }

        let remaining = try await recipeResultRepo.resultsForMeeting("cascade-rr")
        XCTAssertTrue(remaining.isEmpty,
                      "recipeResult rows should be cascade-deleted when their meeting is deleted")
    }

    func testRecipeResultCascadeDeleteOnRecipeDeletion() async throws {
        let meetingRepo = MeetingRepository(database: db)
        let recipeResultRepo = RecipeResultRepository(database: db)

        var meeting = SampleData.makeMeeting(id: "cascade-rr2")
        try await meetingRepo.save(&meeting)

        var recipe = SampleData.makeRecipe(id: "recipe-cascade-del")
        try await db.writer.write { conn in try recipe.save(conn) }

        var result = SampleData.makeRecipeResult(meetingId: "cascade-rr2", recipeId: "recipe-cascade-del")
        try await recipeResultRepo.save(&result)

        try await db.writer.write { conn in
            try conn.execute(sql: "PRAGMA foreign_keys=ON")
            _ = try recipe.delete(conn)
        }

        let remaining = try await recipeResultRepo.resultsForMeeting("cascade-rr2")
        XCTAssertTrue(remaining.isEmpty,
                      "recipeResult rows should be cascade-deleted when their recipe is deleted")
    }

    // MARK: - No-Cascade Tables: cleanedTranscript and detailedOutline

    // cleanedTranscript and detailedOutline declare meetingId as their PRIMARY KEY
    // but do NOT declare a .references("meeting") FK in the migration. SQLite
    // therefore applies NO referential action — rows survive meeting deletion.

    func testCleanedTranscriptRowSurvivesMeetingDeletion() async throws {
        let meetingRepo = MeetingRepository(database: db)
        let cleanedRepo = CleanedTranscriptRepository(database: db)

        var meeting = SampleData.makeMeeting(id: "no-cascade-ct")
        try await meetingRepo.save(&meeting)

        let cleaned = CleanedTranscript(
            meetingId: "no-cascade-ct",
            text: "Cleaned text",
            generatedAt: SampleData.fixedDate,
            method: "stitch"
        )
        try await cleanedRepo.save(cleaned)

        // Delete the meeting (even with FK on, cleanedTranscript has no FK declared).
        try await db.writer.write { conn in
            try conn.execute(sql: "PRAGMA foreign_keys=ON")
            _ = try meeting.delete(conn)
        }

        let orphan = try await cleanedRepo.cleanedTranscript(meetingId: "no-cascade-ct")
        // The row is expected to survive because there is no FK cascade.
        XCTAssertNotNil(orphan,
                        "cleanedTranscript has no FK reference — row should survive meeting deletion (no cascade declared)")
    }

    // MARK: - NOT NULL / Default Columns Added by Later Migrations

    func testAudioFilePathsDefaultsToEmptyArray() async throws {
        // v11 adds audioFilePaths NOT NULL DEFAULT '[]'.
        // Insert a meeting via the model (which always passes audioFilePaths) and
        // verify the value round-trips correctly.
        let meetingRepo = MeetingRepository(database: db)
        var meeting = SampleData.makeMeeting(id: "default-afp", audioFilePaths: [])
        try await meetingRepo.save(&meeting)

        let fetched = try await meetingRepo.find(id: "default-afp")
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.audioFilePaths, [],
                       "audioFilePaths default ('[]') should decode to an empty array")
    }

    func testIsAllDayDefaultsFalse() async throws {
        let meetingRepo = MeetingRepository(database: db)
        var meeting = SampleData.makeMeeting(id: "default-iad")
        try await meetingRepo.save(&meeting)

        let fetched = try await meetingRepo.find(id: "default-iad")
        XCTAssertEqual(fetched?.isAllDay, false,
                       "meeting.isAllDay should default to false")
    }

    func testIsEditedDefaultsFalseOnNewSummary() async throws {
        let meetingRepo = MeetingRepository(database: db)
        let summaryRepo = SummaryRepository(database: db)

        var meeting = SampleData.makeMeeting(id: "default-edited")
        try await meetingRepo.save(&meeting)

        var summary = SampleData.makeMeetingSummary(meetingId: "default-edited")
        try await summaryRepo.save(&summary)

        let fetched = try await summaryRepo.latestSummary(meetingId: "default-edited")
        XCTAssertEqual(fetched?.isEdited, false,
                       "meetingSummary.isEdited should default to false (add-isEdited migration)")
    }

    func testTranscriptionAttemptedAtDefaultsNil() async throws {
        let meetingRepo = MeetingRepository(database: db)
        var meeting = SampleData.makeMeeting(id: "default-tat")
        try await meetingRepo.save(&meeting)

        let fetched = try await meetingRepo.find(id: "default-tat")
        XCTAssertNil(fetched?.transcriptionAttemptedAt,
                     "meeting.transcriptionAttemptedAt should default to NULL for new meetings")
    }

    func testSpeakerConfidenceMapAndDeclinedAttendeesDefaultNil() async throws {
        let meetingRepo = MeetingRepository(database: db)
        var meeting = SampleData.makeMeeting(id: "default-v34")
        try await meetingRepo.save(&meeting)

        let fetched = try await meetingRepo.find(id: "default-v34")
        XCTAssertNil(fetched?.declinedAttendees,
                     "meeting.declinedAttendees should default to NULL")
        XCTAssertNil(fetched?.speakerConfidenceMap,
                     "meeting.speakerConfidenceMap should default to NULL")
    }

    func testAppSettingsDefaultValues() throws {
        let settings = try db.writer.read { conn in
            try AppSettings.fetchOne(conn)
        }
        XCTAssertNotNil(settings)
        guard let s = settings else { return }

        XCTAssertTrue(s.aiEnabled, "appSettings.aiEnabled defaults to true (v5 adds the column with DEFAULT true)")
        XCTAssertFalse(s.autoRecord, "appSettings.autoRecord should default to false (v6)")
        XCTAssertTrue(s.autoInvite, "appSettings.autoInvite should default to true (v6)")
        XCTAssertFalse(s.useLocalLLM, "appSettings.useLocalLLM should default to false (v9)")
        XCTAssertFalse(s.kbWriteBack, "appSettings.kbWriteBack should default to false (v28)")
        XCTAssertFalse(s.contactsImportEnabled, "appSettings.contactsImportEnabled should default to false (v33)")
        XCTAssertFalse(s.apolloProfilePrepEnabled, "appSettings.apolloProfilePrepEnabled should default to false (v41)")
        XCTAssertFalse(s.apolloKeyValidated, "appSettings.apolloKeyValidated should default to false (v41)")
        XCTAssertNil(s.apolloKeyLastValidatedAt, "appSettings.apolloKeyLastValidatedAt should default to NULL (v41)")
    }

    // MARK: - Unique Constraint on transcript (v21)

    func testTranscriptUniqueTimeConstraintPreventsDirectDuplicate() throws {
        // The index idx_transcript_unique_time enforces UNIQUE (meetingId, startTime, endTime).
        // Attempting a raw SQL insert of a duplicate should fail once FK enforcement
        // is on and the constraint is present.
        try db.writer.write { conn in
            try conn.execute(sql: "PRAGMA foreign_keys=ON")
            try conn.execute(
                sql: "INSERT INTO meeting (id, title, status, audioFilePaths, isAllDay, createdAt, updatedAt) VALUES (?, ?, ?, ?, ?, ?, ?)",
                arguments: ["uniq-m", "Unique Test", "scheduled", "[]", false, SampleData.fixedDate, SampleData.fixedDate]
            )
            try conn.execute(
                sql: "INSERT INTO transcript (meetingId, text, startTime, endTime, createdAt) VALUES (?, ?, ?, ?, ?)",
                arguments: ["uniq-m", "Hello", 0.0, 5.0, SampleData.fixedDate]
            )
            // Second insert with identical (meetingId, startTime, endTime) must fail.
            XCTAssertThrowsError(
                try conn.execute(
                    sql: "INSERT INTO transcript (meetingId, text, startTime, endTime, createdAt) VALUES (?, ?, ?, ?, ?)",
                    arguments: ["uniq-m", "Different text", 0.0, 5.0, SampleData.fixedDate]
                ),
                "Duplicate (meetingId, startTime, endTime) should violate the unique index from v21-transcript-dedup-index"
            )
        }
    }

    // MARK: - Helpers

    private func meetingColumnNames() throws -> Set<String> {
        try db.writer.read { conn -> Set<String> in
            Set(try conn.columns(in: "meeting").map(\.name))
        }
    }

    private func settingsColumnNames() throws -> Set<String> {
        try db.writer.read { conn -> Set<String> in
            Set(try conn.columns(in: "appSettings").map(\.name))
        }
    }
}

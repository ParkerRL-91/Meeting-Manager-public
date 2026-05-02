# Meeting Manager — Agent Guide

This file is a **table of contents**. The actual system of record is
`knowledge/`. Read this for orientation, then go to knowledge.

---

## ⚠️ Knowledge Base Discipline (read this first)

`knowledge/` is the durable memory of this codebase. Before doing
substantial work:

1. Read `knowledge/README.md` to see what's catalogued
2. Read `knowledge/architecture/overview.md` for top-level shape
3. Read `knowledge/architecture/where-to-find.md` to locate the file
   you'll edit
4. Read the deep-dive that matches your task (speaker-id, person-identity,
   transcript, calendar, ai-providers, etc.)

After substantial work — and **before** you commit — update the relevant
knowledge files. The rule is the code change AND the doc change ship in
the same diff. If a future agent re-discovers something you already
learned, the docs failed.

### What requires a knowledge update?

| What you changed | Update |
|---|---|
| New service | `knowledge/architecture/services-catalog.md` |
| New repository or model | `knowledge/architecture/repository-catalog.md` + `data-model.md` |
| New migration | `knowledge/architecture/data-model.md` (migration list) |
| New view section | `knowledge/architecture/views-catalog.md` |
| Architectural choice with a tradeoff | new ADR in `knowledge/decisions/` |
| Modified pipeline (recording, attribution, cleanup, sync) | the matching deep-dive |
| New permission requirement | `knowledge/architecture/permissions-tcc.md` |
| New dependency | `knowledge/architecture/overview.md` (Tech Stack) |

If your commit changes architecture and your diff has no `knowledge/`
edit, that's a smell. Either the change isn't actually architectural, or
the docs are about to drift.

---

## Session Start Checklist

1. Read `knowledge/README.md` and skim the architecture catalog
2. Read `project-management/ACTIVE.md` — current sprint, blockers
3. Check `harness/handoffs/` for any in-progress session handoff
4. Identify which knowledge deep-dive(s) cover your task; read them
5. If context is already warm, skip to the task

---

## Repo Map

```
MeetingManager/          Swift source
  App/                   AppState (@Observable @MainActor singleton — the spine)
  Models/                Codable + GRDB record structs (one per table)
  Database/              GRDB repositories (one per logical entity)
  Services/              All non-UI logic
    AI/                  ClaudeService, OllamaService, SummaryGenerator,
                         TranscriptCleanupService, ActionItemExtractor,
                         RecipeEngine, MeetingChatService, etc.
    Audio/               AudioCaptureService, MicrophoneCapture, SystemAudioTap
    Calendar/            GoogleCalendarService, AppleCalendarService,
                         CalendarSyncManager, GoogleAuthManager
    Context/             RelevantMeetingService (related-meeting retrieval)
    Export/              Markdown / PDF / share sheet
    Integrations/        RemindersService
    KnowledgeBase/       KnowledgeBaseService, KBWriteBackService
    Meeting/             MeetingSeriesService (recurring-meeting key)
    Notifications/       NotificationService, NotificationActions
    Onboarding/          OnboardingManager
    Prep/                MeetingPrepService, DailyBriefService
    ProcessMonitor/      CallDetectionService, ParticipantDetectionService
    TaskQueue/           TaskQueueManager — persistent async work
    Transcription/       TranscriptionService, StreamingTranscriber,
                         SpeakerDiarizationService, SpeakerAttributionService,
                         VoiceProfileService, VocativeMiningService
    Updates/             UpdateService (Sparkle removed; manual updates only)
  Views/                 SwiftUI views, organised by area (Sidebar, Home,
                         MeetingDetail, LiveMeeting, People, Settings, etc.)
  Resources/             Info.plist, entitlements, assets
knowledge/               👈 SYSTEM OF RECORD — start here
  README.md                Index + how-to-use
  architecture/            How the app works (overview, services-catalog,
                           data-model, lifecycle, where-to-find, deep-dives
                           on each pipeline)
  decisions/               ADRs — why we chose X over Y
  features/                Feature-level implementation specs
docs/                    User-facing documentation (docs/user/) +
                         developer onboarding (docs/developer/)
harness/                 Agent operating infrastructure
  spec.md                  Active sprint spec
  spec-v2.md               Feature specs (still in flight)
  rubric.md                Scoring rubric for sprint evaluations
  context-management.md    When / how to reset context, write handoffs
  sprint-contracts/        Per-task contracts with success criteria
  evaluations/             Sprint eval reports (created by harness skill)
  handoffs/                Cross-session handoff files
project-management/      ACTIVE.md + (mostly empty) backlog
Scripts/                 push-update.sh, install-local.sh, generate-fixtures.sh
Tests/                   MeetingDetectionTests, MeetingManagerTests, fixtures
```

---

## Architecture Constraints — Read Before Writing Code

For each constraint, follow the `→` to the knowledge doc that explains
the WHY in detail.

### 1. TaskQueueManager (mandatory for post-meeting AI work)

All post-meeting AI/network work **must** go through `TaskQueueManager`.
No inline `Task<Void, Never>` in views for that path.

Exceptions allowed with `// EXEMPT: reason` comment at call site:
- conversational AI chat (user drives lifecycle)
- modal-scoped results persisted on completion
- instant reads (no network/AI)

→ `knowledge/architecture/task-queue-pattern.md`

### 2. Swift 6 / Concurrency

- All touched code must be actor-annotated correctly
- No `Task { @MainActor }` inside already-MainActor contexts
- `Sendable` conformance where required
- No force-unwraps without justification

### 3. No Scope Creep

Changes must be exactly scoped to the task. No speculative improvements,
no touching files outside the task's scope list. If you find something
worth fixing that's out of scope: spawn it as a separate task or leave a
comment.

### 4. Participant Detection

Calendar data is source 1 (always preferred). Screen detection
(`ParticipantDetectionService`) is source 2, fallback only.

→ `knowledge/features/participant-detection.md`

### 5. Local LLM

Use Ollama HTTP API at `http://localhost:11434`. Do not add MLX or
llama.cpp dependencies — irreconcilable SPM conflict with WhisperKit.

→ `knowledge/decisions/ADR-001-ollama-over-mlx-for-local-llm.md`

### 6. Release Pipeline

`Scripts/push-update.sh` requires clean working tree. Use `/git-update`
skill for guided releases. Sparkle has been removed; updates ship via
GitHub Releases manual download.

→ `knowledge/decisions/ADR-002-sparkle-release-hardening.md` (historical)

### 7. Speaker Identification Pipeline (v3.10)

5-signal stack with confidence scores. Don't bypass the gates (RSVP +
attendance) when adding new attribution signals. Don't tag voice profile
samples as `.manual` unless there's a SpeakerAlias row confirming the
rename. Don't overwrite existing speakerMap entries from a retry pass —
fill empties only.

→ `knowledge/architecture/speaker-id-pipeline.md`
→ `knowledge/decisions/ADR-003-person-identity-model.md`
→ `knowledge/decisions/ADR-004-rsvp-and-attendance-gates.md`

### 8. Transcript Cleanup [TURN N] Markers

The LLM never sees speaker names in transcript cleanup. The `[TURN N]`
sentinel pattern is mandatory. Fall back to deterministic stitch when
the AI returns the wrong number of blocks.

→ `knowledge/architecture/transcript-pipeline.md`
→ `knowledge/decisions/ADR-005-turn-marker-anti-hallucination.md`

### 9. Person Identity (UUID-anchored)

Voice profiles attach to `Person.id`, not name strings. Use
`Person.canonicalKey` for identity grouping; use `Meeting.identityKey`
for participant equality. Don't conflate them — different semantics.

→ `knowledge/architecture/person-identity.md`

### 10. Migrations

Append-only. Never edit a shipped migration. SQLite ALTER TABLE
limitations apply: no column drops, no `ON DELETE` actions on added
columns, NOT NULL needs a default. Backfill data in the migration body
when a new column changes downstream behavior.

→ `knowledge/architecture/data-model.md`

---

## How to Run a Task

1. Read the sprint contract in `harness/sprint-contracts/` (if applicable)
2. Read the relevant `knowledge/architecture/*.md` for the area you'll touch
3. Implement — scope strictly to success criteria
4. Run `swift build -c release` — must be clean before marking done
5. Update `knowledge/` to reflect anything new
6. Evaluation uses `harness/rubric.md` — ≥ 90/100 weighted to pass

---

## Context Budget

| Load | ~Tokens |
|------|---------|
| Knowledge README + overview + where-to-find | ~5K |
| One deep-dive (speaker-id, person-identity, etc.) | ~3K |
| 5 source files | ~5K |
| One sprint contract | ~3K |
| One task execution | ~20–40K |
| Safe session budget | ~80K |

If you need >5 source files to answer a question, use targeted `grep` /
`Read` — do not dump entire files. The knowledge catalogs (services,
repos, views) are designed to answer "where is X?" without loading code.

Context reset protocol: `harness/context-management.md`

---

## Tech Stack

- Swift 6, SwiftUI, macOS 14.4+
- GRDB (SQLite, in-process)
- WhisperKit + SpeakerKit (on-device transcription + diarization)
- Claude API (summarization, attribution, chat) — optional
- Ollama (local LLM) — optional
- EventKit (Apple Calendar, Reminders, Contacts)
- ScreenCaptureKit (system audio)
- SPM only — no CocoaPods, no Carthage
- No Sparkle (removed); updates via GitHub Releases manual download
- No analytics SDK, no telemetry

---

## TL;DR for Future Agents

1. **Use knowledge.** It's `knowledge/architecture/` — every catalog you
   need to find a file, every deep-dive you need to understand a
   pipeline, every ADR you need to know why we chose what we did.
2. **Update knowledge.** When you ship architectural changes, the
   commit must include the doc updates. Don't make the next agent
   re-discover what you just learned.
3. **Don't bypass the constraints above.** They're constraints because
   we tried the alternative and it broke.

# Meeting Manager — Agent Guide

Orientation for working in this codebase: where things live, the hard
architectural rules, and the tech stack. Read this before writing code.

---

## Repo Map

```
MeetingManager/          Swift source
  App/                   AppState (@Observable @MainActor singleton — the spine)
  Models/                Codable + GRDB record structs (one per table)
  Database/              GRDB repositories (one per logical entity)
  Services/              All non-UI logic
    AI/                  ClaudeService, OllamaService, AIBackendChoice,
                         SummaryGenerator, TranscriptCleanupService,
                         ActionItemExtractor, RecipeEngine,
                         MeetingChatService, etc.
    Analytics/           ParticipantAnalyticsService
    Audio/               AudioCaptureService, MicrophoneCapture, SystemAudioTap,
                         AudioBufferManager, AudioSessionManager
    Calendar/            GoogleCalendarService, AppleCalendarService,
                         CalendarSyncManager, GoogleAuthManager,
                         CalendarMeetingMatcher
    Context/             RelevantMeetingService (related-meeting retrieval)
    Export/              Markdown / PDF / share sheet
    Integrations/        RemindersService, ApolloService,
                         ApolloEnrichmentCoordinator
    KnowledgeBase/       KnowledgeBaseService, KBWriteBackService
    Meeting/             MeetingSeriesService (recurring-meeting key)
    Notes/               NoteDraftStore (sidecar note-draft autosave)
    Notifications/       NotificationService, NotificationActions
    Onboarding/          OnboardingManager
    Prep/                MeetingPrepService, DailyBriefService,
                         DailyBriefAIService, DailyBriefCache
    ProcessMonitor/      CallDetectionService, BrowserCallDetector,
                         CallAppRegistry, MeetingStateMachine,
                         ParticipantDetectionService
    TaskQueue/           TaskQueueManager — persistent async work
    Transcription/       TranscriptionService, AppleSpeechBatchTranscriber,
                         AppleSpeechEngine, TranscriptionConfiguration,
                         SpeakerDiarizationService, FluidAudioDiarizationService,
                         SpeakerEnrollmentService, SpeakerAttributionService,
                         SpeakerNamingEngine, VoiceProfileService,
                         VocativeMiningService
    Updates/             UpdateService (Sparkle removed; manual updates only)
    CompanyGroupingService.swift, MeetingRollupService.swift,
    ContactsImportService.swift, AppFileLogger.swift
    (top-level files in Services/)
  Views/                 SwiftUI views, organised by area (Sidebar, Home,
                         MeetingDetail, LiveMeeting, People, Settings, etc.)
  Resources/             Info.plist, entitlements, assets
docs/                    User-facing documentation (docs/user/) +
                         developer onboarding (docs/developer/)
Scripts/                 push-update.sh, install-local.sh, generate-fixtures.sh
Tests/                   MeetingDetectionTests, MeetingManagerTests, fixtures
```

---

## Architecture Constraints — Read Before Writing Code

### 1. TaskQueueManager (mandatory for post-meeting AI work)

All post-meeting AI/network work **must** go through `TaskQueueManager`.
No inline `Task<Void, Never>` in views for that path.

Exceptions allowed with `// EXEMPT: reason` comment at call site:
- conversational AI chat (user drives lifecycle)
- modal-scoped results persisted on completion
- instant reads (no network/AI)

### 2. Swift 6 / Concurrency

- All touched code must be actor-annotated correctly
- No `Task { @MainActor }` inside already-MainActor contexts
- `Sendable` conformance where required
- No force-unwraps without justification

### 3. No Scope Creep

Changes must be exactly scoped to the task. No speculative improvements,
no touching files outside the task's scope. If you find something
worth fixing that's out of scope: leave a comment or open an issue.

### 4. Participant Detection

Calendar data is source 1 (always preferred). Screen detection
(`ParticipantDetectionService`) is source 2, fallback only.

### 5. Local LLM

Use Ollama HTTP API at `http://localhost:11434`. Do not add MLX or
llama.cpp dependencies — irreconcilable SPM conflict with WhisperKit.

### 6. Release Pipeline

`Scripts/push-update.sh` requires a clean working tree. Sparkle has been
removed; updates ship via GitHub Releases manual download.

### 7. Speaker Identification Pipeline

5-signal stack with confidence scores. Don't bypass the gates (RSVP +
attendance) when adding new attribution signals. Don't tag voice profile
samples as `.manual` unless there's a SpeakerAlias row confirming the
rename. Don't overwrite existing speakerMap entries from a retry pass —
fill empties only.

### 8. Transcript Cleanup [TURN N] Markers

The LLM never sees speaker names in transcript cleanup. The `[TURN N]`
sentinel pattern is mandatory. Fall back to deterministic stitch when
the AI returns the wrong number of blocks.

### 9. Person Identity (UUID-anchored)

Voice profiles attach to `Person.id`, not name strings. Use
`Person.canonicalKey` for identity grouping; use `Meeting.identityKey`
for participant equality. Don't conflate them — different semantics.

### 10. Migrations

Append-only. Never edit a shipped migration. SQLite ALTER TABLE
limitations apply: no column drops, no `ON DELETE` actions on added
columns, NOT NULL needs a default. Backfill data in the migration body
when a new column changes downstream behavior.

---

## How to Run a Task

1. Make the change, scoped strictly to the task at hand.
2. Run `swift build -c release` — must be clean before marking done.
3. If you need >5 source files to answer a question, use targeted `grep` /
   `Read` — do not dump entire files.

---

## Tech Stack

- Swift 6, SwiftUI, macOS 14.4+
- GRDB (SQLite, in-process)
- WhisperKit + SpeakerKit (on-device transcription + diarization)
- FluidAudio 0.14.7 (alternate diarization + speaker enrollment, behind
  `useFluidAudioDiarization`)
- Claude API (summarization, attribution, chat) — optional
- Ollama (local LLM) — optional
- EventKit (Apple Calendar, Reminders, Contacts)
- ScreenCaptureKit (system audio)
- SPM only — no CocoaPods, no Carthage
- No Sparkle (removed); updates via GitHub Releases manual download
- No analytics SDK, no telemetry

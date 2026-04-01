# Architecture

Meeting Manager is a native macOS SwiftUI application built on Swift 5.9+ with a single observable app state, GRDB for SQLite persistence, and a pipeline-based audio/transcription/summarization flow.

---

## High-Level Data Flow

```
User starts recording
        │
        ▼
AudioCaptureService         ← captures mic and/or system audio
        │
        ▼
AudioBufferManager          ← buffers raw PCM, feeds chunks downstream
        │
        ▼
StreamingTranscriber        ← WhisperKit inference, emits TranscriptSegment
        │
        ▼
TranscriptRepository        ← writes segments to SQLite (off main thread)
        │
        ▼
SummaryGenerator            ← called after recording stops
        │
    ┌───┴───┐
    ▼       ▼
ClaudeService  OllamaService   ← selected by AppSettings.useLocalLLM
    │
    ▼
SummaryRepository           ← stores MeetingSummary to SQLite
```

---

## App State

`AppState` is the single source of truth — one `@Observable @MainActor` class held at the SwiftUI environment root.

```swift
@Observable @MainActor
final class AppState {
    var settings: AppSettings          // persisted to DB
    var upcomingMeetings: [Meeting]
    var pastMeetings: [Meeting]
    var selectedMeetingId: UUID?
    var activeMeeting: Meeting?
    var isRecording: Bool
    var detectedCallApp: String?

    // Services (injected at init, never recreated)
    let database: AppDatabase
    let meetingRepository: MeetingRepository
    let ollamaService: OllamaService
    let ollamaInstaller: OllamaInstaller
    let audioCaptureService: AudioCaptureService
    let transcriptionService: TranscriptionService
    // ...
}
```

Views access AppState via `@Environment(AppState.self)`. Services are injected once at startup — never created inside views.

---

## Directory Structure

```
MeetingManager/
├── App/
│   ├── AppState.swift          — single source of truth
│   ├── AppDelegate.swift       — notifications, menu bar
│   └── MeetingManagerApp.swift — SwiftUI App entry point
│
├── Models/
│   ├── Meeting.swift           — GRDB Record, MeetingStatus enum
│   ├── Transcript.swift        — TranscriptSegment
│   ├── MeetingSummary.swift    — summary + action items
│   ├── AppSettings.swift       — persisted user preferences
│   └── ActionItem.swift
│
├── Database/
│   ├── AppDatabase.swift       — DatabaseQueue setup
│   ├── Migrations.swift        — additive schema migrations (v1–v9)
│   └── Repositories/           — MeetingRepository, TranscriptRepository, etc.
│
├── Services/
│   ├── AI/
│   │   ├── ClaudeService.swift         — Anthropic API client
│   │   ├── OllamaService.swift         — Ollama HTTP client
│   │   ├── OllamaInstaller.swift       — download/install/launch/pull flow
│   │   └── SummaryGenerator.swift      — orchestrates transcripts → summary
│   ├── Audio/
│   │   ├── AudioCaptureService.swift
│   │   └── AudioBufferManager.swift
│   ├── Calendar/
│   │   ├── GoogleCalendarService.swift
│   │   └── GoogleAuthManager.swift
│   ├── Transcription/
│   │   ├── StreamingTranscriber.swift  — WhisperKit wrapper
│   │   └── AppleSpeechTranscriber.swift
│   └── Updates/
│       └── UpdateService.swift         — Sparkle wrapper + cache-clearing delegate
│
└── Views/
    ├── Sidebar/
    │   ├── SidebarView.swift           — Scheduled + History sections
    │   └── MeetingListRow.swift        — row with contextual badges
    ├── MeetingDetail/
    │   ├── LiveMeetingView.swift       — recording UI
    │   ├── SummaryView.swift           — summary + regenerate
    │   └── TranscriptView.swift        — scrollable transcript
    └── Settings/
        ├── SettingsView.swift          — TabView container
        ├── GeneralSettingsView.swift
        ├── AudioSettingsView.swift
        ├── TranscriptionSettingsView.swift
        ├── ClaudeSettingsView.swift
        ├── OnDeviceSettingsView.swift  — Ollama install flow UI
        ├── PromptConfigView.swift
        └── UpdateSettingsView.swift
```

---

## Database

GRDB manages a single SQLite file at `~/Library/Application Support/MeetingManager/db.sqlite`.

**Schema overview:**

| Table | Purpose |
|-------|---------|
| `meeting` | Core meeting record (title, dates, status, audioFilePath) |
| `transcript` | Individual speech segments with timing and speaker label |
| `meetingSummary` | AI-generated summaries (linked to meeting) |
| `actionItem` | Extracted action items from summaries |
| `meetingNote` | User-written notes on meetings |
| `appSettings` | Single-row user preferences |
| `chatMessage` | Chat history per meeting (if applicable) |

All migrations are additive — columns are added, never dropped or renamed. The current schema is at v11 (v11-performance-indexes).

All DB writes happen off the main thread using `dbQueue.write { ... }` in async contexts. Never write to the DB on the main actor.

All repository queries use `LIMIT` clauses (50–200 depending on table) with offset support for pagination.

---

## Concurrency Model

- `@MainActor` on `AppState`, `AudioCaptureService`, and UI-facing services — UI-touching state lives on the main actor
- DB operations run on GRDB's internal dispatch queue
- `WhisperEngine` is a Swift `actor` — eliminates data races on the internal WhisperKit instance without manual locking
- `SystemAudioTap` and `MicrophoneCapture` use `NSLock` to protect shared state accessed from audio callbacks
- Audio capture callbacks arrive on a dedicated audio thread; shared counters use lock-protected nonisolated methods
- `Task { }` blocks in SwiftUI views are implicitly main-actor isolated and are cancelled in `.onDisappear`
- `StreamingTranscriber` batches multiple property updates into a single `MainActor.run {}` block to reduce render cycles

---

## SummaryGenerator Closure Pattern

`SummaryGenerator` accepts a `textGenerator` closure rather than a concrete service, enabling clean routing between Claude and Ollama:

```swift
func generateSummary(
    for meeting: Meeting,
    textGenerator: (String, String) async throws -> String,
    modelUsed: String,
    ...
) async throws -> MeetingSummary
```

The caller constructs the closure based on `AppSettings.useLocalLLM`:

```swift
if settings.useLocalLLM {
    textGenerator = { sys, usr in
        try await ollamaService.generate(systemPrompt: sys, userPrompt: usr, model: ollamaModel)
    }
} else {
    textGenerator = { sys, usr in
        try await claudeService.sendMessage(systemPrompt: sys, userPrompt: usr, model: claudeModel)
    }
}
```

---

## Key Architectural Decisions

- **[ADR-001](../../knowledge/decisions/ADR-001-ollama-over-mlx-for-local-llm.md):** Ollama API over embedded MLX — avoids unresolvable SPM dependency conflict with WhisperKit
- **No sandbox** — app requires microphone, filesystem access, and the ability to install/launch other apps (Ollama)
- **SwiftPM only** — no Xcode project file; build with `swift build`
- **Retry with backoff** — all HTTP clients (Claude, Google Calendar, Google Auth) use exponential backoff + jitter, skipping retries on 400/401/403
- **CircularBuffer for audio** — fixed-capacity ring buffer prevents unbounded memory growth during long recordings
- **Memory pressure monitoring** — `DispatchSource.makeMemoryPressureSource` triggers buffer flush on warning and auto-stop on critical

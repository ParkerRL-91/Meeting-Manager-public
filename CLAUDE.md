# Meeting Manager — Agent Guide

This file is a **table of contents**, not a wiki. Read it to orient yourself, then follow the pointers.

---

## Session Start Checklist

1. Read `project-management/ACTIVE.md` — current sprint, blockers, up-next queue
2. Check `harness/handoffs/` for any in-progress session handoff
3. If context is already warm, skip to the task

---

## Repo Map

```
MeetingManager/          Swift source (App, Models, Services, Views, Utilities)
  Services/
    AI/                  Claude API, OllamaService
    Audio/               WhisperKit transcription pipeline
    Calendar/            CalendarSyncManager (Google Calendar)
    TaskQueue/           TaskQueueManager — ALL async AI/network work routes here
    ProcessMonitor/      ParticipantDetectionService (CGWindowList screen fallback)
    Transcription/       Transcription service wrappers
    Updates/             Sparkle auto-update
knowledge/               Architectural decisions and feature specs (system of record)
  architecture/          Deep dives on core patterns
  decisions/             ADRs — why decisions were made
  features/              Feature-level implementation specs
harness/                 Agent operating infrastructure
  spec.md                Current sprint spec (granola-parity)
  spec-v2.md             Feature specs for meeting reopen, speaker ID, home CTAs
  rubric.md              Scoring rubric (≥90/100 to pass a wave)
  context-management.md  When/how to reset context and write handoffs
  sprint-contracts/      Per-task contracts with success criteria
  evaluations/           Historical eval results
  handoffs/              Cross-session handoff files
docs/                    Distribution, developer setup, user-facing docs
project-management/      ACTIVE.md + backlog task files
Scripts/                 push-update.sh (release pipeline)
```

---

## Architecture Constraints — Read Before Writing Code

### 1. TaskQueueManager (mandatory)
All user-visible AI/network work **must** go through `TaskQueueManager`. No inline `Task<Void, Never>` in views for AI or network ops.
→ Full pattern: `knowledge/architecture/task-queue-pattern.md`

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
Changes must be exactly scoped to the task. No speculative improvements, no touching files outside the task's scope list.

### 4. Participant Detection
Calendar data is source 1 (always preferred). Screen detection (`ParticipantDetectionService`) is source 2, fallback only.
→ `knowledge/features/participant-detection.md`

### 5. Local LLM
Use Ollama HTTP API at `http://localhost:11434`. Do not add MLX or llama.cpp dependencies — irreconcilable SPM conflict with WhisperKit.
→ `knowledge/decisions/ADR-001-ollama-over-mlx-for-local-llm.md`

### 6. Release Pipeline
`Scripts/push-update.sh` requires clean working tree + `NOTARIZE=1`. Use `/git-update` skill for guided releases.
→ `knowledge/decisions/ADR-002-sparkle-release-hardening.md`

---

## How to Run a Task

1. Read the sprint contract in `harness/sprint-contracts/`
2. Implement — scope strictly to success criteria
3. Run `swift build -c release` — must be clean before marking done
4. Evaluation uses `harness/rubric.md` — ≥ 90/100 weighted to pass

---

## Context Budget

| Load | ~Tokens |
|------|---------|
| 5 source files | ~5K |
| One sprint contract | ~3K |
| One task execution | ~20–40K |
| Safe session budget | ~80K |

If you need >5 source files to answer a question, use targeted `grep`/`Read` — do not dump entire files.

Context reset protocol: `harness/context-management.md`

---

## Tech Stack

- Swift 6, SwiftUI, macOS 14+
- GRDB (SQLite)
- WhisperKit (on-device transcription)
- Claude API (summarization, AI chat)
- Ollama (optional local LLM)
- Sparkle (auto-update)
- SPM only — no CocoaPods, no Carthage

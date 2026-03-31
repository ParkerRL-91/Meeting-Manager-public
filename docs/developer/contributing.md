# Contributing

## Development Workflow

This project uses a structured task-based workflow managed through `project-management/`. Every code change traces to a task.

### Starting Work

1. Check `project-management/ACTIVE.md` for current sprint and blockers
2. Pick a task from "Up Next" or create a new one in `project-management/backlog/`
3. Move it to "Current Sprint" in ACTIVE.md when starting

### Task File Format

```markdown
---
title: Feature Name
id: TASK-{N}
project: PRJ-{N}
status: in-progress   # ready | in-progress | done
priority: P1          # P0 | P1 | P2 | P3
---

## User Stories
## Outcomes
## Success Metrics
## Implementation Plan
## Files Changed
## Status Log
## Takeaways
```

### Commit Format

```
TASK-XXX: short imperative description

Longer explanation if needed.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
```

---

## Code Standards

### Architecture
- Services live in `AppState`, never instantiated inside views
- Views are thin — no business logic, no direct DB access
- `@MainActor` on all UI-touching code
- No force-unwraps on optionals that could be nil at runtime

### Database
- All writes off the main thread: `await dbQueue.write { ... }`
- Migrations are additive only — add columns, never drop/rename
- Use GRDB's query interface, not raw SQL string interpolation

### AI Integration
- API keys read from Keychain, never logged or hardcoded
- Prompts send transcripts only — never raw audio or binary data
- Always handle: rate limits, network errors, malformed responses

### Concurrency
- `async/await` throughout — no completion handlers or Combine except where required (Sparkle)
- Audio capture bridges to async via `withCheckedContinuation`
- Never block the main thread with semaphores or synchronous I/O

---

## Adding a New Settings Field

1. Add the property to `AppSettings.swift` with a default value and a `Columns` case
2. Add a migration in `Migrations.swift` with a new version string
3. Update any repository query that reads `AppSettings` to include the new column
4. Add a UI row in the appropriate settings view

---

## Adding a New AI Provider

`SummaryGenerator` accepts a `textGenerator: (String, String) async throws -> String` closure. To add a new provider:

1. Create `Services/AI/NewProviderService.swift` with a `generate(systemPrompt:userPrompt:)` method
2. Add it to `AppState`
3. In `SummaryView.regenerateSummary()`, add a routing case that constructs the closure
4. Add a settings toggle/picker if the user needs to configure it

---

## Project Structure

```
project-management/
├── ACTIVE.md              — current sprint, blockers, recently completed
├── projects/PRJ-*.md      — project-level objectives and task tables
└── backlog/TASK-*.md      — individual task files

knowledge/
├── architecture/          — system design docs
├── decisions/             — ADRs (architecture decision records)
├── features/              — how specific features work
├── integrations/          — third-party API behavior
└── data-model/            — schema and migration docs
```

The `knowledge/` directory is the living technical reference for this codebase. Update it whenever you discover a non-obvious behavior, make an architectural decision, or change how a feature works.

# Contributing

## Development Workflow

1. Read `docs/developer/architecture.md` for the area you'll touch.
2. Make the change, scoped strictly to the task at hand.
3. Run `swift build -c release` — it must be clean before you open a PR.

### Commit Format

```
short imperative description

Longer explanation if needed.
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
- `async/await` throughout — no completion handlers or Combine in new code
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

# Testing Guide

This document describes the automated test suite for Meeting Manager, how to run
it, what it guarantees, and how to extend it. The suite is the executable half of
the project's hardening strategy: the knowledge base and ADRs describe the
intended invariants, and these tests enforce them so a future change cannot
silently break them.

---

## Toolchain requirement (read this first)

The suite is written with **XCTest**, which ships with **full Xcode** — not with
the standalone Command Line Tools (CLT). On a CLT-only machine
(`xcode-select -p` → `/Library/Developer/CommandLineTools`), `swift test` fails
with `no such module 'XCTest'`, and the suite cannot be compiled or run locally.
This affects every XCTest target equally, old and new.

To run the suite you need one of:

- **Full Xcode** installed and selected:
  `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`, then
  `swift test`.
- **CI** — the canonical place the suite runs. `.github/workflows/tests.yml`
  executes it on a GitHub `macos-14` runner (Xcode preinstalled) on every push
  and pull request. If you cannot run XCTest locally, push the branch and let CI
  report.

The app itself builds fine under CLT (`swift build -c release`) — only the
XCTest *test* targets require Xcode.

---

## Running the suite

```bash
# Everything (requires full Xcode)
swift test

# Just the enterprise unit suite (pure-logic + GRDB, fully hermetic)
swift test --filter MeetingManagerTests

# A single test class
swift test --filter MeetingManagerTests.DailyBriefVerifierTests

# Process-simulation detection tests (no real Zoom needed)
swift test --filter MeetingDetectionTests
```

The `MeetingManagerTests` target is hermetic: every database test uses an
in-memory GRDB instance via `TestDatabase.create()` (→ `AppDatabase.empty()`),
and no test performs network, audio, or filesystem I/O. It is safe to run
repeatedly and in parallel.

---

## Layout

```
Tests/
├── MeetingManagerTests/                     ← the unit suite (XCTest)
│   ├── TestHelpers.swift                     ← TestDatabase + SampleData factory
│   ├── RegressionTests.swift                 ← one test per previously-fixed bug
│   ├── Models/                               ← Codable / model-logic tests
│   ├── Database/                             ← GRDB repository + migration tests
│   └── Services/                             ← service / pure-function tests
├── MeetingDetectionTests/                    ← meeting start/stop detection
├── PromptOptimization/                       ← prompt-eval harness (executable)
├── Scripts/                                  ← WER measurement, fixture generation
└── Fixtures/                                 ← synthetic audio + ground-truth text
```

All test files share two helpers and must not redefine them:

- `TestDatabase.create()` — a fresh in-memory `AppDatabase` with all migrations
  applied.
- `SampleData` — a factory of model fixtures (`makeMeeting`, `makeTranscript`,
  `makeMeetingSummary`, …). Note `makeMeeting(audioFilePaths: [String] = [])` —
  the model stores a plural array; `Meeting.audioFilePath` is a computed getter.

---

## Coverage map

The hardening pass added ~340 test methods across seven domains, each anchored to
the invariant it protects.

| Area | File | Guards |
|---|---|---|
| Daily-brief KB verifier | `Services/DailyBriefVerifierTests.swift` | ADR-008 anti-hallucination: a `Background:` bullet survives only if its quoted span is a verbatim substring of the cited chunk (≥8 normalized chars) AND the chunk belongs to the meeting it sits under. Covers all eight adversarial cases (valid kept, unknown id dropped, paraphrase dropped, misattribution dropped, correct kept, bare main-line marker stripped, smart quotes accepted, too-short quote dropped) plus boundaries. |
| Transcript cleanup | `Services/TranscriptCleanupTests.swift` | ADR-005 `[TURN N]` stitching, Markdown rendering (`**Name** _[Time]_`), and the block-count fallback (`parseTurnBodies` count mismatch → discard AI output, keep deterministic stitch). |
| Identity & series keys | `Services/IdentityKeysTests.swift` | ADR-003: `VocativeMiningService.canonicalKey` normalization, vocative detection (no substring false-positives), and `MeetingSeriesService.seriesKey` stability across recurrence/date/case noise. |
| KB retrieval gate + cache | `Services/KnowledgeRetrievalTests.swift` | ADR-008 retrieval gate (`distinctiveTerms`, stopword filter, ≥2-term overlap) and `DailyBriefCache.signature` content-hash invalidation (a same-length KB edit regenerates the brief). |
| Auto-title | `Services/TitleGenerationTests.swift` | ADR-009: `sanitize` quote/prefix/punctuation stripping and the deterministic ≤8-word clamp; `extractFromSummary` first-sentence extraction. |
| Models | `Models/ModelsHardeningTests.swift` | `Meeting` duration/effectiveDate/attendee parsing/JSON-backed dictionaries/`isReopenable`, Codable round-trips, `AppSettings` defaults + forward-compatible decoding, `MeetingStatus` rawValue stability (persisted — must not drift). |
| Migrations & schema | `Database/MigrationsIntegrityTests.swift` | All 41 migrations apply; every expected table/column exists; builtin recipes seed exactly once; cascade deletes fire (GRDB enables `PRAGMA foreign_keys = ON` by default, so the configured DB enforces the declared `onDelete: .cascade`). |

These join the pre-existing repository, model, and service tests and the
`RegressionTests` (one test per QA-round bug).

---

## Writing a new test

1. Put it in the matching subfolder (`Models/`, `Database/`, `Services/`).
2. `import XCTest` + `@testable import MeetingManager`. Add `import GRDB` for
   database tests.
3. Reuse `TestDatabase.create()` and `SampleData`. Do not redefine them.
4. If the type under test is `@MainActor` (e.g. `TitleGenerationService`,
   `DailyBriefAIService`, `KnowledgeBaseService`), annotate the test class
   `@MainActor`.
5. Database tests are `async throws` and mirror `MeetingRepositoryTests`.
6. Only `internal`/`public` symbols are reachable through `@testable`. `private`
   members are tested through their public callers. When a critical pure
   function must be tested directly, widen it to `internal` (not `private`) and
   note why — e.g. `TitleGenerationService.sanitize`.
7. Prefer asserting the implementation's *actual* behavior. If a test documents a
   genuine bug, mark it `// POTENTIAL BUG:` and explain, rather than weakening the
   assertion.

---

## Notes from the hardening pass

- **Stale assertion fixed.** `AppSettingsTests.testDefaultWhisperModel` asserted
  the legacy `"tiny-en"`; the default moved to Large v3 Turbo in migration v17.
  It now asserts `WhisperModel.largev3turbo.rawValue` (the source of truth).
- **Test helper repaired.** `SampleData.makeMeeting` still passed the removed
  `audioFilePath:` init parameter after the model migrated to `audioFilePaths:
  [String]`; the whole target had not compiled since. Fixed to the plural array.
- **Foreign-key enforcement (not a bug).** GRDB sets
  `Configuration.foreignKeysEnabled = true` and runs `PRAGMA foreign_keys = ON`
  on every connection, so the app's `DatabasePool`/`DatabaseQueue` enforce the
  declared cascades. The cascade test proves this through a default
  `AppDatabase.empty()` connection with no manual pragma.

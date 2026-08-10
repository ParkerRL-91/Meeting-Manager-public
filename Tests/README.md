# Meeting Manager Tests

## Unit Test Suite (XCTest)

`MeetingManagerTests` is the hermetic unit suite — pure-logic and GRDB tests
(in-memory DB, no network/audio). It anchors the project's invariants:
anti-hallucination verifiers (ADR-005, ADR-008), identity/series keys (ADR-003),
auto-title (ADR-009), model Codable/round-trips, and migration/schema integrity.

```bash
swift test --filter MeetingManagerTests
```

**Requires full Xcode.** XCTest ships with Xcode, not the Command Line Tools, so
on a CLT-only machine `swift test` fails with `no such module 'XCTest'`. Either
install/select Xcode (`sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`)
or rely on CI — `.github/workflows/tests.yml` runs the suite on a macOS+Xcode
runner on every push and PR.

See **`docs/developer/testing.md`** for the full coverage map and conventions.

## Test Infrastructure

### Synthetic Audio Fixtures
Test transcription quality without talking into a microphone.

**Generate fixtures (run once):**
```bash
bash Tests/Scripts/generate_fixtures.sh
```

Creates 5 conversation fixtures in `Tests/Fixtures/` using macOS `say`.
Each fixture = `.aiff` audio + `.txt` ground truth transcript.

**Run WER evaluation:**
```bash
python3 Tests/Scripts/measure_wer.py \
  --fixtures Tests/Fixtures \
  --output .build/wer/latest-wer.json
```

Results in `.build/wer/latest-wer.json`. Exit code 0 = all gates pass.

**Optional: faster repeated runs**
Compile the transcription helper:
```bash
swift build --product transcribe-audio
python3 Tests/Scripts/measure_wer.py \
  --fixtures Tests/Fixtures \
  --build-dir .build/debug \
  --output .build/wer/latest-wer.json
```

### Detection Tests (Swift test target)
```bash
swift test --filter MeetingDetectionTests
```

Tests meeting start/stop detection using process simulation — no real Zoom needed.

## Pass Thresholds

| Metric | Threshold |
|--------|-----------|
| Word Error Rate | ≤ 15% |
| Hallucinated words | 0 |
| Repeated phrases | 0 |
| Audio coverage | ≥ 50% of expected words |

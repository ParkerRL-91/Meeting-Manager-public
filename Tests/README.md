# Meeting Manager Tests

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
  --output harness/evaluations/latest-wer.json
```

Results in `harness/evaluations/latest-wer.json`. Exit code 0 = all gates pass.

**Optional: faster repeated runs**
Compile the transcription helper:
```bash
swift build --product transcribe-audio
python3 Tests/Scripts/measure_wer.py \
  --fixtures Tests/Fixtures \
  --build-dir .build/debug \
  --output harness/evaluations/latest-wer.json
```

### Detection Tests (Swift test target)
```bash
swift test --filter MeetingDetectionTests
```

Tests meeting start/stop detection using process simulation — no real Zoom needed.

## Sprint Contracts

| Sprint | Contract | Status |
|--------|----------|--------|
| 1 | harness/sprint-contracts/sprint-1-transcription.md | Active |
| 2 | harness/sprint-contracts/sprint-2-detection.md | Not started |

## Pass Thresholds (Sprint 1)

| Metric | Threshold |
|--------|-----------|
| Word Error Rate | ≤ 15% |
| Hallucinated words | 0 |
| Repeated phrases | 0 |
| Audio coverage | ≥ 50% of expected words |

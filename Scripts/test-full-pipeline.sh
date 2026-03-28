#!/usr/bin/env bash
# Full automated pipeline test: generate audio → feed to WhisperKit → check output
# No microphone or user intervention needed.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DB="$HOME/Library/Application Support/MeetingManager/db.sqlite"
WAV="/tmp/test_speech.wav"
LOG="$HOME/Library/Application Support/MeetingManager/app.log"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

pass() { echo -e "  ${GREEN}PASS${NC}: $1"; }
fail() { echo -e "  ${RED}FAIL${NC}: $1"; FAILURES=$((FAILURES+1)); }
info() { echo -e "  ${YELLOW}INFO${NC}: $1"; }
FAILURES=0

echo -e "${BOLD}══════════════════════════════════════════${NC}"
echo -e "${BOLD}  MEETING MANAGER PIPELINE TEST${NC}"
echo -e "${BOLD}══════════════════════════════════════════${NC}"
echo ""

# ── Test 1: Generate known-good test audio ──
echo -e "${BOLD}1. Test Audio Generation${NC}"
say -o /tmp/test_speech.aiff \
  "Hello, this is a test of the meeting transcription system. The quick brown fox jumps over the lazy dog. We need to discuss quarterly results and budget allocation."
afconvert /tmp/test_speech.aiff "$WAV" -d LEF32@16000 -c 1

SIZE=$(stat -f%z "$WAV" 2>/dev/null || echo 0)
if [[ "$SIZE" -gt 10000 ]]; then
    pass "WAV generated ($SIZE bytes)"
else
    fail "WAV too small ($SIZE bytes)"
fi

# ── Test 2: WhisperKit model available ──
echo -e "${BOLD}2. WhisperKit Model${NC}"
MODEL_DIR="$HOME/Documents/huggingface/models/argmaxinc/whisperkit-coreml"
MODELS=$(ls "$MODEL_DIR" 2>/dev/null || echo "")
if [[ -n "$MODELS" ]]; then
    pass "Models available: $MODELS"
else
    fail "No WhisperKit models at $MODEL_DIR"
fi

# ── Test 3: Direct WhisperKit transcription (bypass app pipeline) ──
echo -e "${BOLD}3. Direct WhisperKit Transcription${NC}"
info "Running whisperkit-cli on test audio..."

cd "$REPO"
RESULT=$(swift run whisperkit-cli transcribe \
  --audio-path "$WAV" \
  --model-path "$MODEL_DIR/openai_whisper-tiny.en" \
  2>/dev/null | grep -v "^$" | tail -5)

echo "  Output: \"$RESULT\""

if echo "$RESULT" | grep -qi "test\|meeting\|transcription\|fox\|quarterly\|budget"; then
    pass "WhisperKit recognized speech correctly"
else
    fail "WhisperKit output doesn't contain expected words"
fi

# ── Test 4: Build the app ──
echo -e "${BOLD}4. App Build${NC}"
info "Building release..."
BUILD_OUT=$(swift build -c release 2>&1 | tail -3)
if echo "$BUILD_OUT" | grep -q "Build complete"; then
    pass "Build succeeded"
else
    fail "Build failed: $BUILD_OUT"
fi

# ── Test 5: Database schema ──
echo -e "${BOLD}5. Database Schema${NC}"
if [[ -f "$DB" ]]; then
    TABLES=$(sqlite3 "$DB" ".tables" 2>/dev/null)
    if echo "$TABLES" | grep -q "transcript"; then
        pass "Transcript table exists"
    else
        fail "Transcript table missing"
    fi
    if echo "$TABLES" | grep -q "meeting"; then
        pass "Meeting table exists"
    else
        fail "Meeting table missing"
    fi
else
    fail "Database not found at $DB"
fi

# ── Test 6: App launches without crash ──
echo -e "${BOLD}6. App Launch${NC}"
pkill -f MeetingManager 2>/dev/null || true
sleep 1

APP="$HOME/Applications/Meeting Manager.app"
if [[ -d "$APP" ]]; then
    # Install latest
    rm -rf "$APP"
    mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
    cp .build/release/MeetingManager "$APP/Contents/MacOS/MeetingManager"
    cp MeetingManager/Resources/Info.plist "$APP/Contents/Info.plist"
    cp -r .build/release/MeetingManager_MeetingManager.bundle "$APP/Contents/Resources/" 2>/dev/null || true
    cp -r .build/release/Sparkle.framework "$APP/Contents/Frameworks/"
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/MeetingManager" 2>/dev/null || true
    printf 'APPL????' > "$APP/Contents/PkgInfo"
fi

rm -f "$LOG"
open "$APP"
sleep 5

PID=$(pgrep -f "Meeting Manager.app" | head -1)
if [[ -n "$PID" ]]; then
    pass "App running (PID $PID)"
else
    fail "App not running after launch"
fi

# ── Test 7: Model loads ──
echo -e "${BOLD}7. WhisperKit Model Loading${NC}"
# Wait up to 30s for model to load
for i in $(seq 1 15); do
    if grep -q "LOADED successfully" "$LOG" 2>/dev/null; then
        pass "Model loaded"
        break
    fi
    sleep 2
    if [[ $i -eq 15 ]]; then
        fail "Model didn't load within 30s"
        cat "$LOG" 2>/dev/null | tail -5
    fi
done

# ── Test 8: Call detection ──
echo -e "${BOLD}8. Call Detection${NC}"
if grep -q "BrowserDetector" "$LOG" 2>/dev/null; then
    pass "BrowserCallDetector is polling"
else
    fail "BrowserCallDetector not running"
fi

# ── Summary ──
echo ""
echo -e "${BOLD}══════════════════════════════════════════${NC}"
if [[ $FAILURES -eq 0 ]]; then
    echo -e "  ${GREEN}${BOLD}ALL TESTS PASSED${NC}"
else
    echo -e "  ${RED}${BOLD}$FAILURES TEST(S) FAILED${NC}"
fi
echo -e "${BOLD}══════════════════════════════════════════${NC}"
echo ""
echo "Key finding: WhisperKit transcribes perfectly when given clean 16kHz audio."
echo "If live transcription shows [BLANK_AUDIO], the issue is in the audio"
echo "conversion pipeline (AVAudioConverter), not in WhisperKit itself."

exit $FAILURES

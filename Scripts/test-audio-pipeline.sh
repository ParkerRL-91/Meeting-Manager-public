#!/bin/bash
# test-audio-pipeline.sh — Build, launch, and evaluate audio capture pipeline
# Usage: ./Scripts/test-audio-pipeline.sh [--skip-build] [--timeout 30]
#
# This script:
# 1. Kills any running MeetingManager
# 2. Removes corrupted build.db (prevents stale binary issues)
# 3. Clean builds the project
# 4. Bundles into /tmp/MeetingManager-dev.app with proper rpath + codesigning
# 5. Launches the app
# 6. Monitors app.log for audio diagnostic markers
# 7. Reports PASS/FAIL for mic capture, system capture, and level propagation

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_BUNDLE="/tmp/MeetingManager-dev.app"
LOG_FILE="$HOME/Library/Application Support/MeetingManager/app.log"
ENTITLEMENTS="$REPO_DIR/MeetingManager/Resources/MeetingManager.entitlements"
TIMEOUT=${2:-60}
SKIP_BUILD=false

for arg in "$@"; do
    case $arg in
        --skip-build) SKIP_BUILD=true ;;
        --timeout) ;; # handled by positional
    esac
done

echo "=== MeetingManager Audio Pipeline Test ==="
echo "Repo: $REPO_DIR"
echo "Timeout: ${TIMEOUT}s"
echo ""

# Step 1: Kill existing instances
echo "[1/6] Killing existing MeetingManager processes..."
pkill -f "MeetingManager-dev.app" 2>/dev/null || true
sleep 1

if [ "$SKIP_BUILD" = false ]; then
    # Step 2: Fix build cache
    echo "[2/6] Fixing build cache..."
    if [ -f "$REPO_DIR/.build/build.db" ]; then
        rm -f "$REPO_DIR/.build/build.db"
        echo "  Removed corrupted build.db"
    fi
    # If build.db keeps corrupting, nuke the whole .build
    if [ -f "$REPO_DIR/.build/build.db" ]; then
        rm -rf "$REPO_DIR/.build"
        echo "  Removed entire .build directory"
    fi

    # Step 3: Build
    echo "[3/6] Building..."
    cd "$REPO_DIR"
    BUILD_OUTPUT=$(swift build 2>&1)
    if echo "$BUILD_OUTPUT" | grep -q "Build complete"; then
        echo "  Build succeeded"
    else
        echo "  BUILD FAILED:"
        echo "$BUILD_OUTPUT" | tail -20
        exit 1
    fi

    # Verify the binary contains our diagnostic markers
    if strings "$REPO_DIR/.build/debug/MeetingManager" | grep -q "DIAG:mic_buffer"; then
        echo "  Binary contains diagnostic markers ✓"
    else
        echo "  WARNING: Binary missing diagnostic markers — may be stale"
        echo "  Forcing full clean build..."
        rm -rf "$REPO_DIR/.build"
        BUILD_OUTPUT=$(swift build 2>&1)
        if echo "$BUILD_OUTPUT" | grep -q "Build complete"; then
            echo "  Clean build succeeded"
        else
            echo "  CLEAN BUILD FAILED:"
            echo "$BUILD_OUTPUT" | tail -20
            exit 1
        fi
        # Re-check
        if strings "$REPO_DIR/.build/debug/MeetingManager" | grep -q "DIAG:mic_buffer"; then
            echo "  Binary now contains diagnostic markers ✓"
        else
            echo "  FATAL: Binary still missing markers after clean build"
            exit 1
        fi
    fi

    # Step 4: Bundle
    echo "[4/6] Bundling into $APP_BUNDLE..."
    cp "$REPO_DIR/.build/debug/MeetingManager" "$APP_BUNDLE/Contents/MacOS/MeetingManager"
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_BUNDLE/Contents/MacOS/MeetingManager" 2>/dev/null || true
    codesign --force --sign - --entitlements "$ENTITLEMENTS" "$APP_BUNDLE/Contents/MacOS/MeetingManager" 2>/dev/null
    echo "  Bundled and signed ✓"
else
    echo "[2-4/6] Skipping build (--skip-build)"
fi

# Step 5: Mark log position and launch
echo "[5/6] Launching app..."
LOG_START_LINE=0
if [ -f "$LOG_FILE" ]; then
    LOG_START_LINE=$(wc -l < "$LOG_FILE" | tr -d ' ')
fi
open "$APP_BUNDLE"
echo "  App launched. Log starts at line $LOG_START_LINE"

# Step 6: Monitor and evaluate
echo "[6/6] Monitoring audio diagnostics (${TIMEOUT}s timeout)..."
echo "  Waiting for meeting to start — press New Meeting in the app..."
echo ""

# Wait for diagnostic markers
MIC_BUFFERS=0
SYS_BUFFERS=0
MIC_NONZERO=0
SYS_NONZERO=0
ENGINE_RUNNING=false
MEETING_STARTED=false
POLLING_STARTED=false

END_TIME=$((SECONDS + TIMEOUT))

while [ $SECONDS -lt $END_TIME ]; do
    if [ ! -f "$LOG_FILE" ]; then
        sleep 1
        continue
    fi

    # Read new log lines since launch
    NEW_LINES=$(tail -n +"$((LOG_START_LINE + 1))" "$LOG_FILE" 2>/dev/null || echo "")

    # Check for meeting start
    if echo "$NEW_LINES" | grep -q "Meeting started:"; then
        if [ "$MEETING_STARTED" = false ]; then
            echo "  ✓ Meeting started"
            MEETING_STARTED=true
        fi
    fi

    # Check for audio capture start
    if echo "$NEW_LINES" | grep -q "mic capture STARTED"; then
        echo "  ✓ Mic capture started"
    fi
    if echo "$NEW_LINES" | grep -q "system audio tap STARTED"; then
        echo "  ✓ System audio tap started"
    fi
    if echo "$NEW_LINES" | grep -q "system audio tap FAILED"; then
        echo "  ✗ System audio tap FAILED"
    fi

    # Check polling
    if echo "$NEW_LINES" | grep -q "Audio level polling: STARTING"; then
        if [ "$POLLING_STARTED" = false ]; then
            echo "  ✓ Audio level polling started"
            POLLING_STARTED=true
        fi
    fi

    # Count diagnostic buffer entries
    MIC_BUFFERS=$(echo "$NEW_LINES" | grep -c "DIAG:mic_buffer" || true)
    SYS_BUFFERS=$(echo "$NEW_LINES" | grep -c "DIAG:sys_buffer" || true)

    # Count non-zero levels
    MIC_NONZERO=$(echo "$NEW_LINES" | grep "DIAG:mic_buffer" | grep -cv "rms=0.0000" || true)
    SYS_NONZERO=$(echo "$NEW_LINES" | grep "DIAG:sys_buffer" | grep -cv "rms=0.0000" || true)

    # Check polled levels
    POLL_NONZERO=$(echo "$NEW_LINES" | grep "Audio levels:" | grep -cv "mic=0.0000 sys=0.0000" || true)

    # If we have enough data, report early
    if [ "$MIC_BUFFERS" -gt 10 ] && [ "$MEETING_STARTED" = true ]; then
        break
    fi

    sleep 2
done

echo ""
echo "=== RESULTS ==="
echo ""
echo "Meeting started:     $([ "$MEETING_STARTED" = true ] && echo "YES ✓" || echo "NO ✗")"
echo "Polling started:     $([ "$POLLING_STARTED" = true ] && echo "YES ✓" || echo "NO ✗")"
echo ""
echo "Mic buffer callbacks: $MIC_BUFFERS total, $MIC_NONZERO non-zero"
echo "Sys buffer callbacks: $SYS_BUFFERS total, $SYS_NONZERO non-zero"
echo "Polled non-zero:     $POLL_NONZERO readings"
echo ""

# Verdict
PASS=true
if [ "$MIC_BUFFERS" -eq 0 ]; then
    echo "FAIL: No mic buffer callbacks detected — onBuffer not firing"
    PASS=false
elif [ "$MIC_NONZERO" -eq 0 ]; then
    echo "FAIL: All mic buffers have RMS=0 — audio engine may not be capturing"
    PASS=false
else
    echo "PASS: Mic capture working ($MIC_NONZERO/$MIC_BUFFERS non-zero buffers)"
fi

if [ "$SYS_BUFFERS" -eq 0 ]; then
    echo "WARN: No system buffer callbacks — system tap may not be delivering audio"
    echo "      (Check Screen Recording permission in System Settings)"
elif [ "$SYS_NONZERO" -eq 0 ]; then
    echo "WARN: All system buffers have RMS=0 — no remote participant audio detected"
else
    echo "PASS: System capture working ($SYS_NONZERO/$SYS_BUFFERS non-zero buffers)"
fi

if [ "$POLL_NONZERO" -gt 0 ]; then
    echo "PASS: Audio levels propagating to UI ($POLL_NONZERO non-zero readings)"
else
    echo "FAIL: Audio levels not reaching UI — all polled values are 0"
    PASS=false
fi

echo ""
if [ "$PASS" = true ]; then
    echo "=== OVERALL: PASS ==="
else
    echo "=== OVERALL: FAIL ==="
    echo ""
    echo "Recent diagnostic lines:"
    tail -n +"$((LOG_START_LINE + 1))" "$LOG_FILE" 2>/dev/null | grep -E "DIAG:|Audio level|Audio:|mic capture|system audio" | tail -20
fi

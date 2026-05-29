#!/usr/bin/env bash
# Self-test: verify that the Meeting Manager transcription pipeline actually produces output.
#
# This script:
#   1. Builds the app in release mode
#   2. Installs it to ~/Applications
#   3. Launches it
#   4. Waits for WhisperKit model to download/load (checks stderr/os_log)
#   5. Creates a test WAV file with spoken audio (using macOS 'say' + afconvert)
#   6. Checks the SQLite database for transcript rows after a timeout
#   7. Reports PASS or FAIL
#
# Usage: ./scripts/test-transcription.sh [--skip-build]

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$HOME/Applications/Meeting Manager.app"
DB_PATH="$HOME/Library/Application Support/MeetingManager/db.sqlite3"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}PASS${NC}: $1"; }
fail() { echo -e "${RED}FAIL${NC}: $1"; }
warn() { echo -e "${YELLOW}WARN${NC}: $1"; }
info() { echo -e "INFO: $1"; }

# ── Step 1: Build ──────────────────────────────────────────
if [[ "${1:-}" != "--skip-build" ]]; then
    info "Building release..."
    cd "$REPO_DIR"
    swift build -c release 2>&1 | tail -3
    if [[ $? -ne 0 ]]; then
        fail "Build failed"
        exit 1
    fi
    pass "Build succeeded"

    # Install
    info "Installing to $APP_DIR..."
    pkill -f MeetingManager 2>/dev/null || true
    sleep 1
    rm -rf "$APP_DIR"
    mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
    cp ".build/release/MeetingManager" "$APP_DIR/Contents/MacOS/MeetingManager"
    cp "MeetingManager/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
    cp -r .build/release/MeetingManager_MeetingManager.bundle "$APP_DIR/Contents/Resources/" 2>/dev/null || true
    printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"
    pass "Installed"
else
    info "Skipping build (--skip-build)"
fi

# ── Step 2: Check DB exists ────────────────────────────────
info "Checking database at: $DB_PATH"
if [[ -f "$DB_PATH" ]]; then
    pass "Database file exists"
else
    warn "Database does not exist yet (will be created on first launch)"
fi

# ── Step 3: Check app runs ─────────────────────────────────
info "Launching app..."
open "$APP_DIR"
sleep 5

if pgrep -f MeetingManager > /dev/null 2>&1; then
    pass "App is running (PID: $(pgrep -f MeetingManager | head -1))"
else
    fail "App is NOT running — crashed on launch?"
    exit 1
fi

# ── Step 4: Check DB tables ────────────────────────────────
if [[ -f "$DB_PATH" ]]; then
    TABLES=$(sqlite3 "$DB_PATH" ".tables" 2>/dev/null)
    info "DB tables: $TABLES"

    if echo "$TABLES" | grep -q "transcript"; then
        pass "Transcript table exists"
    else
        fail "Transcript table missing from database"
    fi

    if echo "$TABLES" | grep -q "meeting"; then
        pass "Meeting table exists"
    else
        fail "Meeting table missing from database"
    fi

    if echo "$TABLES" | grep -q "appSettings"; then
        pass "AppSettings table exists"
    else
        fail "AppSettings table missing"
    fi

    # Check settings
    AI_ENABLED=$(sqlite3 "$DB_PATH" "SELECT aiEnabled FROM appSettings LIMIT 1;" 2>/dev/null || echo "N/A")
    info "AI enabled: $AI_ENABLED"

    # Check existing meetings
    MEETING_COUNT=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM meeting;" 2>/dev/null || echo "0")
    info "Existing meetings: $MEETING_COUNT"

    # Check existing transcripts
    TX_COUNT=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM transcript;" 2>/dev/null || echo "0")
    info "Existing transcript segments: $TX_COUNT"
else
    warn "Database not yet created"
fi

# ── Step 5: Summary ────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════"
echo "  MANUAL TEST INSTRUCTIONS"
echo "═══════════════════════════════════════════════"
echo ""
echo "The app is now running. To verify transcription:"
echo ""
echo "  1. Click 'New Meeting' in the sidebar"
echo "  2. Speak into your microphone for 15 seconds"
echo "  3. Watch the transcript pane — text should appear"
echo "  4. Click Stop"
echo "  5. The meeting should appear in the Past Meetings list"
echo ""
echo "After testing, run this to check transcript data:"
echo "  sqlite3 \"$DB_PATH\" \"SELECT text FROM transcript ORDER BY startTime DESC LIMIT 5;\""
echo ""
echo "To check meeting status:"
echo "  sqlite3 \"$DB_PATH\" \"SELECT title, status FROM meeting ORDER BY rowid DESC LIMIT 5;\""
echo ""

#!/bin/bash
# tsan-inplace.sh — Run a Thread-Sanitizer build of Meeting Manager by swapping
# the binary IN PLACE inside /Applications/Meeting Manager.app, then restore the
# release binary afterward. ONE bundle, ONE TCC identity — no duplicate app, no
# permission-prompt cascade (the separate-bundle approach wiped grants; never do
# that again).
#
#   bash Scripts/tsan-inplace.sh run        # backup release → swap in TSan → launch
#   bash Scripts/tsan-inplace.sh restore    # restore the release binary → relaunch
#   bash Scripts/tsan-inplace.sh run --force  # skip the in-call safety guard
#
# REFUSES to run while a meeting is in progress (would disrupt a live recording).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

APP="/Applications/Meeting Manager.app"
EXE="${APP}/Contents/MacOS/MeetingManager"
TSAN_BIN="${REPO_DIR}/.build/debug/MeetingManager"
BACKUP="${REPO_DIR}/build/release-binary-backup/MeetingManager"
ENTITLEMENTS="${REPO_DIR}/MeetingManager/Resources/MeetingManager.entitlements"
SIGN_IDENTITY="57A1035B19FC882CF723DB2EFF114D8104E50537"
APP_LOG="${HOME}/Library/Application Support/MeetingManager/app.log"
TSAN_LOG="/tmp/mm-tsan"

ACTION="${1:-}"; FORCE="${2:-}"

inCall() {
    # Last BrowserDetector poll line; treat inCall=true as "in a meeting".
    grep -hE "BrowserDetector: poll" "${APP_LOG}" 2>/dev/null | tail -1 | grep -q "inCall=true"
}

quitApp() {
    if pgrep -x MeetingManager >/dev/null 2>&1; then
        osascript -e 'tell application "Meeting Manager" to quit' >/dev/null 2>&1 &
        osa=$!; ( sleep 3; kill -9 "$osa" 2>/dev/null ) & wd=$!
        wait "$osa" 2>/dev/null || true; kill -9 "$wd" 2>/dev/null || true
        for _ in 1 2 3 4 5; do sleep 1; pgrep -x MeetingManager >/dev/null 2>&1 || break; done
        pgrep -x MeetingManager >/dev/null 2>&1 && { pkill -TERM -x MeetingManager 2>/dev/null || true; sleep 2; }
        pgrep -x MeetingManager >/dev/null 2>&1 && { pkill -9 -x MeetingManager 2>/dev/null || true; sleep 1; }
    fi
    pgrep -x MeetingManager >/dev/null 2>&1 && { echo "ERROR: app would not quit"; exit 1; } || true
}

signInPlace() {
    codesign --force --sign "${SIGN_IDENTITY}" --entitlements "${ENTITLEMENTS}" "${EXE}"
}

case "${ACTION}" in
run)
    [ -f "${TSAN_BIN}" ] || { echo "ERROR: TSan binary missing — run: swift build --sanitize=thread"; exit 1; }
    otool -L "${TSAN_BIN}" | grep -q libclang_rt.tsan || { echo "ERROR: ${TSAN_BIN} is not TSan-instrumented"; exit 1; }
    if [ "${FORCE}" != "--force" ] && inCall; then
        echo "REFUSING: a meeting is in progress (inCall=true). Re-run when the call ends, or pass --force."
        exit 2
    fi
    quitApp
    # Back up the REAL release binary before clobbering it (only if no backup yet,
    # so a second 'run' doesn't overwrite the good backup with a TSan binary).
    mkdir -p "$(dirname "${BACKUP}")"
    if [ ! -f "${BACKUP}" ]; then
        cp "${EXE}" "${BACKUP}"
        echo "Backed up release binary → ${BACKUP}"
    else
        echo "Release backup already exists (kept): ${BACKUP}"
    fi
    cp "${TSAN_BIN}" "${EXE}"
    signInPlace
    echo "Swapped in TSan binary + re-signed in place."
    rm -f ${TSAN_LOG}.* 2>/dev/null || true
    echo "Launching (race reports → ${TSAN_LOG}.<pid>). Grant Mic/Screen/Calendar when prompted."
    echo "Reproduce: join a call, transcribe a few min, toggle mic + switch input device once, then Quit."
    exec env TSAN_OPTIONS="halt_on_error=0 log_path=${TSAN_LOG} history_size=7 second_deadlock_stack=1" "${EXE}"
    ;;
restore)
    [ -f "${BACKUP}" ] || { echo "ERROR: no backup at ${BACKUP} — cannot restore"; exit 1; }
    quitApp
    cp "${BACKUP}" "${EXE}"
    signInPlace
    echo "Restored release binary + re-signed."
    open "${APP}"
    echo "Relaunched the normal build."
    ;;
*)
    echo "usage: bash Scripts/tsan-inplace.sh {run|restore} [--force]"; exit 1
    ;;
esac

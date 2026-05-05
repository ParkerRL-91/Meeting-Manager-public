#!/bin/bash
# install-local.sh — Build and install Meeting Manager locally for testing.
#
# Uses the persistent "MeetingManager-Dev" code signing cert so TCC grants
# (microphone, calendar, screen recording) are preserved across reinstalls.
# Never calls tccutil reset — grants accumulate rather than being wiped.
#
# Usage:
#   bash Scripts/install-local.sh
#   bash Scripts/install-local.sh --no-build   # skip build, just reinstall

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

APP_NAME="Meeting Manager"
EXECUTABLE="MeetingManager"
SIGN_IDENTITY="MeetingManager-Dev"
ENTITLEMENTS="${REPO_DIR}/MeetingManager/Resources/MeetingManager.entitlements"
BUILD_DIR="${REPO_DIR}/build/app"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
APP_DEST="/Applications/${APP_NAME}.app"
BINARY_SRC="${REPO_DIR}/.build/release/${EXECUTABLE}"

NO_BUILD=0
for arg in "$@"; do
    [[ "$arg" == "--no-build" ]] && NO_BUILD=1
done

# ── Build ──────────────────────────────────────────────────────────────────
if [[ "$NO_BUILD" == "0" ]]; then
    echo "Building..."
    cd "${REPO_DIR}"
    swift build -c release 2>&1 | grep -E "^(error:|Build complete)" || true
    if [[ ! -f "${BINARY_SRC}" ]]; then
        echo "ERROR: build failed — binary not found"; exit 1
    fi
    echo "Build complete."
fi

# ── Assemble bundle ────────────────────────────────────────────────────────
echo "Assembling bundle..."
mkdir -p "${BUILD_DIR}/${APP_NAME}.app/Contents/MacOS"
mkdir -p "${BUILD_DIR}/${APP_NAME}.app/Contents/Resources"
cp "${BINARY_SRC}" "${APP_BUNDLE}/Contents/MacOS/${EXECUTABLE}"
cp "${REPO_DIR}/MeetingManager/Resources/Info.plist" "${APP_BUNDLE}/Contents/Info.plist"
rsync -a --exclude="Info.plist" \
    "${REPO_DIR}/MeetingManager/Resources/" \
    "${APP_BUNDLE}/Contents/Resources/"

# ── Sign with persistent cert ──────────────────────────────────────────────
echo "Signing with '${SIGN_IDENTITY}'..."
codesign --force --sign "${SIGN_IDENTITY}" \
    --entitlements "${ENTITLEMENTS}" \
    "${APP_BUNDLE}/Contents/MacOS/${EXECUTABLE}"
codesign --force --deep --sign "${SIGN_IDENTITY}" \
    --entitlements "${ENTITLEMENTS}" \
    "${APP_BUNDLE}"

# ── Stop running instance ──────────────────────────────────────────────────
# Two-step kill: graceful AppleScript quit first (lets the app flush state
# and exit cleanly), then pkill -9 as a fallback. The previous single-pkill
# version relied on SIGTERM, which a SwiftUI app's default signal handler
# can ignore — leaving the old process alive while the binary swap below
# happened underneath. Visible symptom: install reports success, the
# version string on disk matches the latest commit, but the running process
# is still pre-change because the loaded binary's file descriptor was
# never released.
echo "Stopping any running instance..."
if pgrep -x "${EXECUTABLE}" >/dev/null 2>&1; then
    osascript -e "tell application \"${APP_NAME}\" to quit" 2>/dev/null || true
    # Poll up to 5s for graceful shutdown
    for _ in 1 2 3 4 5; do
        sleep 1
        pgrep -x "${EXECUTABLE}" >/dev/null 2>&1 || break
    done
    # Force-kill anything still alive
    if pgrep -x "${EXECUTABLE}" >/dev/null 2>&1; then
        echo "  graceful quit didn't take — sending SIGKILL"
        pkill -9 -x "${EXECUTABLE}" 2>/dev/null || true
        sleep 1
    fi
fi

# ── Install ────────────────────────────────────────────────────────────────
echo "Installing to ${APP_DEST}..."
# `ditto` overwrites files with the same name in-place. We don't `rm -rf`
# the destination because the signed bundle in /Applications carries
# extended attributes that block plain `rm` without elevation. The bundle
# layout is consistent build-to-build, so a merge-overwrite is safe in
# practice — no stale files have ever been observed from this path.
ditto "${APP_BUNDLE}" "${APP_DEST}"

VERSION=$(defaults read "${APP_DEST}/Contents/Info.plist" CFBundleShortVersionString)
echo "Installed Meeting Manager ${VERSION}"
echo ""
echo "NOTE: TCC grants are preserved — no permission reset needed."
echo "      If a permission prompt appears, grant it once and it will stick."
echo ""

# ── Relaunch ───────────────────────────────────────────────────────────────
# `-n` forces a new process even if macOS thinks the app is still around.
# `-F` clears saved state so the relaunch is fully fresh.
open -n -F "${APP_DEST}"

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
# Pin to the EXACT cert SHA-1, not the name. Two self-signed certs exist in the
# keychain ("MeetingManager-Dev" and "MeetingManager-Dev2"), so --sign
# "MeetingManager-Dev" is an ambiguous prefix match. If codesign ever resolved
# it to Dev2, the app's designated requirement (certificate root) would change,
# macOS TCC would treat it as a *different* app, and a DUPLICATE entry would
# appear in System Settings → Privacy (existing grants lost). This hash is the
# cert the installed app and all existing TCC grants are bound to:
#   codesign -d --requirements -  →  certificate root = H"57a1035b…"
SIGN_IDENTITY="57A1035B19FC882CF723DB2EFF114D8104E50537"
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
    # Graceful quit via Apple Event, but BOUNDED: `osascript ... to quit` can
    # hang indefinitely waiting on an Automation (TCC) permission prompt that
    # never appears in a non-interactive run, wedging the whole install. Run
    # it in the background and hard-kill the osascript after 3s so we always
    # fall through to the SIGTERM/SIGKILL path below.
    osascript -e "tell application \"${APP_NAME}\" to quit" >/dev/null 2>&1 &
    osa_pid=$!
    ( sleep 3; kill -9 "${osa_pid}" 2>/dev/null ) &
    watchdog_pid=$!
    wait "${osa_pid}" 2>/dev/null || true
    kill -9 "${watchdog_pid}" 2>/dev/null || true

    # Poll up to 5s for graceful shutdown
    for _ in 1 2 3 4 5; do
        sleep 1
        pgrep -x "${EXECUTABLE}" >/dev/null 2>&1 || break
    done
    # Escalate: SIGTERM, then SIGKILL.
    if pgrep -x "${EXECUTABLE}" >/dev/null 2>&1; then
        echo "  graceful quit didn't take — sending SIGTERM"
        pkill -TERM -x "${EXECUTABLE}" 2>/dev/null || true
        sleep 2
    fi
    if pgrep -x "${EXECUTABLE}" >/dev/null 2>&1; then
        echo "  still alive — sending SIGKILL"
        pkill -9 -x "${EXECUTABLE}" 2>/dev/null || true
        sleep 1
    fi
fi

# ── Install ────────────────────────────────────────────────────────────────
echo "Installing to ${APP_DEST}..."
# Clean the destination's CONTENTS before copying — do NOT plain ditto-merge.
# A merge left stale files across installs (an old codesign `*.cstemp`, and
# even a whole nested `Meeting Manager.app/` copied inside the bundle) that
# aren't part of the freshly-signed seal, so `codesign --verify --strict`
# failed ("a sealed resource is missing or invalid"). A broken seal risks
# macOS re-evaluating the app's identity and re-prompting for permissions /
# spawning a duplicate TCC entry — exactly what we're trying to avoid.
#
# We clear the contents rather than `rm -rf` the whole bundle because macOS
# App Management protection blocks removing a top-level `.app` from
# /Applications (that fails with "Permission denied"), but we own and can
# clear what's INSIDE the bundle. `ditto` then lays down a byte-for-byte copy
# of the signed staging bundle.
if [[ -d "${APP_DEST}" ]]; then
    chflags -R nouchg "${APP_DEST}" 2>/dev/null || true
    rm -rf "${APP_DEST:?}/"* "${APP_DEST:?}/".[!.]* 2>/dev/null || true
fi
ditto "${APP_BUNDLE}" "${APP_DEST}"

# Fail loudly if the installed bundle doesn't validate — a bad seal here is
# exactly what causes permission re-prompts / duplicate TCC entries.
if ! codesign --verify --strict "${APP_DEST}" 2>/dev/null; then
    echo "ERROR: installed bundle failed codesign --verify --strict" >&2
    exit 1
fi

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

#!/bin/bash
# clean-build-dmg.sh — Clear caches, build fresh, install, and create DMG.
#
# Usage:
#   ./Scripts/clean-build-dmg.sh
#
# What it does:
#   1. Kills any running Meeting Manager
#   2. Clears SPM build cache, derived data, and app caches
#   3. Resolves dependencies fresh
#   4. Builds release binary
#   5. Assembles .app bundle with Sparkle framework
#   6. Ad-hoc signs the bundle (use SIGN_IDENTITY env var for production)
#   7. Installs to ~/Applications
#   8. Creates DMG in repo root
#
# Requirements:
#   - macOS 14.4+, Xcode CLI tools (xcode-select --install)
#   - Swift 5.9+

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

APP_NAME="Meeting Manager"
EXECUTABLE="MeetingManager"
BUNDLE_ID="com.meetingmanager.app"

# ──────────────────────────────────────────────────
# Signing identity — MUST be stable to preserve macOS permissions (TCC).
# Ad-hoc signing (--sign -) changes identity every build, which forces
# the user to re-grant Screen Recording permission after each rebuild.
# ──────────────────────────────────────────────────
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    echo "Using explicit SIGN_IDENTITY: ${SIGN_IDENTITY}"
elif security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"; then
    SIGN_IDENTITY="Developer ID Application"
    echo "Auto-detected Developer ID Application certificate."
elif security find-identity -v -p codesigning 2>/dev/null | grep -q "MeetingManager-Dev"; then
    SIGN_IDENTITY="MeetingManager-Dev"
    echo "Auto-detected MeetingManager-Dev certificate."
else
    echo ""
    echo "ERROR: No stable code-signing identity found."
    echo ""
    echo "  Ad-hoc signing (--sign -) causes macOS to forget your Screen Recording"
    echo "  and Microphone permissions every time you rebuild. This is why the app"
    echo "  keeps asking for permissions."
    echo ""
    echo "  To fix this, run the setup script to create a free self-signed certificate:"
    echo ""
    echo "    ./Scripts/setup-signing.sh"
    echo ""
    echo "  This is a one-time setup. After that, permissions stick across rebuilds."
    echo ""
    echo "  To bypass this check (not recommended): SIGN_IDENTITY=- ./Scripts/clean-build-dmg.sh"
    echo ""
    exit 1
fi

# Read version from Info.plist
PLIST="${REPO_DIR}/MeetingManager/Resources/Info.plist"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${PLIST}")
echo "=== Clean Build — Meeting Manager v${VERSION} ==="

# ──────────────────────────────────────────────────
# Step 1: Kill running instance
# ──────────────────────────────────────────────────
echo "[1/8] Stopping running Meeting Manager..."
pkill -x "${EXECUTABLE}" 2>/dev/null || true
sleep 1

# ──────────────────────────────────────────────────
# Step 2: Clear ALL caches
# ──────────────────────────────────────────────────
echo "[2/8] Clearing caches..."

# SPM build artifacts
rm -rf "${REPO_DIR}/.build"
echo "  Cleared .build/"

# Old build output
rm -rf "${REPO_DIR}/build"
echo "  Cleared build/"

# Xcode derived data (if any)
DERIVED_DATA="${HOME}/Library/Developer/Xcode/DerivedData"
MEETING_DERIVED=$(find "${DERIVED_DATA}" -maxdepth 1 -name "MeetingManager-*" 2>/dev/null || true)
if [[ -n "${MEETING_DERIVED}" ]]; then
    rm -rf ${MEETING_DERIVED}
    echo "  Cleared Xcode DerivedData"
fi

# App caches
rm -rf "${HOME}/Library/Caches/${BUNDLE_ID}" 2>/dev/null || true
rm -rf "${HOME}/Library/Caches/com.apple.dt.SwiftPackageManager" 2>/dev/null || true
echo "  Cleared app and SPM caches"

# macOS app icon/bundle cache (forces fresh app bundle recognition)
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -kill -r -domain local -domain system -domain user 2>/dev/null || true
echo "  Reset LaunchServices cache"

# ──────────────────────────────────────────────────
# Step 3: Resolve dependencies
# ──────────────────────────────────────────────────
echo "[3/8] Resolving dependencies..."
cd "${REPO_DIR}"
swift package resolve
echo "  Dependencies resolved."

# ──────────────────────────────────────────────────
# Step 4: Build release binary
# ──────────────────────────────────────────────────
echo "[4/8] Building release..."
swift build -c release 2>&1 | grep -E "^(Compiling|Linking|error:|warning:|Build complete)" || true

BINARY="${REPO_DIR}/.build/release/${EXECUTABLE}"
if [[ ! -f "${BINARY}" ]]; then
    echo "ERROR: Build failed — binary not found at ${BINARY}"
    exit 1
fi
echo "  Binary: ${BINARY}"

# ──────────────────────────────────────────────────
# Step 5: Assemble .app bundle
# ──────────────────────────────────────────────────
echo "[5/8] Assembling .app bundle..."
BUILD_DIR="${REPO_DIR}/build"
APP_BUNDLE="${BUILD_DIR}/app/${APP_NAME}.app"
MACOS_DIR="${APP_BUNDLE}/Contents/MacOS"
FRAMEWORKS_DIR="${APP_BUNDLE}/Contents/Frameworks"
RESOURCES_DIR="${APP_BUNDLE}/Contents/Resources"

mkdir -p "${MACOS_DIR}" "${FRAMEWORKS_DIR}" "${RESOURCES_DIR}"

# Binary
cp "${BINARY}" "${MACOS_DIR}/${EXECUTABLE}"

# Info.plist
cp "${PLIST}" "${APP_BUNDLE}/Contents/Info.plist"

# Entitlements (for reference, not embedded by ad-hoc signing)
if [[ -f "${REPO_DIR}/MeetingManager/Resources/MeetingManager.entitlements" ]]; then
    cp "${REPO_DIR}/MeetingManager/Resources/MeetingManager.entitlements" "${RESOURCES_DIR}/"
fi

# App resources (icons, assets, etc.)
if [[ -d "${REPO_DIR}/MeetingManager/Resources" ]]; then
    rsync -a \
        --exclude="Info.plist" \
        --exclude="MeetingManager.entitlements" \
        "${REPO_DIR}/MeetingManager/Resources/" "${RESOURCES_DIR}/"
fi

# Sparkle framework
SPARKLE_FRAMEWORK_SRC="$(find "${REPO_DIR}/.build/artifacts" -name "Sparkle.framework" -maxdepth 5 2>/dev/null | head -1)"
if [[ -z "${SPARKLE_FRAMEWORK_SRC}" ]]; then
    SPARKLE_FRAMEWORK_SRC="$(find "${REPO_DIR}/.build/checkouts" -name "Sparkle.framework" -maxdepth 5 2>/dev/null | head -1)"
fi
if [[ -n "${SPARKLE_FRAMEWORK_SRC}" ]]; then
    cp -R "${SPARKLE_FRAMEWORK_SRC}" "${FRAMEWORKS_DIR}/"
    # Ensure @executable_path/../Frameworks rpath exists — required for Sparkle to load.
    # -add_rpath fails if it already exists, so check first.
    if ! otool -l "${MACOS_DIR}/${EXECUTABLE}" | grep -q "@executable_path/../Frameworks"; then
        install_name_tool -add_rpath "@executable_path/../Frameworks" "${MACOS_DIR}/${EXECUTABLE}"
    fi
    echo "  Sparkle framework bundled."
else
    echo "  WARNING: Sparkle.framework not found — update checks won't work."
fi

echo "  App bundle: ${APP_BUNDLE}"

# ──────────────────────────────────────────────────
# Step 6: Sign
# ──────────────────────────────────────────────────
echo "[6/8] Signing with '${SIGN_IDENTITY}'..."

ENTITLEMENTS="${REPO_DIR}/MeetingManager/Resources/MeetingManager.entitlements"

# Sign Sparkle components first
if [[ -d "${FRAMEWORKS_DIR}/Sparkle.framework" ]]; then
    codesign --force --deep --options runtime \
        --sign "${SIGN_IDENTITY}" \
        "${FRAMEWORKS_DIR}/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc" 2>/dev/null || true
    codesign --force --options runtime \
        --sign "${SIGN_IDENTITY}" \
        "${FRAMEWORKS_DIR}/Sparkle.framework/Versions/B/Autoupdate" 2>/dev/null || true
    codesign --force --options runtime \
        --sign "${SIGN_IDENTITY}" \
        "${FRAMEWORKS_DIR}/Sparkle.framework" 2>/dev/null || true
fi

# Sign the app bundle with entitlements
codesign --force --deep --options runtime \
    --entitlements "${ENTITLEMENTS}" \
    --sign "${SIGN_IDENTITY}" \
    "${APP_BUNDLE}"

# Verify signing identity is stable (not ad-hoc)
SIGNED_ID=$(codesign -dvv "${APP_BUNDLE}" 2>&1 | grep "Authority=" | head -1 || true)
if [[ "${SIGN_IDENTITY}" != "-" ]]; then
    echo "  Signed with: ${SIGNED_ID}"
    echo "  ✓ Stable identity — macOS permissions will persist across rebuilds."
else
    echo "  ⚠ Ad-hoc signed — permissions will reset on next rebuild."
fi

# ──────────────────────────────────────────────────
# Step 7: Install to ~/Applications
# ──────────────────────────────────────────────────
echo "[7/8] Installing to ~/Applications..."
INSTALL_DIR="${HOME}/Applications"
INSTALL_PATH="${INSTALL_DIR}/${APP_NAME}.app"

mkdir -p "${INSTALL_DIR}"
rm -rf "${INSTALL_PATH}"
cp -R "${APP_BUNDLE}" "${INSTALL_PATH}"
xattr -cr "${INSTALL_PATH}" 2>/dev/null || true
echo "  Installed: ${INSTALL_PATH}"

# ──────────────────────────────────────────────────
# Step 8: Create DMG
# ──────────────────────────────────────────────────
echo "[8/8] Creating DMG..."
DMG_NAME="MeetingManager-v${VERSION}.dmg"
DMG_PATH="${REPO_DIR}/${DMG_NAME}"
DMG_STAGING="${BUILD_DIR}/dmg-staging"

# Remove old DMGs from repo root
rm -f "${REPO_DIR}"/MeetingManager-v*.dmg 2>/dev/null || true

mkdir -p "${DMG_STAGING}"
cp -R "${APP_BUNDLE}" "${DMG_STAGING}/"
ln -sf /Applications "${DMG_STAGING}/Applications"

hdiutil create \
    -volname "${APP_NAME}" \
    -srcfolder "${DMG_STAGING}" \
    -ov -format UDZO \
    "${DMG_PATH}"

echo "  DMG: ${DMG_PATH}"

# ──────────────────────────────────────────────────
# Done
# ──────────────────────────────────────────────────
echo ""
echo "=== Build complete ==="
echo "  App:     ${INSTALL_PATH}"
echo "  DMG:     ${DMG_PATH}"
echo ""
echo "To launch:"
echo "  open ~/Applications/Meeting\\ Manager.app"
echo ""
echo "To push the DMG to git:"
echo "  git add ${DMG_NAME} && git commit -m 'Build v${VERSION} DMG' && git push"

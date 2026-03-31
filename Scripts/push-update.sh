#!/bin/bash
# push-update.sh — Build, sign, package, and publish a Meeting Manager release.
#
# Prerequisites:
#   - Developer ID Application certificate in Keychain
#   - Sparkle EdDSA private key in Keychain (generated once with generate_keys)
#   - gh CLI installed and authenticated (brew install gh)
#   - GitHub Pages enabled on the repo, serving from docs/ on main branch
#   - TEAM_ID and APPLE_ID environment variables set, or a notarytool keychain profile
#     named "MeetingManager-Notarize" (xcrun notarytool store-credentials)
#
# Usage:
#   ./Scripts/push-update.sh 1.2.0
#
# The script will:
#   1. Bump version in Info.plist
#   2. Build release binary via swift build
#   3. Assemble a signed .app bundle
#   4. Notarize and staple (if NOTARIZE=1)
#   5. Create a signed DMG
#   6. Generate and sign appcast.xml for Sparkle
#   7. Push appcast.xml to docs/ (GitHub Pages) and commit
#   8. Create a GitHub Release with the DMG attached

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

APP_NAME="Meeting Manager"
BUNDLE_ID="com.meetingmanager.app"
EXECUTABLE="MeetingManager"
BUILD_DIR="${REPO_DIR}/build"
SPARKLE_BIN="${REPO_DIR}/.build/artifacts/sparkle/Sparkle/bin"
GENERATE_APPCAST="${SPARKLE_BIN}/generate_appcast"
SIGN_UPDATE="${SPARKLE_BIN}/sign_update"
NOTARIZE="${NOTARIZE:-0}"

VERSION="${1:-}"
if [[ -z "${VERSION}" ]]; then
    echo "Usage: $0 <version>  (e.g. $0 1.2.0)"
    exit 1
fi

echo "=== Meeting Manager v${VERSION} release ==="

# ──────────────────────────────────────────────────
# Step 1: Bump version in Info.plist
# ──────────────────────────────────────────────────
PLIST="${REPO_DIR}/MeetingManager/Resources/Info.plist"
echo "Bumping version to ${VERSION}..."
plutil -replace CFBundleShortVersionString -string "${VERSION}" "${PLIST}"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"
plutil -replace CFBundleVersion -string "${BUILD_NUMBER}" "${PLIST}"

# ──────────────────────────────────────────────────
# Step 2: Build release binary
# ──────────────────────────────────────────────────
echo "Building..."
cd "${REPO_DIR}"
swift build -c release 2>&1 | grep -E "^(error:|warning:|Build complete)" || true
BINARY="${REPO_DIR}/.build/release/${EXECUTABLE}"
if [[ ! -f "${BINARY}" ]]; then
    echo "Error: binary not found at ${BINARY}"
    exit 1
fi
echo "Binary built: ${BINARY}"

# ──────────────────────────────────────────────────
# Step 3: Assemble .app bundle
# ──────────────────────────────────────────────────
echo "Assembling .app bundle..."
rm -rf "${BUILD_DIR}"
APP_BUNDLE="${BUILD_DIR}/app/${APP_NAME}.app"
MACOS_DIR="${APP_BUNDLE}/Contents/MacOS"
FRAMEWORKS_DIR="${APP_BUNDLE}/Contents/Frameworks"
RESOURCES_DIR="${APP_BUNDLE}/Contents/Resources"

mkdir -p "${MACOS_DIR}" "${FRAMEWORKS_DIR}" "${RESOURCES_DIR}"

# Binary
cp "${BINARY}" "${MACOS_DIR}/${EXECUTABLE}"

# Info.plist
cp "${PLIST}" "${APP_BUNDLE}/Contents/Info.plist"

# App resources (icons, entitlements, etc.)
if [[ -d "${REPO_DIR}/MeetingManager/Resources" ]]; then
    rsync -a --exclude="Info.plist" "${REPO_DIR}/MeetingManager/Resources/" "${RESOURCES_DIR}/"
fi

# Sparkle framework
SPARKLE_FRAMEWORK_SRC="$(find "${REPO_DIR}/.build/artifacts" -name "Sparkle.framework" -maxdepth 5 | head -1)"
if [[ -z "${SPARKLE_FRAMEWORK_SRC}" ]]; then
    SPARKLE_FRAMEWORK_SRC="$(find "${REPO_DIR}/.build/checkouts" -name "Sparkle.framework" -maxdepth 5 | head -1)"
fi
if [[ -n "${SPARKLE_FRAMEWORK_SRC}" ]]; then
    cp -R "${SPARKLE_FRAMEWORK_SRC}" "${FRAMEWORKS_DIR}/"
    install_name_tool -add_rpath "@executable_path/../Frameworks" \
        "${MACOS_DIR}/${EXECUTABLE}" 2>/dev/null || true
    echo "Sparkle framework bundled."
else
    echo "Warning: Sparkle.framework not found — update checks will not work."
fi

# ──────────────────────────────────────────────────
# Step 4: Sign
# ──────────────────────────────────────────────────
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
echo "Signing with '${SIGN_IDENTITY}'..."

# Sign Sparkle first (required for deep signing to work)
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

# Sign the binary
codesign --force --options runtime \
    --sign "${SIGN_IDENTITY}" \
    "${MACOS_DIR}/${EXECUTABLE}"

# Sign the app bundle
codesign --force --deep --options runtime \
    --sign "${SIGN_IDENTITY}" \
    "${APP_BUNDLE}"

echo "Signed."

# ──────────────────────────────────────────────────
# Step 5: Notarize (optional, set NOTARIZE=1)
# ──────────────────────────────────────────────────
if [[ "${NOTARIZE}" == "1" ]]; then
    echo "Notarizing..."
    NOTARIZE_ZIP="${BUILD_DIR}/${EXECUTABLE}-${VERSION}-notarize.zip"
    ditto -c -k --keepParent "${APP_BUNDLE}" "${NOTARIZE_ZIP}"
    xcrun notarytool submit "${NOTARIZE_ZIP}" \
        --keychain-profile "MeetingManager-Notarize" \
        --wait
    xcrun stapler staple "${APP_BUNDLE}"
    echo "Notarized and stapled."
fi

# ──────────────────────────────────────────────────
# Step 6: Create DMG
# ──────────────────────────────────────────────────
echo "Creating DMG..."
DMG_NAME="${APP_NAME// /-}-${VERSION}.dmg"
DMG_DIR="${BUILD_DIR}/dmg"
DMG_PATH="${DMG_DIR}/${DMG_NAME}"
DMG_STAGING="${BUILD_DIR}/dmg-staging"

mkdir -p "${DMG_DIR}" "${DMG_STAGING}"
cp -R "${APP_BUNDLE}" "${DMG_STAGING}/"
ln -sf /Applications "${DMG_STAGING}/Applications"

hdiutil create \
    -volname "${APP_NAME}" \
    -srcfolder "${DMG_STAGING}" \
    -ov -format UDZO \
    "${DMG_PATH}"

if [[ "${NOTARIZE}" == "1" ]]; then
    codesign --sign "${SIGN_IDENTITY}" "${DMG_PATH}"
fi

echo "DMG: ${DMG_PATH}"

# ──────────────────────────────────────────────────
# Step 7: Generate appcast.xml
# ──────────────────────────────────────────────────
echo "Generating appcast..."
APPCAST_BUILD_DIR="${BUILD_DIR}/appcast"
mkdir -p "${APPCAST_BUILD_DIR}"
cp "${DMG_PATH}" "${APPCAST_BUILD_DIR}/"

# generate_appcast will sign the release using the Sparkle private key in Keychain
"${GENERATE_APPCAST}" \
    --download-url-prefix "https://github.com/ParkerRL-91/Meeting-Manager/releases/download/v${VERSION}/" \
    --link "https://github.com/ParkerRL-91/Meeting-Manager/releases/tag/v${VERSION}" \
    "${APPCAST_BUILD_DIR}"

echo "Appcast generated."

# ──────────────────────────────────────────────────
# Step 8: Publish appcast to GitHub Pages (docs/)
# ──────────────────────────────────────────────────
echo "Publishing appcast to GitHub Pages..."
DOCS_DIR="${REPO_DIR}/docs"
mkdir -p "${DOCS_DIR}"
cp "${APPCAST_BUILD_DIR}/appcast.xml" "${DOCS_DIR}/appcast.xml"

cd "${REPO_DIR}"
git add docs/appcast.xml MeetingManager/Resources/Info.plist
git commit -m "Release v${VERSION}

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
git push

echo "Appcast pushed to GitHub Pages."

# ──────────────────────────────────────────────────
# Step 9: Create GitHub Release
# ──────────────────────────────────────────────────
echo "Creating GitHub Release v${VERSION}..."
gh release create "v${VERSION}" \
    "${DMG_PATH}" \
    --title "Meeting Manager v${VERSION}" \
    --notes "## Meeting Manager v${VERSION}

**Install:** Download and open the DMG, then drag Meeting Manager to Applications.

**Auto-update:** If you have a previous version installed, it will update automatically via Sparkle." \
    --repo "ParkerRL-91/Meeting-Manager"

echo ""
echo "=== Release v${VERSION} complete ==="
echo "  DMG:      ${DMG_PATH}"
echo "  Appcast:  https://parkerrl-91.github.io/Meeting-Manager/appcast.xml"
echo "  Release:  https://github.com/ParkerRL-91/Meeting-Manager/releases/tag/v${VERSION}"

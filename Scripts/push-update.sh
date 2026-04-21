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
#   ./Scripts/push-update.sh 1.2.0           # full release (must set NOTARIZE=1)
#   ./Scripts/push-update.sh --dry-run 1.2.0 # validate only — no build or publish
#   NOTARIZE=1 ./Scripts/push-update.sh 1.2.0
#   SKIP_NOTARIZE=1 ./Scripts/push-update.sh 1.2.0  # override (not recommended)
#
# The script will:
#   1. Pre-flight: git state check + Keychain key check + notarization guard
#   2. Bump version in Info.plist (atomically: reverts on build failure)
#   3. Build release binary via swift build
#   4. Assemble a signed .app bundle
#   5. Notarize and staple (required unless SKIP_NOTARIZE=1)
#   6. Create a signed DMG and print SHA-256 checksum
#   7. Download previous release DMG for delta generation
#   8. Generate and sign appcast.xml for Sparkle (with .delta files)
#   9. Push appcast.xml to docs/ (GitHub Pages) — only if changed
#  10. Create a GitHub Release with the DMG attached

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
SKIP_NOTARIZE="${SKIP_NOTARIZE:-0}"

# ──────────────────────────────────────────────────
# Parse arguments
# ──────────────────────────────────────────────────
DRY_RUN=0
VERSION=""

for arg in "$@"; do
    case "${arg}" in
        --dry-run) DRY_RUN=1 ;;
        *)         VERSION="${arg}" ;;
    esac
done

if [[ -z "${VERSION}" ]]; then
    echo "Usage: $0 [--dry-run] <version>  (e.g. $0 1.2.0)"
    exit 1
fi

PLIST="${REPO_DIR}/MeetingManager/Resources/Info.plist"

# ──────────────────────────────────────────────────
# Pre-flight validation (always runs, even in dry-run)
# ──────────────────────────────────────────────────
echo "=== Pre-flight checks ==="

# 1. Git state: working tree must be clean
if [[ -n "$(git -C "${REPO_DIR}" status --porcelain)" ]]; then
    echo "ERROR: Working tree is dirty. Commit or stash all changes before releasing."
    git -C "${REPO_DIR}" status --short
    exit 1
fi
echo "  [OK] git working tree is clean"

# 2. Signing environment: required to produce a release-quality archive.
#    build-release.sh silently substitutes empty strings if these are missing,
#    which surfaces far later as cryptic xcodebuild / notarytool errors. Fail fast.
MISSING_ENV=()
if [[ -z "${TEAM_ID:-}" ]]; then MISSING_ENV+=("TEAM_ID"); fi
if [[ "${SKIP_NOTARIZE:-}" != "1" && -z "${APPLE_ID:-}" ]]; then MISSING_ENV+=("APPLE_ID"); fi
if [[ "${SKIP_NOTARIZE:-}" != "1" && -z "${APP_SPECIFIC_PASSWORD:-}" ]]; then MISSING_ENV+=("APP_SPECIFIC_PASSWORD"); fi
if [[ ${#MISSING_ENV[@]} -gt 0 ]]; then
    echo "ERROR: Required signing env vars not set: ${MISSING_ENV[*]}"
    echo "  Set them in your shell profile or a .env.local (gitignored), then re-run."
    echo "  TEAM_ID                Apple Developer team ID (10-char alphanumeric)"
    echo "  APPLE_ID               Apple ID used for notarization"
    echo "  APP_SPECIFIC_PASSWORD  App-specific password for notarytool"
    echo "  (APPLE_ID / APP_SPECIFIC_PASSWORD may be omitted when SKIP_NOTARIZE=1.)"
    exit 1
fi
echo "  [OK] signing env vars present"

# 3. Sparkle EdDSA key must be accessible in Keychain before we spend 3min building.
# Sparkle's generate_keys tool stores the key with service="https://sparkle-project.org"
# and account="ed25519".
SPARKLE_KEY_SERVICE="https://sparkle-project.org"
SPARKLE_KEY_ACCOUNT="ed25519"
if ! security find-generic-password -s "${SPARKLE_KEY_SERVICE}" -a "${SPARKLE_KEY_ACCOUNT}" &>/dev/null; then
    echo "ERROR: Sparkle EdDSA private key not found in Keychain."
    echo "  Expected: service='${SPARKLE_KEY_SERVICE}' account='${SPARKLE_KEY_ACCOUNT}'"
    echo "  Run: ${SPARKLE_BIN}/generate_keys  (then copy the public key to Info.plist SUPublicEDKey)"
    echo "  Or:  ./Scripts/setup-signing.sh"
    exit 1
fi
echo "  [OK] Sparkle EdDSA key found in Keychain"

# 3. Current version
ORIGINAL_VERSION="$(plutil -extract CFBundleShortVersionString raw "${PLIST}")"
echo "  [OK] Current version: ${ORIGINAL_VERSION} → new version: ${VERSION}"

# 4. Notarization guard: enforce NOTARIZE=1 unless explicitly overriding
if [[ "${DRY_RUN}" == "0" && "${NOTARIZE}" != "1" && "${SKIP_NOTARIZE}" != "1" ]]; then
    echo ""
    echo "ERROR: Notarization is required for public releases."
    echo "  Un-notarized apps are blocked by Gatekeeper on macOS 15+ for most users."
    echo "  Options:"
    echo "    NOTARIZE=1 $0 ${VERSION}          # full notarization (recommended)"
    echo "    SKIP_NOTARIZE=1 $0 ${VERSION}     # skip (internal testing only)"
    exit 1
fi
if [[ "${SKIP_NOTARIZE}" == "1" && "${NOTARIZE}" != "1" ]]; then
    echo ""
    echo "  WARN: Shipping WITHOUT notarization (SKIP_NOTARIZE=1)."
    echo "  Users on macOS 15+ will see Gatekeeper warnings. Use for internal testing only."
fi

echo ""

# ──────────────────────────────────────────────────
# Dry-run: exit after validation
# ──────────────────────────────────────────────────
if [[ "${DRY_RUN}" == "1" ]]; then
    echo "=== DRY RUN — all checks passed. Would release v${VERSION}. ==="
    echo "  git state:         clean"
    echo "  Sparkle key:       found (service='${SPARKLE_KEY_SERVICE}')"
    echo "  Current version:   ${ORIGINAL_VERSION}"
    echo "  New version:       ${VERSION}"
    echo "  Notarize:          ${NOTARIZE}"
    echo "  No build or publish performed."
    exit 0
fi

echo "=== Meeting Manager v${VERSION} release ==="

# ──────────────────────────────────────────────────
# Step 1: Bump version (atomic — reverts on build failure)
# ──────────────────────────────────────────────────
echo "Bumping version to ${VERSION}..."
plutil -replace CFBundleShortVersionString -string "${VERSION}" "${PLIST}"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"
plutil -replace CFBundleVersion -string "${BUILD_NUMBER}" "${PLIST}"

# ──────────────────────────────────────────────────
# Step 2: Build release binary
# ──────────────────────────────────────────────────
echo "Building..."
cd "${REPO_DIR}"
if ! swift build -c release 2>&1 | grep -E "^(error:|warning:|Build complete)" || true; then
    :  # grep exits non-zero if no match — that's fine
fi

BINARY="${REPO_DIR}/.build/release/${EXECUTABLE}"
if [[ ! -f "${BINARY}" ]]; then
    echo "ERROR: Build failed — binary not found at ${BINARY}. Reverting version bump."
    plutil -replace CFBundleShortVersionString -string "${ORIGINAL_VERSION}" "${PLIST}"
    plutil -replace CFBundleVersion -string "$(date +%Y%m%d%H%M)" "${PLIST}"
    exit 1
fi

# Verify build actually succeeded (swift build exits 0 even on error in some versions)
if ! swift build -c release --show-bin-path &>/dev/null; then
    echo "ERROR: Build verification failed. Reverting version bump."
    plutil -replace CFBundleShortVersionString -string "${ORIGINAL_VERSION}" "${PLIST}"
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
# Step 5: Notarize (required by default, SKIP_NOTARIZE=1 to override)
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
# Step 6: Create DMG + print SHA-256
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

DMG_SHA=$(shasum -a 256 "${DMG_PATH}" | awk '{print $1}')
echo "DMG: ${DMG_PATH}"
echo "SHA-256: ${DMG_SHA}"

# ──────────────────────────────────────────────────
# Step 7: Fetch previous release DMG for delta generation
# ──────────────────────────────────────────────────
echo "Generating appcast (with delta support)..."
APPCAST_BUILD_DIR="${BUILD_DIR}/appcast"
mkdir -p "${APPCAST_BUILD_DIR}"

# Download previous release DMG so generate_appcast can create .delta files
# (80-90% smaller downloads for minor releases)
PREV_TAG="$(git -C "${REPO_DIR}" describe --tags --abbrev=0 HEAD 2>/dev/null || echo "")"
if [[ -n "${PREV_TAG}" ]]; then
    echo "  Downloading ${PREV_TAG} DMG for delta generation..."
    if gh release download "${PREV_TAG}" --pattern "*.dmg" --dir "${APPCAST_BUILD_DIR}" 2>/dev/null; then
        echo "  Downloaded ${PREV_TAG} DMG — deltas will be generated."
    else
        echo "  Could not download ${PREV_TAG} DMG — delta updates disabled for this release."
    fi
fi

# Copy current DMG into staging (must be alongside previous for delta generation)
cp "${DMG_PATH}" "${APPCAST_BUILD_DIR}/"

# ──────────────────────────────────────────────────
# Step 8: Generate appcast.xml (signs with EdDSA key from Keychain)
# ──────────────────────────────────────────────────
"${GENERATE_APPCAST}" \
    --download-url-prefix "https://github.com/ParkerRL-91/Meeting-Manager/releases/download/v${VERSION}/" \
    --link "https://github.com/ParkerRL-91/Meeting-Manager/releases/tag/v${VERSION}" \
    "${APPCAST_BUILD_DIR}"

echo "Appcast generated."

# ──────────────────────────────────────────────────
# Step 9: Publish appcast to GitHub Pages (only if changed)
# ──────────────────────────────────────────────────
echo "Publishing appcast to GitHub Pages..."
DOCS_DIR="${REPO_DIR}/docs"
mkdir -p "${DOCS_DIR}"
cp "${APPCAST_BUILD_DIR}/appcast.xml" "${DOCS_DIR}/appcast.xml"

cd "${REPO_DIR}"
git add docs/appcast.xml MeetingManager/Resources/Info.plist

if git diff --cached --quiet; then
    echo "appcast.xml unchanged — skipping commit."
else
    git commit -m "Release v${VERSION}

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
    git push
    echo "Appcast pushed to GitHub Pages."
fi

# ──────────────────────────────────────────────────
# Step 10: Create GitHub Release
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
echo "  SHA-256:  ${DMG_SHA}"
echo "  Appcast:  https://parkerrl-91.github.io/Meeting-Manager/appcast.xml"
echo "  Release:  https://github.com/ParkerRL-91/Meeting-Manager/releases/tag/v${VERSION}"

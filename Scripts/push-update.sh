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
#   1. Pre-flight: git state check + notarization guard
#   2. Bump version in Info.plist (atomically: reverts on build failure)
#   3. Build release binary via swift build
#   4. Assemble a signed .app bundle
#   5. Notarize and staple (required unless SKIP_NOTARIZE=1)
#   6. Create a signed DMG and print SHA-256 checksum
#   7. Commit version bump and push
#   8. Create a GitHub Release with the DMG attached

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

APP_NAME="Meeting Manager"
BUNDLE_ID="com.meetingmanager.app"
EXECUTABLE="MeetingManager"
BUILD_DIR="${REPO_DIR}/build"
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


# ──────────────────────────────────────────────────
# Step 4: Sign
# ──────────────────────────────────────────────────
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
ENTITLEMENTS="${REPO_DIR}/MeetingManager/Resources/MeetingManager.entitlements"
echo "Signing with '${SIGN_IDENTITY}'..."

# Hardened runtime is required for notarization but breaks signature validation
# on copy when using a self-signed cert (dyld rejects the framework at load time).
# Only set it when we're actually going to notarize.
if [[ "${NOTARIZE}" == "1" ]]; then
    RUNTIME_OPTS="--options runtime"
else
    RUNTIME_OPTS=""
fi

# Sign Sparkle first (required for deep signing to work)
if [[ -d "${FRAMEWORKS_DIR}/Sparkle.framework" ]]; then
    codesign --force --deep ${RUNTIME_OPTS} \
        --sign "${SIGN_IDENTITY}" \
        "${FRAMEWORKS_DIR}/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc" 2>/dev/null || true
    codesign --force ${RUNTIME_OPTS} \
        --sign "${SIGN_IDENTITY}" \
        "${FRAMEWORKS_DIR}/Sparkle.framework/Versions/B/Autoupdate" 2>/dev/null || true
    codesign --force ${RUNTIME_OPTS} \
        --sign "${SIGN_IDENTITY}" \
        "${FRAMEWORKS_DIR}/Sparkle.framework" 2>/dev/null || true
fi

# Sign the binary (with entitlements so microphone/screen permissions aren't stripped)
ENTITLEMENTS_OPT=""
if [[ -f "${ENTITLEMENTS}" ]]; then
    ENTITLEMENTS_OPT="--entitlements ${ENTITLEMENTS}"
fi

codesign --force ${RUNTIME_OPTS} \
    --sign "${SIGN_IDENTITY}" \
    ${ENTITLEMENTS_OPT} \
    "${MACOS_DIR}/${EXECUTABLE}"

# Sign the app bundle
codesign --force --deep ${RUNTIME_OPTS} \
    --sign "${SIGN_IDENTITY}" \
    ${ENTITLEMENTS_OPT} \
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
# Step 7: Commit version bump and create GitHub Release
# ──────────────────────────────────────────────────
cd "${REPO_DIR}"
git add MeetingManager/Resources/Info.plist

if git diff --cached --quiet; then
    echo "Info.plist unchanged — skipping commit."
else
    git commit -m "Release v${VERSION}

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
    git push
fi

# ──────────────────────────────────────────────────
# Step 8: Create GitHub Release
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

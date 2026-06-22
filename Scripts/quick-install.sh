#!/bin/bash
# quick-install.sh — Build, install, and launch Meeting Manager.
# Unlike clean-build-dmg.sh, this preserves dependency caches for speed.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="$HOME/Applications/Meeting Manager.app"
BINARY="$APP_BUNDLE/Contents/MacOS/MeetingManager"

echo "=== Quick Install ==="

# 1. Kill running instance
pkill -f "Meeting Manager" 2>/dev/null || true
sleep 1

# 2. Clean MeetingManager-specific build artifacts (keeps dependency cache)
BUILD_DIR="$REPO_DIR/.build/arm64-apple-macosx/release"
rm -rf "$BUILD_DIR/MeetingManager.build" "$BUILD_DIR/MeetingManager" "$REPO_DIR/.build/build.db"

# 3. Build
echo "Building..."
cd "$REPO_DIR"
swift build -c release 2>&1 | tail -3

# 4. Ensure app bundle structure exists
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Frameworks"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# 5. Copy binary
cp "$REPO_DIR/.build/release/MeetingManager" "$BINARY"
chmod +x "$BINARY"

# 6. ALWAYS add the Frameworks rpath (SPM binaries don't have it)
if ! otool -l "$BINARY" | grep -q "@loader_path/../Frameworks"; then
    install_name_tool -add_rpath "@loader_path/../Frameworks" "$BINARY"
fi

# 7. Copy resources
cp "$REPO_DIR/MeetingManager/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$REPO_DIR/MeetingManager/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns" 2>/dev/null || true

# 8. Sign with the pinned self-signed identity (by SHA-1, same as the release
#    build) so local installs never reset the developer's own Microphone /
#    Screen Recording permissions. Signing by hash avoids the
#    "MeetingManager-Dev" vs "MeetingManager-Dev2" name collision. Sparkle was
#    removed, so there are no framework components to sign.
PINNED_SIGN_SHA="${PINNED_SIGN_SHA:-57A1035B19FC882CF723DB2EFF114D8104E50537}"  # MeetingManager-Dev
if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "$PINNED_SIGN_SHA"; then
    echo "ERROR: Pinned signing identity $PINNED_SIGN_SHA not found."
    echo "  Run ./Scripts/setup-signing.sh once to create it. Ad-hoc signing would"
    echo "  reset your Microphone/Screen Recording permissions on every install."
    exit 1
fi
ENTITLEMENTS="$REPO_DIR/MeetingManager/Resources/MeetingManager.entitlements"
codesign --force --options runtime --entitlements "$ENTITLEMENTS" --sign "$PINNED_SIGN_SHA" "$APP_BUNDLE"

# 10. Launch
echo "Launching..."
open "$APP_BUNDLE"

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP_BUNDLE/Contents/Info.plist")
echo "=== Installed v$VERSION ==="

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

# 8. Copy Sparkle if not already there
if [ ! -d "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework" ]; then
    SPARKLE_SRC="$REPO_DIR/.build/arm64-apple-macosx/release/Sparkle.framework"
    [ -d "$SPARKLE_SRC" ] && cp -R "$SPARKLE_SRC" "$APP_BUNDLE/Contents/Frameworks/"
fi

# 9. Sign inside-out
FW="$APP_BUNDLE/Contents/Frameworks"
for xpc in "$FW/Sparkle.framework/Versions/B/XPCServices"/*.xpc; do
    [ -d "$xpc" ] && codesign --force --sign - "$xpc" 2>/dev/null
done
[ -d "$FW/Sparkle.framework/Versions/B/Updater.app" ] && \
    codesign --force --sign - "$FW/Sparkle.framework/Versions/B/Updater.app" 2>/dev/null
[ -f "$FW/Sparkle.framework/Versions/B/Autoupdate" ] && \
    codesign --force --sign - "$FW/Sparkle.framework/Versions/B/Autoupdate" 2>/dev/null
codesign --force --sign - "$FW/Sparkle.framework" 2>/dev/null
codesign --force --sign - "$APP_BUNDLE"

# 10. Launch
echo "Launching..."
open "$APP_BUNDLE"

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP_BUNDLE/Contents/Info.plist")
echo "=== Installed v$VERSION ==="

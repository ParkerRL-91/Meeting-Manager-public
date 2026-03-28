#!/bin/bash
set -euo pipefail

# Meeting Manager Release Build Script
#
# Prerequisites:
#   - Xcode installed with command line tools
#   - Apple Developer ID certificate in Keychain
#   - Sparkle framework integrated via SPM
#   - generate_appcast from Sparkle tools installed
#
# Usage:
#   ./Scripts/build-release.sh [version]
#   Example: ./Scripts/build-release.sh 1.2.0

APP_NAME="Meeting Manager"
BUNDLE_ID="com.meetingmanager.app"
SCHEME="MeetingManager"
BUILD_DIR="build"
ARCHIVE_DIR="${BUILD_DIR}/archive"
EXPORT_DIR="${BUILD_DIR}/export"
DMG_DIR="${BUILD_DIR}/dmg"
APPCAST_DIR="docs/appcast"

# Version from argument or Info.plist
VERSION="${1:-$(defaults read "$(pwd)/MeetingManager/Resources/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "1.0.0")}"

echo "=== Building ${APP_NAME} v${VERSION} ==="

# Step 1: Clean build directory
echo "Cleaning build directory..."
rm -rf "${BUILD_DIR}"
mkdir -p "${ARCHIVE_DIR}" "${EXPORT_DIR}" "${DMG_DIR}" "${APPCAST_DIR}"

# Step 2: Archive
echo "Archiving..."
xcodebuild archive \
    -scheme "${SCHEME}" \
    -archivePath "${ARCHIVE_DIR}/${APP_NAME}.xcarchive" \
    -configuration Release \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    DEVELOPMENT_TEAM="${TEAM_ID:-}" \
    MARKETING_VERSION="${VERSION}" \
    CURRENT_PROJECT_VERSION="$(date +%Y%m%d%H%M)" \
    | xcpretty || true

# Step 3: Export
echo "Exporting..."
cat > "${BUILD_DIR}/ExportOptions.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>${TEAM_ID:-REPLACE_WITH_TEAM_ID}</string>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
    -archivePath "${ARCHIVE_DIR}/${APP_NAME}.xcarchive" \
    -exportPath "${EXPORT_DIR}" \
    -exportOptionsPlist "${BUILD_DIR}/ExportOptions.plist" \
    | xcpretty || true

APP_PATH="${EXPORT_DIR}/${APP_NAME}.app"

# Step 4: Notarize
echo "Notarizing..."
NOTARIZE_ZIP="${BUILD_DIR}/${APP_NAME}-${VERSION}-notarize.zip"
ditto -c -k --keepParent "${APP_PATH}" "${NOTARIZE_ZIP}"

xcrun notarytool submit "${NOTARIZE_ZIP}" \
    --keychain-profile "MeetingManager-Notarize" \
    --wait

xcrun stapler staple "${APP_PATH}"
echo "Notarization complete."

# Step 5: Create DMG
echo "Creating DMG..."
DMG_NAME="${APP_NAME// /-}-${VERSION}.dmg"
DMG_PATH="${DMG_DIR}/${DMG_NAME}"

# Create a temporary DMG folder with the app and Applications symlink
DMG_STAGING="${BUILD_DIR}/dmg-staging"
mkdir -p "${DMG_STAGING}"
cp -R "${APP_PATH}" "${DMG_STAGING}/"
ln -s /Applications "${DMG_STAGING}/Applications"

hdiutil create -volname "${APP_NAME}" \
    -srcfolder "${DMG_STAGING}" \
    -ov -format UDZO \
    "${DMG_PATH}"

echo "DMG created: ${DMG_PATH}"

# Step 6: Generate Sparkle appcast
echo "Generating appcast..."
if command -v generate_appcast &> /dev/null; then
    # Move DMG to appcast directory for generate_appcast to process
    cp "${DMG_PATH}" "${APPCAST_DIR}/"
    generate_appcast "${APPCAST_DIR}"
    echo "Appcast updated at ${APPCAST_DIR}/appcast.xml"
else
    echo "Warning: generate_appcast not found. Install Sparkle tools to auto-generate appcast."
    echo "You can download it from: https://github.com/sparkle-project/Sparkle/releases"
fi

echo ""
echo "=== Release Build Complete ==="
echo "  Version:  ${VERSION}"
echo "  DMG:      ${DMG_PATH}"
echo "  Appcast:  ${APPCAST_DIR}/appcast.xml"
echo ""
echo "Next steps:"
echo "  1. Upload ${DMG_NAME} to GitHub Releases or your CDN"
echo "  2. Upload appcast.xml to your server (URL must match SUFeedURL in Info.plist)"
echo "  3. Announce the release!"

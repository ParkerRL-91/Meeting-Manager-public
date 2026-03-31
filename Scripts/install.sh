#!/bin/bash
# Meeting Manager Installer
# Copies the app to /Applications and removes the quarantine flag
# so macOS Gatekeeper won't block it.

set -euo pipefail

APP_NAME="Meeting Manager"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Find the .app — it's either next to this script or in the DMG root
if [[ -d "${SCRIPT_DIR}/${APP_NAME}.app" ]]; then
    APP_SRC="${SCRIPT_DIR}/${APP_NAME}.app"
else
    # Look one level up (DMG root)
    PARENT="$(dirname "${SCRIPT_DIR}")"
    if [[ -d "${PARENT}/${APP_NAME}.app" ]]; then
        APP_SRC="${PARENT}/${APP_NAME}.app"
    else
        echo "Error: Could not find ${APP_NAME}.app"
        exit 1
    fi
fi

DEST="/Applications/${APP_NAME}.app"

echo ""
echo "  Meeting Manager Installer"
echo "  ========================="
echo ""

# Remove old copy if present
if [[ -d "${DEST}" ]]; then
    echo "  Removing previous installation..."
    rm -rf "${DEST}" 2>/dev/null || {
        echo "  Need admin access to replace existing installation."
        sudo rm -rf "${DEST}"
    }
fi

echo "  Copying to /Applications..."
cp -R "${APP_SRC}" "${DEST}"

echo "  Removing quarantine flag..."
xattr -cr "${DEST}"

echo ""
echo "  Done! Meeting Manager is installed."
echo "  Opening now..."
echo ""

open "${DEST}"

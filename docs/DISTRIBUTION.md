# Meeting Manager — Distribution Guide

## Overview

Meeting Manager is distributed as a signed & notarized DMG, with automatic updates via the Sparkle framework. Users download the DMG, drag the app to Applications, and receive automatic updates thereafter.

## Prerequisites

### Apple Developer Account
- **Cost:** $99/year at [developer.apple.com](https://developer.apple.com)
- **Required for:** Code signing (Developer ID), notarization, and Gatekeeper approval
- You need a **Developer ID Application** certificate

### Sparkle Framework
Already integrated via SPM. Sparkle handles:
- Checking for updates (appcast.xml)
- Downloading new versions
- EdDSA signature verification
- Installing updates seamlessly

### Tools
- Xcode 15+ with command line tools
- `generate_appcast` from [Sparkle releases](https://github.com/sparkle-project/Sparkle/releases)
- `xcnotary` or Xcode's built-in `notarytool`

## Setup (One-Time)

### 1. Generate Sparkle EdDSA Keys

```bash
# Download Sparkle and run the key generator
./bin/generate_keys
```

This outputs a public key. Add it to Info.plist:
```xml
<key>SUPublicEDKey</key>
<string>YOUR_PUBLIC_KEY_HERE</string>
```

Store the private key securely — it signs your updates.

### 2. Set Up Notarization Credentials

```bash
xcrun notarytool store-credentials "MeetingManager-Notarize" \
    --apple-id "your@email.com" \
    --team-id "YOUR_TEAM_ID" \
    --password "app-specific-password"
```

### 3. Configure Appcast URL

In Info.plist, set where your appcast lives:
```xml
<key>SUFeedURL</key>
<string>https://yourdomain.com/appcast.xml</string>
```

Options for hosting:
- **GitHub Pages:** Free, reliable. Host appcast.xml in a `gh-pages` branch
- **GitHub Releases:** Host DMGs as release assets, appcast.xml in repo
- **Your own server/CDN:** Full control

### 4. Configure Info.plist for Updates

Required keys (already in our Info.plist):
```xml
<key>SUFeedURL</key>
<string>https://yourdomain.com/appcast.xml</string>
<key>SUPublicEDKey</key>
<string>your-public-ed-key</string>
<key>SUEnableAutomaticChecks</key>
<true/>
```

## Building a Release

```bash
# Set your Apple Developer Team ID
export TEAM_ID="YOUR_TEAM_ID"

# Build, sign, notarize, create DMG, and update appcast
./Scripts/build-release.sh 1.0.0
```

This produces:
- `build/dmg/Meeting-Manager-1.0.0.dmg` — distributable disk image
- `docs/appcast/appcast.xml` — update feed

## Publishing a Release

### Option A: GitHub Releases (Recommended)

1. Tag the release:
   ```bash
   git tag -a v1.0.0 -m "Release 1.0.0"
   git push origin v1.0.0
   ```

2. Create a GitHub Release and upload the DMG

3. Host `appcast.xml` on GitHub Pages or in the repo

### Option B: Direct Hosting

1. Upload DMG to your CDN
2. Upload `appcast.xml` to your web server
3. Ensure the `SUFeedURL` in Info.plist points to it

## How Updates Work (User Perspective)

1. User downloads DMG from your website/GitHub
2. User drags "Meeting Manager.app" to Applications
3. On launch, Sparkle checks appcast.xml for new versions
4. If update available → shows native macOS update dialog
5. User clicks "Install Update" → downloads, verifies signature, restarts app
6. Fully automatic, no manual download needed

## Versioning

Use semantic versioning:
- **Major** (2.0.0): Breaking changes, major redesign
- **Minor** (1.1.0): New features, backward compatible
- **Patch** (1.0.1): Bug fixes

Update in two places:
- `MARKETING_VERSION` in Xcode project (or pass to build script)
- The build script auto-sets `CURRENT_PROJECT_VERSION` from timestamp

## Troubleshooting

### "App is damaged" warning
- App wasn't notarized. Run `xcrun stapler staple "App.app"` after notarization
- Or user downloaded from untrusted source — re-download from official link

### Updates not showing
- Check `SUFeedURL` is reachable
- Verify appcast.xml has correct version numbers
- Check Console.app for Sparkle logs

### Code signing issues
- Ensure "Developer ID Application" certificate is in Keychain
- Run `codesign --verify --deep "App.app"` to check

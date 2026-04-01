# Distribution Guide

How to build and publish a Meeting Manager release.

## Quick Release

```bash
./Scripts/push-update.sh 1.3.0
```

This single command:
1. Bumps `CFBundleShortVersionString` in Info.plist
2. Runs `swift build -c release`
3. Assembles a signed `.app` bundle (binary + Sparkle.framework + resources)
4. Creates a DMG
5. Generates a signed Sparkle appcast.xml
6. Commits and pushes appcast.xml to GitHub Pages (`docs/`)
7. Creates a GitHub Release with the DMG attached

Add `NOTARIZE=1` to also notarize with Apple:
```bash
NOTARIZE=1 ./Scripts/push-update.sh 1.3.0
```

Notarization requires a keychain profile named `MeetingManager-Notarize`:
```bash
xcrun notarytool store-credentials "MeetingManager-Notarize" \
    --apple-id "your@email.com" \
    --team-id "YOURTEAMID" \
    --password "app-specific-password"
```

---

## Sparkle Update Infrastructure

| Component | Location |
|-----------|----------|
| Appcast feed | `https://parkerrl-91.github.io/Meeting-Manager/appcast.xml` |
| Appcast source | `docs/appcast.xml` (GitHub Pages, `main` branch `/docs` folder) |
| EdDSA public key | `MeetingManager/Resources/Info.plist` → `SUPublicEDKey` |
| EdDSA private key | macOS Keychain (stored by `generate_keys` at first setup) |
| Sparkle tools | `.build/artifacts/sparkle/Sparkle/bin/` |

### Enable GitHub Pages

Go to repo **Settings → Pages → Source**: `main` branch, `/docs` folder. The appcast URL goes live immediately.

### Regenerate Keys (if needed)

```bash
.build/artifacts/sparkle/Sparkle/bin/generate_keys
```

Update `SUPublicEDKey` in Info.plist with the new public key. The private key is saved in Keychain automatically.

---

## Manual DMG Build

```bash
# 1. Build release binary
swift build -c release

# 2. Assemble .app bundle
mkdir -p build/app/Meeting\ Manager.app/Contents/{MacOS,Frameworks,Resources}
cp .build/release/MeetingManager build/app/Meeting\ Manager.app/Contents/MacOS/
cp MeetingManager/Resources/Info.plist build/app/Meeting\ Manager.app/Contents/
rsync -a --exclude="Info.plist" MeetingManager/Resources/ \
    build/app/Meeting\ Manager.app/Contents/Resources/
SPARKLE=$(find .build/artifacts -name "Sparkle.framework" | head -1)
cp -R "$SPARKLE" build/app/Meeting\ Manager.app/Contents/Frameworks/
install_name_tool -add_rpath "@executable_path/../Frameworks" \
    build/app/Meeting\ Manager.app/Contents/MacOS/MeetingManager
codesign --force --deep --sign - build/app/Meeting\ Manager.app

# 3. Create DMG
mkdir -p build/dmg-staging
cp -R build/app/Meeting\ Manager.app build/dmg-staging/
ln -sf /Applications build/dmg-staging/Applications
hdiutil create -volname "Meeting Manager" \
    -srcfolder build/dmg-staging \
    -ov -format UDZO \
    build/Meeting-Manager-1.0.5.dmg
```

---

## Version History

| Version | Date | Notes |
|---------|------|-------|
| 1.0.5 | 2026-03-29 | On-device AI (Ollama auto-install), sidebar redesign, Sparkle update pipeline |

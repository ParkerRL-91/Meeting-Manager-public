# Distribution Guide

How to build and publish a Meeting Manager release. Sparkle was removed in
3.x: updates ship
as GitHub Releases that users download manually — there is no appcast and no
in-app update check.

## Quick Release

```bash
./Scripts/push-update.sh 4.2.0
```

This single command:

1. Pre-flight checks: refuses to run on a dirty working tree; validates the
   version argument; verifies notarization env vars when `NOTARIZE=1`.
2. Bumps `CFBundleShortVersionString` in `MeetingManager/Resources/Info.plist`.
3. Runs `swift build -c release`.
4. Assembles the `.app` bundle (binary + Info.plist + entitlements + assets).
5. Signs the bundle — by default with the local self-signed identity
   (ADR-006); users see a Gatekeeper warning on first launch and bypass it
   with right-click → Open.
6. Creates a DMG and prints its SHA-256.
7. Creates a GitHub Release with the DMG attached.

Validate everything without building or publishing:

```bash
./Scripts/push-update.sh --dry-run 4.2.0
```

## Notarized releases (optional)

With an Apple Developer account, set the signing environment and add
`NOTARIZE=1`:

```bash
TEAM_ID=XXXXXXXXXX APPLE_ID=you@example.com APP_SPECIFIC_PASSWORD=xxxx \
NOTARIZE=1 ./Scripts/push-update.sh 4.2.0
```

Notarization requires a notarytool keychain profile named
`MeetingManager-Notarize`. Without `NOTARIZE=1` the script ships
self-signed and reminds you about the Gatekeeper warning.

## Local install for testing

```bash
./Scripts/install-local.sh
```

Builds release and installs into `~/Applications` without publishing.

## How users update

Users download the new DMG from the GitHub Releases page and replace the app
in `/Applications` (or `~/Applications`). The database, recordings, and
Keychain entries live outside the bundle (`~/Library/Application
Support/MeetingManager/` + Keychain), so replacing the app preserves all
data.

# Building & Running

## Prerequisites

- macOS 14.4+
- Xcode 15+ (for Swift compiler and command line tools)
- Swift 5.9+

Install Xcode command line tools if you don't have Xcode:
```bash
xcode-select --install
```

---

## Clone and Build

```bash
git clone https://github.com/ParkerRL-91/Meeting-Manager.git
cd Meeting-Manager

# Debug build (fast, includes debug symbols)
swift build

# Release build (optimized, ~3× smaller binary)
swift build -c release
```

Build output lands in `.build/debug/` or `.build/release/`.

---

## Running the App

The binary requires a proper `.app` bundle to launch (due to Sparkle and UserNotifications). You can't run `swift run` directly.

**Option A: Install to ~/Applications (recommended for testing)**

```bash
# Build release
swift build -c release

# Assemble and install
mkdir -p ~/Applications/Meeting\ Manager.app/Contents/{MacOS,Frameworks,Resources}
cp .build/release/MeetingManager ~/Applications/Meeting\ Manager.app/Contents/MacOS/
cp MeetingManager/Resources/Info.plist ~/Applications/Meeting\ Manager.app/Contents/
SPARKLE=$(find .build/artifacts -name "Sparkle.framework" | head -1)
cp -R "$SPARKLE" ~/Applications/Meeting\ Manager.app/Contents/Frameworks/
install_name_tool -add_rpath "@executable_path/../Frameworks" \
    ~/Applications/Meeting\ Manager.app/Contents/MacOS/MeetingManager
codesign --force --deep --sign - ~/Applications/Meeting\ Manager.app
open ~/Applications/Meeting\ Manager.app
```

**Option B: Use the Xcode IDE**

Generate an Xcode project (for IDE features like breakpoints and previews):
```bash
# Note: swift package generate-xcodeproj is deprecated but still works
swift package generate-xcodeproj
open MeetingManager.xcodeproj
```

Run from Xcode with ⌘R. The generated project may need manual configuration for entitlements and Info.plist.

---

## Dependencies

All managed by Swift Package Manager. No manual steps needed — SPM resolves on first build.

| Package | Version | Purpose |
|---------|---------|---------|
| GRDB | 6.x | SQLite ORM |
| WhisperKit | 0.9+ | On-device speech-to-text |
| Sparkle | 2.6+ | Auto-updates |

**Important:** WhisperKit pins `swift-transformers` to `1.1.x`. Do not add any dependency that requires `swift-transformers >= 1.2.0` (e.g., mlx-swift-lm) — this creates an irreconcilable SPM conflict. See [ADR-001](../../knowledge/decisions/ADR-001-ollama-over-mlx-for-local-llm.md).

---

## Environment Setup for Development

### Claude API Key
Set in the app under **Settings → Claude → API Key**. Stored in macOS Keychain as `com.meetingmanager.app.claudeApiKey`. Never hardcode or log.

### Google Calendar
OAuth credentials are baked into the bundle (Google OAuth client ID in Info.plist). The OAuth flow runs in-app.

### Ollama (for on-device AI testing)
```bash
brew install ollama
ollama serve          # starts server at localhost:11434
ollama pull llama3.2:3b
```

Or enable **Settings → On-Device** in the app to auto-install.

---

## Code Signing

The app is not sandboxed (`com.apple.security.app-sandbox = false`). For local development, ad-hoc signing works:

```bash
codesign --force --deep --sign - ~/Applications/Meeting\ Manager.app
```

For distribution, use a Developer ID Application certificate. See [DISTRIBUTION.md](../DISTRIBUTION.md).

---

## Common Issues

**`bundleProxyForCurrentProcess is nil`**
Running the binary directly from the command line (not from a `.app` bundle). Always use `open Meeting\ Manager.app` or the install script above.

**Sparkle library not loaded**
The release binary doesn't have the Frameworks rpath. Fix:
```bash
install_name_tool -add_rpath "@executable_path/../Frameworks" \
    Meeting\ Manager.app/Contents/MacOS/MeetingManager
```

**SPM `disk I/O error` on build.db**
Spurious warning from Swift build system — does not affect the build. Ignore it.

**App shows old UI after binary replacement**
macOS caches app bundles. Force a fresh launch:
```bash
pkill -x MeetingManager; sleep 1; open ~/Applications/Meeting\ Manager.app
```

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

The binary requires a proper `.app` bundle to launch (due to UserNotifications). You can't run `swift run` directly.

**Option A: Install to ~/Applications (recommended for testing)**

Use the install script — it builds, assembles the bundle, signs with the
persistent `MeetingManager-Dev` cert (preserves TCC grants across
rebuilds), and relaunches cleanly:

```bash
Scripts/install-local.sh
```

Or assemble manually:

```bash
# Build release
swift build -c release

# Assemble and install
mkdir -p ~/Applications/Meeting\ Manager.app/Contents/{MacOS,Resources}
cp .build/release/MeetingManager ~/Applications/Meeting\ Manager.app/Contents/MacOS/
cp MeetingManager/Resources/Info.plist ~/Applications/Meeting\ Manager.app/Contents/
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
| argmax-oss-swift | 1.0.0 | WhisperKit (on-device speech-to-text) + SpeakerKit (diarization) |
| FluidAudio | 0.14.7 (exact pin) | Alternate diarization + speaker enrollment (behind `useFluidAudioDiarization`) |
| GRDB | 6.29.3 | SQLite ORM |
| swift-argument-parser | 1.8.1 | Transitive (argmax-oss-swift) |

**Note:** MLX and llama.cpp remain banned by policy (ADR-001) — local LLM goes through Ollama's HTTP API. The old `swift-transformers` pin that made the ban mechanical disappeared with the Argmax OSS 1.0.0 upgrade; see the 2026-05-29 update note in the ADR.

---

## Environment Setup for Development

### Claude API Key
Set in the app under **Settings → Claude → API Key**. Stored in the macOS Keychain (service `com.meetingmanager`, account `claude-api-key`). Never hardcode or log.

### Google Calendar
A built-in Google OAuth client ID ships in GoogleAuthManager (a Keychain entry can override it); Info.plist holds only the callback URL scheme. The OAuth flow runs in-app.

### Ollama (for on-device AI testing)
```bash
brew install ollama
ollama serve          # starts server at localhost:11434
ollama pull qwen3:4b  # small tier; qwen3:8b is the default tier
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

**SPM `disk I/O error` on build.db**
Spurious warning from Swift build system — does not affect the build. Ignore it.

**App shows old UI after binary replacement**
macOS caches app bundles. Force a fresh launch:
```bash
pkill -x MeetingManager; sleep 1; open ~/Applications/Meeting\ Manager.app
```

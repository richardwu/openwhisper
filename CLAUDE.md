# OpenWhisper — Agent Guide

## What This Is

macOS menu bar voice-to-text app using local whisper.cpp. Non-sandboxed, SwiftUI, targets macOS 14+.

## Build

```bash
brew install xcodegen
xcodegen generate
xcodebuild -scheme OpenWhisper -configuration Debug -derivedDataPath .build build \
  CODE_SIGN_IDENTITY="Apple Development" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=T2ZTUY8F2X
```

The Xcode project (`*.xcodeproj`) is gitignored — always regenerate with `xcodegen generate` before building.

**Always pass `CODE_SIGN_IDENTITY="Apple Development" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=T2ZTUY8F2X`** when building debug builds. These override the ad-hoc signing in `project.yml` so that macOS preserves Microphone and Accessibility permissions across rebuilds. Without them, every rebuild invalidates granted permissions.

## Architecture

`AppState` is the central `@Observable` orchestrator. Everything flows through it:

```
Hotkey → AudioRecorder (AVAudioEngine, 16kHz mono Float32)
       → TranscriptionService (SwiftWhisper)
       → PasteService (clipboard + CGEvent Cmd+V)
```

Key files:
- `OpenWhisperApp.swift` — App entry point, owns `AppState` + Sparkle updater, sets up MenuBarExtra
- `AppState.swift` — Central state: recording, transcription, overlay lifecycle, hotkey registration
- `Overlay/OverlayState.swift` — Overlay phases: hidden, recording, transcribing, cancelled, accessibilityRequired
- `Overlay/OverlayController.swift` — NSPanel management for the floating overlay
- `Views/MenuBarMenuView.swift` — Menu bar dropdown; dynamically reads hotkey from KeyboardShortcuts
- `Views/ShortcutRecorder.swift` — Custom recorder that captures Escape and other keys the built-in KeyboardShortcuts.Recorder intercepts
- `Hotkey/HotkeyNames.swift` — Default hotkey definitions (Cmd+' for toggle, Escape for cancel)
- `Transcription/ModelManager.swift` — Downloads ggml-base.en model (~148MB) from HuggingFace on first launch

## Key Nuances

### Project Generation
- `project.yml` is the source of truth — never edit the `.xcodeproj` directly
- Info.plist keys (SUFeedURL, SUPublicEDKey, etc.) are managed in `project.yml` under `info.properties`, not in `Info.plist` directly (xcodegen merges them)

### Code Signing
- `project.yml` uses `CODE_SIGN_IDENTITY: "-"` (ad-hoc) so anyone can clone and build
- CI overrides with `Developer ID Application` at build time via xcodebuild args
- No `DEVELOPMENT_TEAM` or `CODE_SIGN_STYLE` in project.yml — CI provides these
- To build locally with a dev cert (persists Accessibility/Microphone permissions across rebuilds):
  ```bash
  xcodebuild ... CODE_SIGN_IDENTITY="Apple Development" CODE_SIGN_STYLE=Manual
  ```
- Ad-hoc signed builds lose granted permissions every rebuild — use a real cert during development

### Non-Sandboxed
- Required for `CGEvent` paste simulation (Accessibility API)
- Entitlements only has `com.apple.security.device.audio-input`
- User must manually grant Accessibility permission in System Settings

### Sparkle Auto-Updates
- `SPUStandardUpdaterController` is created in `OpenWhisperApp.swift`
- `SUPublicEDKey` in project.yml is `TO_BE_GENERATED` — needs one-time `generate_keys` run
- Menu bar has "Check for Updates..." item

### ShortcutRecorder (Custom)
- We use a custom `ShortcutRecorder` instead of `KeyboardShortcuts.Recorder` because the built-in one intercepts Escape (used as cancel hotkey)
- Uses `NSEvent.addLocalMonitorForEvents` to capture raw key events
- Key display uses `UCKeyTranslate` for proper character mapping

### Menu Bar Hotkey Sync
- The recording button in `MenuBarMenuView` dynamically reads the configured shortcut via `KeyboardShortcuts.getShortcut(for:)` and converts it to SwiftUI's `.keyboardShortcut()` modifier
- Conversion helpers are in a `@MainActor` extension on `KeyboardShortcuts.Shortcut` (same file)

### Overlay System
- `RecordingOverlayPanel` is an `NSPanel` (floating, non-activating) positioned at bottom-center of the active screen
- Phases: recording (waveform + red dot), transcribing (spinner), cancelled (X + text, auto-dismiss 0.8s), accessibilityRequired (red X + prompt, auto-dismiss 3s)

### Launch at Login
- Uses `SMAppService.mainApp` (ServiceManagement framework, macOS 13+)
- Toggle in Settings reverts on failure

## CI

- `.github/workflows/build.yml` — CI build on push/PR to main

## Releasing

Releases are created locally via `bin/create_release`:

```bash
bin/create_release 0.2.0
```

The script handles: xcodegen → archive → code sign (Developer ID) → notarize → DMG → Sparkle sign → appcast.xml → GitHub Release.

Prerequisites:
- `Developer ID Application` certificate in keychain
- Sparkle EdDSA key (`generate_keys` from Sparkle SPM artifact)
- Notarization credentials stored via `xcrun notarytool store-credentials notarytool`
- CLI tools: `xcodegen`, `create-dmg`, `gh`

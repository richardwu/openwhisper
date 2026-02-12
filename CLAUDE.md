# OpenWhisper — Agent Guide

## What This Is

macOS menu bar voice-to-text app using local whisper.cpp. Non-sandboxed, SwiftUI, targets macOS 14+.

## Build

```bash
brew install xcodegen
xcodegen generate
xcodebuild -scheme OpenWhisper -configuration Debug -derivedDataPath .build build
```

The Xcode project (`*.xcodeproj`) is gitignored — always regenerate with `xcodegen generate` before building.

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

## GitHub Actions

- `.github/workflows/build.yml` — CI build on push/PR to main
- `.github/workflows/release.yml` — Full release on `v*` tags: sign, notarize, DMG, Sparkle, GitHub Release upload
- Required secrets: `DEVELOPER_ID_P12_BASE64`, `DEVELOPER_ID_P12_PASSWORD`, `APPLE_ID`, `APPLE_APP_PASSWORD`, `APPLE_TEAM_ID`, `SPARKLE_PRIVATE_KEY`

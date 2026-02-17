# OpenWhisper

<video src="https://github.com/user-attachments/assets/9ccbc298-e9fa-459e-b9e2-fca64d6a6160" width="100%" autoplay loop muted playsinline></video>

Local, private voice-to-text for macOS. Lives in your menu bar, transcribes with [whisper.cpp](https://github.com/ggerganov/whisper.cpp), and pastes the result directly into any app.

## Install

Download the latest `.dmg` from the [Releases](https://github.com/richardwu/openwhisper/releases) page — open it, drag OpenWhisper to Applications, and you're done.

## Features

- **Fully local & private** — audio never leaves your machine
- **whisper.cpp** via [SwiftWhisper](https://github.com/exPHAT/SwiftWhisper) for fast, accurate transcription
- **Global hotkey** — start/stop recording from anywhere
- **Auto-paste** — transcribed text is pasted into the active app automatically
- **Transcription history** — review and copy past transcriptions
- **Auto-updates** via [Sparkle](https://sparkle-project.org)

## Requirements

- macOS 14.0+ (Sonoma)
- Xcode 16+
- [xcodegen](https://github.com/yonaskolb/XcodeGen)

## Build from Source

```bash
brew install xcodegen
git clone https://github.com/richardwu/openwhisper
cd openwhisper
xcodegen generate
xcodebuild -scheme OpenWhisper -configuration Debug -derivedDataPath .build build
open .build/Build/Products/Debug/OpenWhisper.app
```

To sign with your own Apple Development certificate (persists permissions across rebuilds):

```bash
xcodebuild -scheme OpenWhisper -configuration Debug -derivedDataPath .build build \
  CODE_SIGN_IDENTITY="Apple Development" \
  CODE_SIGN_STYLE=Manual
```

On first launch of a dev build the app will download the Whisper model (~148 MB) if not already bundled. You'll also need to grant:

- **Microphone** access (prompted automatically)
- **Accessibility** access (System Settings > Privacy & Security > Accessibility) for auto-paste

## Usage

1. Click the waveform icon in the menu bar, or use the global hotkey
2. Speak — a recording overlay appears
3. Stop recording — transcription runs locally, then the text is pasted into the frontmost app
4. View transcription history from the main window

### Global Hotkeys

| Action | Default |
|--------|---------|
| Start/stop recording | `Cmd+'` |
| Cancel recording | `Escape` |

Hotkeys can be customized in the main window's settings tab.

## Pre-built Binaries

Signed and notarized `.dmg` releases are published on the [Releases](https://github.com/richardwu/openwhisper/releases) page. These bundle the Whisper model and require no Xcode or developer tools — just download, open, and drag to Applications.

Building pre-built binaries requires an Apple Developer ID Application certificate ($99/year Apple Developer Program).

## License

MIT

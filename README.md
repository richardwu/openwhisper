# OpenWhisper

Local, private voice-to-text for macOS. Lives in your menu bar, transcribes with [whisper.cpp](https://github.com/ggerganov/whisper.cpp), and pastes the result directly into any app.

## Features

- **Fully local** — audio never leaves your machine
- **whisper.cpp** via [SwiftWhisper](https://github.com/exPHAT/SwiftWhisper) for fast, accurate transcription
- **Menu bar app** — always accessible, stays out of your way
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
cd open-whisper-claude
xcodegen generate
open OpenWhisper.xcodeproj
```

Build and run from Xcode (Cmd+R). The app will auto-sign for local development.

On first launch the app will download the Whisper model (~148 MB). You'll also need to grant:

- **Microphone** access (prompted automatically)
- **Accessibility** access (System Settings > Privacy & Security > Accessibility) for auto-paste

## Usage

1. Click the waveform icon in the menu bar, or use the global hotkey
2. Speak — a recording overlay appears
3. Stop recording — transcription runs locally, then the text is pasted into the frontmost app
4. View transcription history from the main window

### Global Hotkey

Configure the recording hotkey in the main window's settings tab.

## Pre-built Binaries

Signed and notarized `.dmg` releases are published on the [Releases](https://github.com/richardwu/openwhisper/releases) page. These require no Xcode or developer tools — just download, open, and drag to Applications.

Building pre-built binaries requires an Apple Developer ID Application certificate ($99/year Apple Developer Program).

## License

MIT

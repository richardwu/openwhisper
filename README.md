# OpenWhisper

<video src="https://github.com/user-attachments/assets/9ccbc298-e9fa-459e-b9e2-fca64d6a6160" width="100%" autoplay loop muted playsinline></video>

Local, private voice-to-text for macOS. OpenWhisper lives in your menu bar, transcribes with your choice of on-device models, and pastes the result into your active app.

## Install

Download the latest `.dmg` from the [Releases](https://github.com/richardwu/openwhisper/releases) page — open it, drag OpenWhisper to Applications, and you're done.

## Features

- **Local transcription** — audio and transcription stay on your Mac.
- **Live previews** — streaming models transcribe while you speak. Whisper models transcribe after recording stops.
- **13 model options** — Apple Speech, Parakeet, Moonshine, Nemotron, Voxtral, and four Whisper sizes.
- **Custom vocabulary** — pin names and jargon, add comma-separated terms, search, and remove entries. The built-in dictionary and pinned terms correct previews and final text locally.
- **Two recording modes** — press once to start and again to stop, or hold the shortcut and release to transcribe. Escape cancels recording or processing.
- **Auto-paste and history** — paste into your active app, then review, copy, or delete past transcriptions. Copy the latest result from the window footer.
- **Model and language settings** — search the model picker, see download status, and choose a supported language. Language preferences are saved per model.
- **Auto-updates** via [Sparkle](https://sparkle-project.org).

## Screenshots

<table>
  <tr>
    <th>History</th>
    <th>Vocabulary</th>
    <th>Settings</th>
  </tr>
  <tr>
    <td><img src="https://raw.githubusercontent.com/richardwu/openwhisper/c599186de37b371706bbbf205f6d51b47ef8c063/docs/images/history.png" alt="Production OpenWhisper history with copy and delete controls" width="300" /></td>
    <td><img src="https://raw.githubusercontent.com/richardwu/openwhisper/c599186de37b371706bbbf205f6d51b47ef8c063/docs/images/vocabulary.png" alt="Production OpenWhisper vocabulary editor for names and jargon" width="300" /></td>
    <td><img src="https://raw.githubusercontent.com/richardwu/openwhisper/c599186de37b371706bbbf205f6d51b47ef8c063/docs/images/settings.png" alt="Production OpenWhisper settings with recording modes, shortcuts, and Parakeet Unified" width="300" /></td>
  </tr>
</table>

*OpenWhisper keeps transcription on your Mac: review and copy your history, pin names and jargon for better spelling, and choose your recording mode, hotkeys, model, and language. Screenshots show the production app, version 0.5.0.*

## Models

Select a model in **Settings → Voice Model**. Streaming models produce live previews; batch models process the recording after you stop.

| Model | Mode | Languages in OpenWhisper | Approximate download |
| --- | --- | --- | --- |
| Apple Speech | Streaming | Languages available through Apple Speech on your Mac | Managed by macOS |
| Parakeet Unified 0.6B | Streaming | English | 609 MB |
| Moonshine Tiny / Small / Medium | Streaming | English | 50 / 199 / 296 MB |
| Nemotron Speech EN 0.6B | Streaming | English | 475 MB |
| Nemotron 3.5 ASR 0.6B | Streaming | 28 languages, plus automatic detection | 496 MB |
| Voxtral Mini 4B Realtime | Streaming | 13 languages, plus automatic detection | 2.8 GB |
| Multitalker Parakeet 0.6B | Streaming | English; no speaker labels | 617 MB |
| Whisper Base / Small / Medium / Large | Batch | 99 languages, plus automatic detection | 148 / 163 / 568 MB / 1.1 GB |

Apple Speech requires macOS 26 or later and an available on-device SpeechTranscriber. New installations use Apple Speech when available; otherwise they use Whisper Small. Existing model selections are preserved.

Model files download when needed and remain on your Mac. An internet connection is needed for initial downloads and updates. Whisper Large uses **large-v2**; large-v3 and Turbo are not selectable. See the [model catalog](docs/local-model-catalog.md) for runtimes, language restrictions, and models that are not yet integrated.

The picker’s accuracy and speed scores are relative scores from Handy’s catalog. They are not percentage accuracy or measured performance on your Mac.

## Requirements

- macOS 14.0+ (Sonoma). Apple Speech requires macOS 26+.
- Microphone permission for recording.
- Accessibility permission for automatic paste.
- Xcode 16+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen) only when building from source.

## Build from Source

```bash
brew install xcodegen
git clone https://github.com/richardwu/openwhisper
cd openwhisper
xcodegen generate
xcodebuild -scheme OpenWhisper -configuration Debug -derivedDataPath .build build
open ".build/Build/Products/Debug/OpenWhisper (Dev).app"
```

To sign with your own Apple Development certificate (persists permissions across rebuilds):

```bash
xcodebuild -scheme OpenWhisper -configuration Debug -derivedDataPath .build build \
  CODE_SIGN_IDENTITY="Apple Development" \
  CODE_SIGN_STYLE=Manual
```

`Debug` builds use the bundle ID `com.openwhisper.OpenWhisper.dev` and appear as `OpenWhisper (Dev)`, so they can coexist with the installed production app and keep separate TCC permissions/user defaults.

On first launch, OpenWhisper prepares the selected model and downloads its files if needed. You'll also need to grant:

- **Microphone** access (prompted automatically)
- **Accessibility** access (System Settings > Privacy & Security > Accessibility) for auto-paste

Run `scripts/test_background.sh` for checks without cursor input or visible windows. See [UI testing](docs/ui-testing.md) for native click tests, real-model checks and coverage boundaries.

## Usage

1. Click the waveform icon in the menu bar, or use the global hotkey
2. Speak — a recording overlay appears
3. With a streaming model, follow the live text preview while you speak
4. Stop recording — the overlay shows **Processing...** until the final text is ready, then OpenWhisper pastes it into the frontmost app
5. Review history, manage vocabulary, and choose models from the main window

### Global Hotkeys

| Action | Default |
|--------|---------|
| Start/stop recording | `Cmd+'` |
| Cancel recording | `Escape` |

Hotkeys can be customized in the main window's settings tab. Choose **Toggle** (default) to press once to start and again to stop, or **Press & Hold** to record while holding the hotkey and transcribe on release.

## Pre-built Binaries

Signed and notarized `.dmg` releases are published on the [Releases](https://github.com/richardwu/openwhisper/releases) page. They require no Xcode or developer tools. Download, open, and drag to Applications; OpenWhisper prepares or downloads the selected model when needed.

Building pre-built binaries requires an Apple Developer ID Application certificate ($99/year Apple Developer Program).

## License

MIT

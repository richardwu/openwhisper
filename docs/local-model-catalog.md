# Local model catalog

OpenWhisper supports Apple SpeechTranscriber, FluidAudio Parakeet Unified,
Handy's transcribe.cpp streaming families, and Whisper checkpoints through
SwiftWhisper. Every backend runs on the Mac.

Handy's current local model set includes Parakeet Unified, Moonshine Streaming,
SenseVoice, Canary, GigaAM, Breeze ASR, Multitalker Parakeet, and newer families
such as Nemotron Streaming and Voxtral Realtime. Those checkpoints use Core ML
or Handy's `transcribe.cpp` GGUF runtime. OpenWhisper exposes eight Handy-family
streaming models through FluidAudio or the vendored TranscribeCpp Swift package:

- Parakeet Unified through FluidAudio (English-only).
- Moonshine Streaming Tiny, Small, and Medium.
- Nemotron Speech Streaming EN 0.6B.
- Nemotron 3.5 ASR Streaming 0.6B, with its supported BCP-47 locale list.
- Voxtral Mini 4B Realtime. Selecting it downloads a GGUF file of about 2.8 GB.
- Multitalker Parakeet Streaming 0.6B. OpenWhisper uses the transcript stream;
  speaker diarization is not exposed by the Swift binding.

The following families remain catalog-only because OpenWhisper has no matching
batch adapter yet:

- Parakeet V3. A FluidAudio batch service and model assets are still needed.
- SenseVoice. FluidAudio Core ML assets and a batch service are still needed.
- Canary, GigaAM, and Breeze ASR. The native runtime can host these families,
  but OpenWhisper still needs a batch adapter and model integration.

These pending entries are future batch work. They are not claims that the model
architectures cannot run locally. Each family needs model assets, an adapter,
and an end-to-end local test before it can enter the picker.

The first additional compatible checkpoint is Whisper large-v2 q5_0. It uses
the existing SwiftWhisper runtime and downloads from the official whisper.cpp
Hugging Face repository. Whisper large-v3 and large-v3-turbo are deliberately
not selectable: their newer model/runtime requirements need a modern
whisper.cpp adapter and a separate validation pass.

Potential future backends:

- [FluidAudio](https://github.com/FluidInference/FluidAudio) for local Core ML
  Parakeet TDT, Parakeet EOU, SenseVoice, and Nemotron models. Parakeet Unified
  is already selectable. Its model cache is
  `~/Library/Application Support/FluidAudio/Models/`.
  FluidAudio 0.17.5 manages these downloads and its cache checks. OpenWhisper
  does not pin or verify the Core ML weight files itself; it trusts
  FluidAudio's model publisher and download mechanism. The app's GGUF and
  Whisper downloads instead use pinned revisions and SHA-256 checks.
- [Handy transcribe.cpp](https://github.com/handy-computer/transcribe.cpp) for
  Moonshine Streaming, Nemotron, Voxtral Realtime, Multitalker Parakeet, and
  other GGUF model families. The streaming families above are selectable
  through the local TranscribeCpp package.

The vendored package contains Handy's macOS universal `TranscribeCpp.xcframework`
and its Swift wrapper. The app downloads only the selected GGUF checkpoint to
`~/Library/Application Support/OpenWhisper/Models/`; inference stays local.

Parakeet Unified uses FluidAudio's `StreamingUnifiedAsrManager`. The service
feeds 16 kHz microphone buffers as they arrive, calls
`processBufferedAudio()`, and publishes partial text before recording stops.
The model is English-only. The transcribe.cpp streaming services feed the same
16 kHz buffers to each native stream extension. The picker marks Moonshine,
Nemotron Speech Streaming EN, and Multitalker Parakeet as English-only.
Nemotron 3.5 receives the selected BCP-47 locale. Voxtral Realtime accepts auto
detection or an explicit language hint. OpenWhisper applies local vocabulary
correction to live updates, then runs the final text through the shared filter
once.

Before adding a picker entry, the backend must pass the same local audio,
vocabulary, cancellation and end-to-end paste tests as the existing models.

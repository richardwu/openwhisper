import Foundation

/// Local ASR models identified during the Handy model audit.
///
/// The app supports Apple SpeechTranscriber, FluidAudio/Core ML Parakeet
/// Unified, Handy's transcribe.cpp streaming families, and
/// SwiftWhisper/whisper.cpp. `supportedHandyModels` lists model families that
/// are wired into the picker. `pendingHandyModels` records Handy families
/// that still need a batch adapter or model asset integration.
enum LocalModelCatalog {
    enum Runtime: String, Equatable, Sendable {
        case fluidAudioCoreML
        case transcribeCpp
    }

    struct Entry: Equatable, Sendable {
        let identifier: String
        let displayName: String
        let runtime: Runtime
        let sourceURL: URL
        let reasonUnavailable: String
    }

    /// Handy-family model now exposed by the picker through FluidAudio.
    static let supportedHandyModels: [Entry] = [
        Entry(
            identifier: "parakeet-unified",
            displayName: "Parakeet Unified",
            runtime: .fluidAudioCoreML,
            sourceURL: URL(string: "https://github.com/FluidInference/FluidAudio")!,
            reasonUnavailable: ""
        ),
        Entry(
            identifier: "moonshine-streaming-tiny",
            displayName: "Moonshine Streaming Tiny",
            runtime: .transcribeCpp,
            sourceURL: URL(string: "https://github.com/handy-computer/transcribe.cpp")!,
            reasonUnavailable: ""
        ),
        Entry(
            identifier: "moonshine-streaming-small",
            displayName: "Moonshine Streaming Small",
            runtime: .transcribeCpp,
            sourceURL: URL(string: "https://github.com/handy-computer/transcribe.cpp")!,
            reasonUnavailable: ""
        ),
        Entry(
            identifier: "moonshine-streaming-medium",
            displayName: "Moonshine Streaming Medium",
            runtime: .transcribeCpp,
            sourceURL: URL(string: "https://github.com/handy-computer/transcribe.cpp")!,
            reasonUnavailable: ""
        ),
        Entry(
            identifier: "nemotron-speech-streaming-en-0.6b",
            displayName: "Nemotron Speech Streaming EN 0.6B",
            runtime: .transcribeCpp,
            sourceURL: URL(string: "https://huggingface.co/handy-computer/nemotron-speech-streaming-en-0.6b-gguf")!,
            reasonUnavailable: ""
        ),
        Entry(
            identifier: "nemotron-3.5-asr-streaming-0.6b",
            displayName: "Nemotron 3.5 ASR Streaming 0.6B",
            runtime: .transcribeCpp,
            sourceURL: URL(string: "https://huggingface.co/handy-computer/nemotron-3.5-asr-streaming-0.6b-gguf")!,
            reasonUnavailable: ""
        ),
        Entry(
            identifier: "voxtral-mini-4b-realtime",
            displayName: "Voxtral Mini 4B Realtime",
            runtime: .transcribeCpp,
            sourceURL: URL(string: "https://huggingface.co/handy-computer/Voxtral-Mini-4B-Realtime-2602-gguf")!,
            reasonUnavailable: ""
        ),
        Entry(
            identifier: "multitalker-parakeet-streaming-0.6b-v1",
            displayName: "Multitalker Parakeet Streaming 0.6B",
            runtime: .transcribeCpp,
            sourceURL: URL(string: "https://huggingface.co/handy-computer/multitalker-parakeet-streaming-0.6b-v1-gguf")!,
            // Single-speaker transcription is supported; the Swift binding does not expose diarization.
            reasonUnavailable: ""
        ),
    ]

    /// Popular Handy model families that still need a batch adapter or model
    /// asset integration. The vendored transcribe.cpp binary supports several
    /// of these architectures, but the app has no matching service yet.
    static let pendingHandyModels: [Entry] = [
        Entry(
            identifier: "parakeet-v3",
            displayName: "Parakeet V3",
            runtime: .fluidAudioCoreML,
            sourceURL: URL(string: "https://github.com/FluidInference/FluidAudio")!,
            reasonUnavailable: "Requires a batch Parakeet backend and streaming integration."
        ),
        Entry(
            identifier: "sensevoice",
            displayName: "SenseVoice",
            runtime: .fluidAudioCoreML,
            sourceURL: URL(string: "https://github.com/FluidInference/FluidAudio")!,
            reasonUnavailable: "Requires FluidAudio CoreML model assets and backend integration."
        ),
        Entry(
            identifier: "canary",
            displayName: "Canary",
            runtime: .transcribeCpp,
            sourceURL: URL(string: "https://github.com/handy-computer/transcribe.cpp")!,
            reasonUnavailable: "The native runtime supports Canary, but OpenWhisper has no batch adapter yet."
        ),
        Entry(
            identifier: "gigaam",
            displayName: "GigaAM",
            runtime: .transcribeCpp,
            sourceURL: URL(string: "https://github.com/handy-computer/transcribe.cpp")!,
            reasonUnavailable: "The native runtime supports GigaAM, but OpenWhisper has no batch adapter yet."
        ),
        Entry(
            identifier: "breeze-asr",
            displayName: "Breeze ASR",
            runtime: .transcribeCpp,
            sourceURL: URL(string: "https://github.com/handy-computer/transcribe.cpp")!,
            reasonUnavailable: "The native runtime supports Breeze ASR, but OpenWhisper has no batch adapter yet."
        ),
    ]
}

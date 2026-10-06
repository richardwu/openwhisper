import Foundation
import SwiftWhisper
import TranscribeCpp

/// Streaming extension selected for a transcribe.cpp model family.
///
/// The GGUF architecture identifies the model, but several streaming families
/// need a matching stream extension to select their latency and cache policy.
enum TranscribeCppStreamFamily: Sendable {
    case moonshineStreaming
    case nemotronSpeechStreaming
    case nemotron35Streaming
    case voxtralRealtime
    case parakeetBuffered
    case multitalkerParakeetStreaming

    var displayName: String {
        switch self {
        case .moonshineStreaming: return "Moonshine"
        case .nemotronSpeechStreaming: return "Nemotron Speech Streaming"
        case .nemotron35Streaming: return "Nemotron 3.5 ASR Streaming"
        case .voxtralRealtime: return "Voxtral Realtime"
        case .parakeetBuffered: return "Parakeet"
        case .multitalkerParakeetStreaming: return "Multitalker Parakeet"
        }
    }

    var streamExtension: TranscribeCpp.StreamExtension {
        switch self {
        case .moonshineStreaming:
            return .moonshineStreaming(.init())
        case .nemotronSpeechStreaming, .nemotron35Streaming,
             .multitalkerParakeetStreaming:
            return .parakeetStream(.init())
        case .voxtralRealtime:
            return .voxtralRealtime(.init())
        case .parakeetBuffered:
            return .parakeetBuffered(.init())
        }
    }
}

/// Runs a streaming model from Handy's transcribe.cpp model families through
/// the local runtime. The native stream owns all model work on a detached worker so the
/// microphone and menu-bar UI remain responsive while partial text is decoded.
///
/// Publishes raw decoder text. The shared router corrects live previews;
/// TranscriptionService filters and corrects final text before paste/history.
@MainActor
final class TranscribeCppStreamingTranscriptionService: StreamingTranscriptionService {
    var onPartialText: ((String) -> Void)?
    var onFailure: ((Error) -> Void)?

    private let modelURLProvider: @MainActor () -> URL?
    private let vocabularyStore: VocabularyStore?
    private let family: TranscribeCppStreamFamily
    private var configuredModelURL: URL?
    /// Shared by production decoders, owned by their environment rather than
    /// process globals so native resources are released before Metal shutdown.
    final class ModelCache {
        var model: TranscribeCpp.Model?
        var url: URL?
        private(set) var generation = 0

        func invalidate() {
            generation &+= 1
            let previous = model
            model = nil
            url = nil
            Task.detached { withExtendedLifetime(previous) {} }
        }
    }
    private let modelCache: ModelCache
    private var configuredLanguage: WhisperLanguage = .english

    private var frameContinuation: AsyncStream<[Float]>.Continuation?
    private var worker: Task<Void, Never>?
    private var cleanupWorker: Task<Void, Never>?
    private var completion: CheckedContinuation<String, Error>?
    private var completedResult: Result<String, Error>?
    private var nativeCancellationToken: TranscribeCpp.CancellationToken?
    private var didFail = false
    private var generation = 0

    init(
        modelURLProvider: @escaping @MainActor () -> URL?,
        vocabularyStore: VocabularyStore? = nil,
        family: TranscribeCppStreamFamily = .moonshineStreaming,
        modelCache: ModelCache = ModelCache()
    ) {
        self.modelURLProvider = modelURLProvider
        self.vocabularyStore = vocabularyStore
        self.family = family
        self.modelCache = modelCache
    }

    func configure(language: WhisperLanguage) {
        configure(language: language, modelURL: nil)
    }

    func configure(language: WhisperLanguage, modelURL: URL?) {
        configuredLanguage = language
        configuredModelURL = modelURL ?? modelURLProvider()
    }

    func begin() {
        cancel()
        let previousWorker = cleanupWorker
        let currentGeneration = generation
        completedResult = nil
        didFail = false

        guard let modelURL = configuredModelURL ?? modelURLProvider() else {
            let error = Self.unavailableError("\(family.displayName) model is not downloaded")
            complete(result: .failure(error), generation: currentGeneration)
            return
        }

        let (frames, continuation) = AsyncStream<[Float]>.makeStream()
        frameContinuation = continuation
        let language = configuredLanguage
        let family = family
        let candidateTerms = vocabularyStore?.nativeTerms ?? []
        let cacheGeneration = modelCache.generation
        let cachedModel = modelCache.url == modelURL ? modelCache.model : nil
        let cancellationToken = TranscribeCpp.CancellationToken()
        nativeCancellationToken = cancellationToken

        worker = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                await previousWorker?.value
                try Task.checkCancellation()
                let model = try cachedModel ?? TranscribeCpp.Model(path: modelURL.path)
                await self?.cache(model, at: modelURL, generation: currentGeneration, cacheGeneration: cacheGeneration)
                try Task.checkCancellation()
                let runLanguage: String? = language.transcribeCppLanguageCode(for: family)
                // Only pass native vocabulary when the loaded model advertises
                // the feature. The local correction pass still handles every
                // family, including models with no native biasing support.
                let vocabulary = model.supports(.vocabulary) ? candidateTerms : []
                let runOptions = TranscribeCpp.RunOptions(
                    language: runLanguage,
                    vocabulary: vocabulary
                )
                let session = try model.session()
                session.setCancellationToken(cancellationToken)
                let stream = try session.stream(
                    runOptions,
                    TranscribeCpp.StreamOptions(
                        commitPolicy: .auto,
                        family: family.streamExtension
                    )
                )

                var lastPartial = ""
                for await frame in frames {
                    try Task.checkCancellation()
                    _ = try stream.feed(frame)
                    let text = stream.text.display
                    guard !text.isEmpty, text != lastPartial else { continue }
                    lastPartial = text
                    await self?.publish(text, generation: currentGeneration)
                }

                try Task.checkCancellation()
                _ = try stream.finalize()
                // The stable display text can lag the final family post-
                // processing by one suffix. Read the finalized transcript
                // snapshot so the text pasted into the target app is complete.
                let text = stream.snapshot.text
                await self?.complete(result: .success(text), generation: currentGeneration)
            } catch is CancellationError {
                await self?.complete(result: .failure(CancellationError()), generation: currentGeneration)
            } catch {
                await self?.complete(result: .failure(error), generation: currentGeneration)
            }
        }
    }

    func append(audioFrames: [Float]) {
        guard !audioFrames.isEmpty, !didFail else { return }
        frameContinuation?.yield(audioFrames)
    }

    func finish() async throws -> String {
        guard worker != nil || completedResult != nil else {
            throw Self.unavailableError("\(family.displayName) streaming did not start")
        }

        frameContinuation?.finish()
        frameContinuation = nil

        if let completedResult {
            return try completedResult.get()
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if let completedResult = self.completedResult {
                    continuation.resume(with: completedResult)
                } else {
                    self.completion = continuation
                }
            }
        } onCancel: {
            // `onCancel` runs outside the main actor. Hop back before
            // touching the actor-isolated stream state.
            Task { @MainActor [weak self] in
                self?.cancel()
            }
        }
    }

    func cancel() {
        generation &+= 1
        frameContinuation?.finish()
        frameContinuation = nil
        cleanupWorker = worker ?? cleanupWorker
        cleanupWorker?.cancel()
        nativeCancellationToken?.cancel()
        nativeCancellationToken = nil
        worker = nil
        completion?.resume(throwing: CancellationError())
        completion = nil
        completedResult = nil
        didFail = false
    }

    private func cache(_ model: TranscribeCpp.Model, at url: URL, generation: Int, cacheGeneration: Int) {
        guard generation == self.generation, cacheGeneration == modelCache.generation else { return }
        // Keep one checkpoint across all backend instances. Release native
        // weights on a worker when another checkpoint replaces the cache.
        let previous = modelCache.model
        modelCache.model = model
        modelCache.url = url
        Task.detached { withExtendedLifetime(previous) {} }
    }

    private func publish(_ text: String, generation: Int) {
        guard generation == self.generation, !text.isEmpty else { return }
        onPartialText?(text)
    }

    private func complete(result: Result<String, Error>, generation: Int) {
        guard generation == self.generation else { return }
        frameContinuation?.finish()
        frameContinuation = nil
        if case .failure = result { didFail = true }
        completedResult = result
        nativeCancellationToken = nil
        // A resumed caller may begin again before native stream teardown.
        cleanupWorker = worker ?? cleanupWorker
        worker = nil
        if let completion {
            self.completion = nil
            completion.resume(with: result)
        }
        if case .failure(let error) = result, !(error is CancellationError) {
            onFailure?(error)
        }
    }

    private static func unavailableError(_ message: String) -> NSError {
        NSError(
            domain: "OpenWhisper.TranscribeCpp",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

private extension WhisperLanguage {
    /// Converts the app's Whisper language identifiers to the language hints
    /// expected by each transcribe.cpp family. Nemotron 3.5 requires an exact
    /// BCP-47 locale, while the other streaming families accept short codes.
    func transcribeCppLanguageCode(for family: TranscribeCppStreamFamily) -> String? {
        switch family {
        case .nemotron35Streaming:
            switch self {
            case .auto:
                return nil
            case .english: return "en-US"
            case .chinese: return "zh-CN"
            case .german: return "de-DE"
            case .spanish: return "es-ES"
            case .russian: return "ru-RU"
            case .korean: return "ko-KR"
            case .french: return "fr-FR"
            case .japanese: return "ja-JP"
            case .portuguese: return "pt-PT"
            case .turkish: return "tr-TR"
            case .polish: return "pl-PL"
            case .dutch: return "nl-NL"
            // The model advertises ar-AR as its Arabic token (not a country selection).
            // https://huggingface.co/handy-computer/nemotron-3.5-asr-streaming-0.6b-gguf
            case .arabic: return "ar-AR"
            case .swedish: return "sv-SE"
            case .italian: return "it-IT"
            case .hindi: return "hi-IN"
            case .ukrainian: return "uk-UA"
            case .czech: return "cs-CZ"
            case .romanian: return "ro-RO"
            case .danish: return "da-DK"
            case .hungarian: return "hu-HU"
            case .finnish: return "fi-FI"
            case .vietnamese: return "vi-VN"
            case .slovak: return "sk-SK"
            case .bulgarian: return "bg-BG"
            case .croatian: return "hr-HR"
            case .estonian: return "et-EE"
            case .norwegian: return "nb-NO"
            default:
                // ModelManager restricts this backend's picker. Keep a safe
                // fallback for a stale persisted setting or direct callers.
                return "en-US"
            }
        case .voxtralRealtime:
            // Voxtral can auto-detect when no hint is supplied. Its decoder
            // accepts ISO short codes for explicit language selection.
            return self == .auto ? nil : rawValue
        case .moonshineStreaming, .nemotronSpeechStreaming,
             .parakeetBuffered, .multitalkerParakeetStreaming:
            // These checkpoints accept English only, including stale/direct settings.
            return "en"
        }
    }
}

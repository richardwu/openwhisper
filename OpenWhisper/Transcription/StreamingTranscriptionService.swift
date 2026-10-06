import Foundation
import SwiftWhisper

/// Decoders publish raw live text and return raw final text. The shared router
/// owns preview correction; TranscriptionService owns final correction.
@MainActor
protocol StreamingTranscriptionService: AnyObject {
    var onPartialText: ((String) -> Void)? { get set }
    var onStatusChange: ((String) -> Void)? { get set }
    var onFailure: ((Error) -> Void)? { get set }
    func configure(language: WhisperLanguage)
    func configure(language: WhisperLanguage, modelURL: URL?)
    func begin()
    func append(audioFrames: [Float])
    func finish() async throws -> String
    func cancel()
}

extension StreamingTranscriptionService {
    var onStatusChange: ((String) -> Void)? { get { nil } set {} }
    var onFailure: ((Error) -> Void)? { get { nil } set {} }
    func configure(language: WhisperLanguage, modelURL: URL?) {
        configure(language: language)
    }
}

/// Every production streaming backend runs through this router. One worker
/// corrects changed previews off the UI thread. Only the newest pending preview
/// is needed; audio is never dropped by this preview policy.
@MainActor
final class BackendStreamingTranscriptionService: StreamingTranscriptionService {
    var onPartialText: ((String) -> Void)?
    var onStatusChange: ((String) -> Void)?
    var onFailure: ((Error) -> Void)?

    private let services: [TranscriptionBackend: any StreamingTranscriptionService]
    private let selectedBackend: () -> TranscriptionBackend
    private let vocabularyStore: VocabularyStore?
    private var activeService: (any StreamingTranscriptionService)?
    private var acceptingFrames = false
    private var generation = 0
    private var previewContinuation: AsyncStream<String>.Continuation?
    private var previewWorker: Task<Void, Never>?

    init(
        selectedBackend: @escaping () -> TranscriptionBackend,
        services: [TranscriptionBackend: any StreamingTranscriptionService],
        vocabularyStore: VocabularyStore? = nil
    ) {
        self.selectedBackend = selectedBackend
        self.services = services
        self.vocabularyStore = vocabularyStore
    }

    func configure(language: WhisperLanguage) {
        services[selectedBackend()]?.configure(language: language)
    }

    func configure(language: WhisperLanguage, modelURL: URL?) {
        services[selectedBackend()]?.configure(language: language, modelURL: modelURL)
    }

    func begin() {
        cancel()
        guard let service = services[selectedBackend()] else { return }
        activeService = service
        acceptingFrames = true
        let currentGeneration = generation
        let correction = vocabularyStore?.correctionSnapshot()
        let (previews, continuation) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(1))
        previewContinuation = continuation
        service.onPartialText = { [weak self] text in
            guard let self, currentGeneration == self.generation else { return }
            self.previewContinuation?.yield(text)
        }
        service.onStatusChange = { [weak self] status in
            guard let self, currentGeneration == self.generation else { return }
            self.onStatusChange?(status)
        }
        service.onFailure = { [weak self] error in
            guard let self, currentGeneration == self.generation else { return }
            self.onFailure?(error)
        }
        previewWorker = Task.detached(priority: .userInitiated) { [weak self] in
            var lastRaw = ""
            var lastCorrected = ""
            for await text in previews {
                guard !Task.isCancelled else { return }
                guard !text.isEmpty, text != lastRaw else { continue }
                lastRaw = text
                // ponytail: one full-text match per changed preview; switch
                // to incremental matching if multi-minute sessions fall behind.
                let corrected = correction?(text) ?? text
                guard !Task.isCancelled else { return }
                guard !corrected.isEmpty, corrected != lastCorrected else { continue }
                lastCorrected = corrected
                await self?.publish(corrected, generation: currentGeneration)
            }
        }
        service.begin()
    }

    func append(audioFrames: [Float]) {
        guard acceptingFrames else { return }
        activeService?.append(audioFrames: audioFrames)
    }

    func finish() async throws -> String {
        guard let service = activeService else {
            throw NSError(domain: "OpenWhisper.Streaming", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No streaming transcription backend is available"])
        }
        acceptingFrames = false
        let currentGeneration = generation
        do {
            let text = try await service.finish()
            guard currentGeneration == generation else { throw CancellationError() }
            previewContinuation?.finish()
            previewContinuation = nil
            await previewWorker?.value
            guard currentGeneration == generation else { throw CancellationError() }
            previewWorker = nil
            activeService = nil
            return text
        } catch {
            if currentGeneration == generation { cancel() }
            throw error
        }
    }

    func cancel() {
        generation &+= 1
        acceptingFrames = false
        activeService?.cancel()
        activeService = nil
        previewContinuation?.finish()
        previewContinuation = nil
        previewWorker?.cancel()
        previewWorker = nil
    }

    private func publish(_ text: String, generation: Int) {
        guard generation == self.generation else { return }
        onPartialText?(text)
    }
}

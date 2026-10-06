import Foundation
import SwiftWhisper

enum TranscriptionError: LocalizedError {
    case stubError

    var errorDescription: String? {
        "Transcription failed (stub)"
    }
}

@MainActor
final class TranscriptionService {
    enum Mode {
        case live
        case stub(result: String)
        case stubError
    }

    private let mode: Mode
    /// Shared local store used for model hints and final text correction.
    /// A nil store is useful for controlled baseline benchmarks.
    let vocabularyStore: VocabularyStore?
    private var whisperInstance: Whisper?
    private var loadedModelURL: URL?
    private var loadedLanguage: WhisperLanguage?
    private var generation = 0
    private var cancellationTask: Task<Void, Never>?
    private var promptPointer: UnsafeMutablePointer<CChar>?

    init(mode: Mode = .live, vocabularyStore: VocabularyStore? = VocabularyStore()) {
        self.mode = mode
        self.vocabularyStore = vocabularyStore
    }

    deinit {
        if let promptPointer {
            free(promptPointer)
        }
    }

    func transcribe(
        audioFrames: [Float],
        modelURL: URL,
        language: WhisperLanguage = .english,
        initialPrompt: String? = nil
    ) async throws -> String {
        let currentGeneration = generation
        await cancellationTask?.value
        guard currentGeneration == generation else { throw CancellationError() }
        cancellationTask = nil
        let rawText: String
        switch mode {
        case .live:
            let whisper = try getOrCreateWhisper(modelURL: modelURL, language: language)
            updateInitialPrompt(vocabularyStore?.makePrompt(extra: initialPrompt) ?? initialPrompt, on: whisper.params)
            let segments = try await whisper.transcribe(audioFrames: audioFrames)
            rawText = segments.map(\.text).joined()
        case .stub(let result):
            // Keep fixture transcription on the same finalization path as a
            // live decoder, including filtering and local vocabulary repair.
            rawText = result
        case .stubError:
            throw TranscriptionError.stubError
        }
        guard currentGeneration == generation else { throw CancellationError() }
        let text = await finalizeTranscription(rawText)
        guard currentGeneration == generation else { throw CancellationError() }
        return text
    }

    func cancel() {
        generation &+= 1
        guard cancellationTask == nil, let whisper = whisperInstance, whisper.inProgress else { return }
        // A new batch request waits for native cancellation before reusing weights.
        cancellationTask = Task { try? await whisper.cancel() }
    }

    /// Adds one explicitly reviewed spelling to the local prompt vocabulary.
    @discardableResult
    func learnVocabularyTerm(_ term: String) -> Bool {
        vocabularyStore?.learn(term: term) ?? false
    }

    @discardableResult
    func learnVocabularyTerms(_ input: String) -> [String] {
        vocabularyStore?.learnTerms(input) ?? []
    }

    var learnedVocabularyTerms: [String] {
        vocabularyStore?.learnedTerms ?? []
    }

    func forgetVocabularyTerm(_ term: String) {
        vocabularyStore?.forget(term: term)
    }

    func forgetAllVocabularyTerms() {
        vocabularyStore?.removeAllLearnedTerms()
    }

    private func updateInitialPrompt(_ prompt: String?, on params: WhisperParams) {
        if let promptPointer {
            free(promptPointer)
            self.promptPointer = nil
        }

        if let prompt, !prompt.isEmpty {
            let pointer = strdup(prompt)
            self.promptPointer = pointer
            params.initial_prompt = UnsafePointer(pointer)
        } else {
            params.initial_prompt = nil
        }
    }

    func filterTranscription(_ text: String) -> String {
        Self.filterTranscription(text, correction: vocabularyStore?.correctionSnapshot())
    }

    func finalizeTranscription(_ text: String) async -> String {
        let correction = vocabularyStore?.correctionSnapshot()
        return await Task.detached(priority: .userInitiated) {
            Self.filterTranscription(text, correction: correction)
        }.value
    }

    nonisolated private static func filterTranscription(
        _ text: String, correction: (@Sendable (String) -> String)?
    ) -> String {
        var result = text
        // Remove <|...|> special tokens
        result = result.replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
        // Reserve known acoustic marker names across backends. Preserve other
        // bracketed content, such as [TODO] and (see attached).
        let marker = "(?:blank[_ ]audio|inaudible|sound|no sound|silence|applause|laughter|(?:speaking|speaks in) foreign language|cough(?:s|ing)?|door slam(?:s|ming)?|(?:keyboard )?typing|(?:[a-z-]+ )*(?:music|noise)(?: playing)?|wind blowing|clapping|footsteps|(?:dog )?barking|laugh(?:s|ing)?|sigh(?:s|ing)?|breathing|sobbing|clears throat)"
        for (open, close) in [("\\[", "\\]"), ("\\(", "\\)")] {
            result = result.replacingOccurrences(of: "(?i)" + open + "\\s*" + marker + "\\s*" + close,
                                                  with: "", options: .regularExpression)
        }
        // Remove musical note sequences
        result = result.replacingOccurrences(of: "♪+", with: "", options: .regularExpression)
        // Collapse multiple spaces and trim
        result = result.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        // Punctuation-only output (e.g. ".") means the model found no speech
        if result.allSatisfy({ $0.isPunctuation || $0.isWhitespace }) {
            return ""
        }
        // Filter common hallucinated phrases when they're the entire output
        let hallucinatedPhrases = [
            "thank you for watching",
            "thank you for listening",
            "thanks for watching",
            "thanks for listening",
        ]
        if hallucinatedPhrases.contains(result.lowercased().trimmingCharacters(in: .punctuationCharacters)) {
            return ""
        }
        // Apply the same local correction pass to every backend. Apple
        // Speech accepts contextual strings as a hint, but it does not
        // guarantee the requested spelling in its final result.
        return correction?(result) ?? result
    }

    private func getOrCreateWhisper(modelURL: URL, language: WhisperLanguage) throws -> Whisper {
        if let whisperInstance, loadedModelURL == modelURL, loadedLanguage == language {
            return whisperInstance
        }

        let params = WhisperParams(strategy: .greedy)
        params.language = language

        let whisper = Whisper(fromFileURL: modelURL, withParams: params)
        self.whisperInstance = whisper
        self.loadedModelURL = modelURL
        self.loadedLanguage = language
        return whisper
    }
}

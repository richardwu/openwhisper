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
    private var whisperInstance: Whisper?
    private var loadedModelURL: URL?
    private var loadedLanguage: WhisperLanguage?
    private var promptPointer: UnsafeMutablePointer<CChar>?

    init(mode: Mode = .live) {
        self.mode = mode
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
        switch mode {
        case .live:
            let whisper = try getOrCreateWhisper(modelURL: modelURL, language: language)
            updateInitialPrompt(initialPrompt, on: whisper.params)
            let segments = try await whisper.transcribe(audioFrames: audioFrames)
            let rawText = segments.map(\.text).joined()
            return filterTranscription(rawText)
        case .stub(let result):
            return result
        case .stubError:
            throw TranscriptionError.stubError
        }
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
        var result = text
        // Remove <|...|> special tokens
        result = result.replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
        // Remove [BRACKET_TAGS] - matches [BLANK_AUDIO], [MUSIC], [inaudible], [ No sound ], etc.
        result = result.replacingOccurrences(of: "\\[\\s*\\w[\\w\\s]*\\]", with: "", options: .regularExpression)
        // Remove (PAREN_TAGS) - matches (music), (inaudible), (SPEAKING FOREIGN LANGUAGE), etc.
        result = result.replacingOccurrences(of: "\\([A-Za-z][A-Za-z\\s]*\\)", with: "", options: .regularExpression)
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
        return result
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

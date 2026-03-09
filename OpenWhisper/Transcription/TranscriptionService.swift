import Foundation
import SwiftWhisper

@MainActor
final class TranscriptionService {
    private var whisperInstance: Whisper?
    private var loadedModelURL: URL?
    private var promptPointer: UnsafeMutablePointer<CChar>?

    deinit {
        if let promptPointer {
            free(promptPointer)
        }
    }

    func transcribe(audioFrames: [Float], modelURL: URL, initialPrompt: String? = nil) async throws -> String {
        let whisper = try getOrCreateWhisper(modelURL: modelURL)
        updateInitialPrompt(initialPrompt, on: whisper.params)
        let segments = try await whisper.transcribe(audioFrames: audioFrames)
        let rawText = segments.map(\.text).joined()
        return TranscriptionFilter.filter(rawText)
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

    private func getOrCreateWhisper(modelURL: URL) throws -> Whisper {
        if let whisperInstance, loadedModelURL == modelURL {
            return whisperInstance
        }

        let params = WhisperParams(strategy: .greedy)
        params.language = .english

        let whisper = Whisper(fromFileURL: modelURL, withParams: params)
        self.whisperInstance = whisper
        self.loadedModelURL = modelURL
        return whisper
    }
}

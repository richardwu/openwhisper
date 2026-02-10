import Foundation
import SwiftWhisper

@MainActor
final class TranscriptionService {
    private var whisperInstance: Whisper?
    private var loadedModelURL: URL?

    func transcribe(audioFrames: [Float], modelURL: URL) async throws -> String {
        let whisper = try getOrCreateWhisper(modelURL: modelURL)
        let segments = try await whisper.transcribe(audioFrames: audioFrames)
        return segments.map(\.text).joined()
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

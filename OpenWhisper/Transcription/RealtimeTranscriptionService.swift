import Foundation
import SwiftWhisper

@MainActor
final class RealtimeTranscriptionService {
    private var whisperInstance: Whisper?
    private var loadedModelURL: URL?

    func transcribeChunk(audioFrames: [Float], modelURL: URL) async throws -> String {
        let whisper = try getOrCreateWhisper(modelURL: modelURL)

        // Limit to last 30 seconds of audio at 16kHz
        let maxSamples = 480_000
        let trimmedFrames: [Float]
        if audioFrames.count > maxSamples {
            trimmedFrames = Array(audioFrames.suffix(maxSamples))
        } else {
            trimmedFrames = audioFrames
        }

        let segments = try await whisper.transcribe(audioFrames: trimmedFrames)
        let rawText = segments.map(\.text).joined()
        return TranscriptionFilter.filter(rawText)
    }

    func cancelIfRunning() async {
        if whisperInstance != nil {
            try? await whisperInstance?.cancel()
        }
    }

    private func getOrCreateWhisper(modelURL: URL) throws -> Whisper {
        if let whisperInstance, loadedModelURL == modelURL {
            return whisperInstance
        }

        let params = WhisperParams(strategy: .greedy)
        params.language = .english
        params.single_segment = true
        params.no_context = true

        let whisper = Whisper(fromFileURL: modelURL, withParams: params)
        self.whisperInstance = whisper
        self.loadedModelURL = modelURL
        return whisper
    }
}

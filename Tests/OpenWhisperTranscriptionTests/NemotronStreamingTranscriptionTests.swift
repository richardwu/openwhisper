import AVFoundation
import XCTest
@testable import OpenWhisper

/// Optional integration coverage for Handy's Nemotron Speech Streaming model.
/// Set OPENWHISPER_NEMOTRON_MODEL to override the local fixture checkpoint.
@MainActor
final class NemotronStreamingTranscriptionTests: XCTestCase {
    func testNemotronStreamsFixtureAndPublishesPartialText() async throws {
        let defaultModelURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".context/models/nemotron-speech-streaming-en-0.6b-Q4_K_M.gguf")
        let modelPath = ProcessInfo.processInfo.environment["OPENWHISPER_NEMOTRON_MODEL"]
            ?? defaultModelURL.path
        let modelURL = URL(fileURLWithPath: modelPath)
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw XCTSkip("Nemotron model not found at \(modelPath)")
        }
        guard let fixture = Bundle(for: type(of: self)).url(
            forResource: "english-e2e-test-1", withExtension: "m4a", subdirectory: "Fixtures/Audio"
        ) else {
            throw XCTSkip("Streaming fixture is not available")
        }

        let samples = try readSamples(url: fixture)
        let service = TranscribeCppStreamingTranscriptionService(
            modelURLProvider: { modelURL },
            family: .nemotronSpeechStreaming
        )
        var partials: [String] = []
        service.onPartialText = { text in
            if !text.isEmpty { partials.append(text) }
        }

        service.configure(language: .english, modelURL: modelURL)
        service.begin()
        for start in stride(from: 0, to: samples.count, by: 3_200) {
            let end = min(start + 3_200, samples.count)
            service.append(audioFrames: Array(samples[start..<end]))
        }
        let text = try await service.finish().lowercased()

        XCTAssertFalse(partials.isEmpty, "Nemotron should publish a partial transcript")
        XCTAssertTrue(text.contains("this is me testing"), "Unexpected final text: \(text)")
        XCTAssertTrue(text.contains("work properly"), "Unexpected final text: \(text)")
    }

    private func readSamples(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                   channels: 1, interleaved: false)!
        let capacity = AVAudioFrameCount(Double(file.length) * 16_000 / file.processingFormat.sampleRate) + 1024
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)!
        var conversionError: NSError?
        _ = AVAudioConverter(from: file.processingFormat, to: format)!.convert(to: output, error: &conversionError) { _, status in
            let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)!
            do {
                try file.read(into: input)
                if input.frameLength == 0 {
                    status.pointee = .endOfStream
                    return nil
                }
                status.pointee = .haveData
                return input
            } catch {
                status.pointee = .endOfStream
                return nil
            }
        }
        if let conversionError { throw conversionError }
        guard let channel = output.floatChannelData?[0] else {
            throw NSError(domain: "NemotronStreamingTranscriptionTests", code: 1)
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}

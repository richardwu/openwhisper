import AVFoundation
import XCTest
@testable import OpenWhisper

/// Integration test for Handy's local Moonshine Streaming checkpoint.
/// Set OPENWHISPER_MOONSHINE_MODEL to override the default model cache path.
@MainActor
final class MoonshineStreamingTranscriptionTests: XCTestCase {
    func testMoonshineStreamsFixtureAndPublishesPartialText() async throws {
        let modelPath = ProcessInfo.processInfo.environment["OPENWHISPER_MOONSHINE_MODEL"]
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/OpenWhisper/Models/moonshine-streaming-small-Q8_0.gguf")
                .path
        let modelURL = URL(fileURLWithPath: modelPath)
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw XCTSkip("Moonshine model not found at \(modelPath)")
        }
        guard let fixture = Bundle(for: type(of: self)).url(
            forResource: "english-e2e-test-1", withExtension: "m4a", subdirectory: "Fixtures/Audio"
        ) else {
            throw XCTSkip("Streaming fixture is not available")
        }

        let samples = try readSamples(url: fixture)
        let cache = TranscribeCppStreamingTranscriptionService.ModelCache()
        let service = TranscribeCppStreamingTranscriptionService(
            modelURLProvider: { nil }, modelCache: cache
        )
        var partials: [String] = []
        service.onPartialText = { text in
            if !text.isEmpty { partials.append(text) }
        }

        // The second recording reuses the model with a fresh native session.
        for recording in 0..<3 {
            // Direct stale settings must normalize safely for English-only checkpoints.
            service.configure(language: recording == 0 ? .german : .english, modelURL: modelURL)
            partials.removeAll()
            if recording == 2 {
                service.begin()
                service.append(audioFrames: Array(samples.prefix(3_200)))
                try await Task.sleep(for: .milliseconds(10))
                service.cancel()
                service.configure(language: .english, modelURL: nil)
                service.begin()
                do {
                    _ = try await service.finish()
                    XCTFail("Expected the missing-model startup error")
                } catch {
                    XCTAssertTrue(error.localizedDescription.contains("not downloaded"))
                }
                service.configure(language: .english, modelURL: modelURL)
            }
            service.begin()
            if recording == 1 { cache.invalidate() }
            for start in stride(from: 0, to: samples.count, by: 3_200) {
                let end = min(start + 3_200, samples.count)
                service.append(audioFrames: Array(samples[start..<end]))
            }
            let text = try await service.finish().lowercased()

            if recording == 1 {
                XCTAssertNil(cache.model, "A pinned worker must not refill an invalidated cache")
            } else {
                XCTAssertNotNil(cache.model)
            }
            XCTAssertFalse(partials.isEmpty, "Moonshine should publish a partial transcript")
            XCTAssertTrue(text.contains("this is me testing"), "Unexpected final text: \(text)")
            XCTAssertTrue(text.contains("work properly"), "Unexpected final text: \(text)")
        }
    }

    private func readSamples(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                   channels: 1, interleaved: false)!
        let capacity = AVAudioFrameCount(Double(file.length) * 16_000 / file.processingFormat.sampleRate) + 1024
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)!
        var conversionError: NSError?
        let status = AVAudioConverter(from: file.processingFormat, to: format)!.convert(to: output, error: &conversionError) { _, status in
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
        guard status != .error, let channel = output.floatChannelData?[0] else {
            throw NSError(domain: "MoonshineStreamingTranscriptionTests", code: 1)
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}

import AVFoundation
import Speech
import XCTest
@testable import OpenWhisper

@MainActor
final class AppleStreamingTranscriptionTests: XCTestCase {
    func testLocalStreamingProducesPartialAndFinalText() async throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Apple SpeechTranscriber requires macOS 26")
        }
        guard SpeechTranscriber.isAvailable else {
            throw XCTSkip("Apple SpeechTranscriber is unavailable")
        }
        guard let url = Bundle(for: type(of: self)).url(
            forResource: "english-e2e-test-1", withExtension: "m4a", subdirectory: "Fixtures/Audio"
        ) else {
            throw XCTSkip("Streaming fixture is not available")
        }

        let samples = try readSamples(url: url)
        let service = AppleStreamingTranscriptionService()
        var partials: [String] = []
        service.onPartialText = { text in
            if !text.isEmpty { partials.append(text) }
        }

        service.begin()
        for start in stride(from: 0, to: samples.count, by: 3_200) {
            service.append(audioFrames: Array(samples[start..<min(start + 3_200, samples.count)]))
        }
        let text = try await service.finish().lowercased()

        XCTAssertFalse(partials.isEmpty, "Streaming should report text before finalization")
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
            throw NSError(domain: "AppleStreamingTranscriptionTests", code: 1)
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}

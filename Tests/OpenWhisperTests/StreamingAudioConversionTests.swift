import AVFoundation
import XCTest
@testable import OpenWhisper

@MainActor
final class StreamingAudioConversionTests: XCTestCase {
    func testResamplingDrainsTheFinalAudioFrames() throws {
        let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                       channels: 1, interleaved: false)!
        let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                        channels: 1, interleaved: false)!
        let converter = try XCTUnwrap(AVAudioConverter(from: inputFormat, to: outputFormat))
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 320))
        input.frameLength = 320
        input.floatChannelData![0].initialize(repeating: 0.25, count: 320)
        var outputFrames = 0
        for _ in 0..<4 {
            outputFrames += Int(try AudioBufferConversion.convert(input: input, using: converter).frameLength)
        }
        let beforeFlush = outputFrames
        while true {
            let tail = try AudioBufferConversion.convert(input: nil, using: converter)
            guard tail.frameLength > 0 else { break }
            outputFrames += Int(tail.frameLength)
        }
        XCTAssertGreaterThan(outputFrames, beforeFlush)
        XCTAssertEqual(outputFrames, 4 * 320 * 3)
    }
}

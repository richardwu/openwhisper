import AVFoundation
import XCTest
@testable import OpenWhisper

final class AudioCaptureBufferTests: XCTestCase {
    @MainActor
    func testFixtureCaptureDeliversFramesToStreamingCallback() throws {
        let samples: [Float] = [0.1, 0.2, 0.3]
        let recorder = AudioRecorder(mode: .fixture(samples: samples))
        var streamed: [Float] = []
        recorder.onAudioFrames = { streamed += $0 }
        try recorder.startRecording(retainSamples: false)
        XCTAssertEqual(recorder.stopRecording(), samples)
        XCTAssertEqual(streamed, samples)
    }

    func testStreamingCaptureFlushesTailWithoutRetainingFullRecording() throws {
        let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                       channels: 1, interleaved: false)!
        let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                        channels: 1, interleaved: false)!
        let converter = try XCTUnwrap(AVAudioConverter(from: inputFormat, to: outputFormat))
        let capture = AudioCaptureBuffer(retainSamples: false, converter: converter)
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 960))
        input.frameLength = 960
        input.floatChannelData![0].initialize(repeating: 0.25, count: 960)
        var frames = 0
        for _ in 0..<4 {
            _ = try capture.convert(input)
            frames += capture.drain().reduce(0) { $0 + $1.count }
        }
        let result = capture.finish()
        let tail = result.pending.reduce(0) { $0 + $1.count }
        XCTAssertGreaterThan(tail, 0)
        XCTAssertEqual(frames + tail, 1280)
        XCTAssertTrue(result.samples.isEmpty)
        XCTAssertNil(result.error)
        XCTAssertTrue(try capture.convert(input).isEmpty)
    }

    func testBatchCaptureRetainsSamplesWithoutQueueingDelivery() {
        let capture = AudioCaptureBuffer()
        XCTAssertTrue(capture.append([1, 2]))
        XCTAssertTrue(capture.drain().isEmpty)
        XCTAssertTrue(capture.append([3, 4]))
        let result = capture.finish()
        XCTAssertEqual(result.samples, [1, 2, 3, 4])
        XCTAssertTrue(result.pending.isEmpty)
    }

    func testStopDrainsQueuedFramesAndRejectsLateAudio() {
        let capture = AudioCaptureBuffer(retainSamples: false)
        XCTAssertTrue(capture.append([1, 2]))
        XCTAssertEqual(capture.drain(), [[1, 2]])
        XCTAssertTrue(capture.append([3, 4]))
        let result = capture.finish()
        XCTAssertTrue(result.samples.isEmpty)
        XCTAssertEqual(result.pending, [[3, 4]])
        XCTAssertTrue(capture.drain().isEmpty)
        XCTAssertFalse(capture.append([5]))
        XCTAssertTrue(capture.finish().samples.isEmpty)
        let next = AudioCaptureBuffer()
        XCTAssertTrue(next.append([6]))
        XCTAssertEqual(next.finish().samples, [6])
    }
}

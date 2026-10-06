import XCTest
@testable import OpenWhisper

final class AudioCaptureBufferTests: XCTestCase {
    func testStopDrainsQueuedFramesAndRejectsLateAudio() {
        let capture = AudioCaptureBuffer()
        XCTAssertTrue(capture.append([1, 2]))
        XCTAssertEqual(capture.drain(), [[1, 2]])
        XCTAssertTrue(capture.append([3, 4]))
        let result = capture.finish()
        XCTAssertEqual(result.samples, [1, 2, 3, 4])
        XCTAssertEqual(result.pending, [[3, 4]])
        XCTAssertTrue(capture.drain().isEmpty)
        XCTAssertFalse(capture.append([5]))
        XCTAssertTrue(capture.finish().samples.isEmpty)
        let next = AudioCaptureBuffer()
        XCTAssertTrue(next.append([6]))
        XCTAssertEqual(next.finish().samples, [6])
    }
}

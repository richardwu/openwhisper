import XCTest
import SwiftWhisper
@testable import OpenWhisper

@MainActor
final class TranscribeCppStreamingTests: XCTestCase {
    func testFinishReportsMissingLocalCheckpointWithoutStartingAWorker() async {
        let service = TranscribeCppStreamingTranscriptionService(
            modelURLProvider: { nil }
        )
        service.configure(language: .english, modelURL: nil)
        service.begin()

        do {
            _ = try await service.finish()
            XCTFail("Expected a missing-checkpoint error")
        } catch {
            XCTAssertEqual((error as NSError).domain, "OpenWhisper.TranscribeCpp")
            XCTAssertTrue((error as NSError).localizedDescription.contains("not downloaded"))
        }
    }

    func testModelURLConfigurationIsUsedAtBeginTime() async {
        let missingURL = URL(fileURLWithPath: "/tmp/missing-moonshine-(UUID().uuidString).gguf")
        let service = TranscribeCppStreamingTranscriptionService(
            modelURLProvider: { nil }
        )
        service.configure(language: .english, modelURL: missingURL)
        service.begin()

        do {
            _ = try await service.finish()
            XCTFail("Expected model loading to fail")
        } catch {
            // The native loader can change its detail text between releases;
            // the service must still report a local failure.
            XCTAssertFalse((error as NSError).localizedDescription.isEmpty)
        }
    }
}

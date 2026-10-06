import XCTest
import SwiftWhisper
@testable import OpenWhisper

@MainActor
final class StreamingTranscriptionTests: XCTestCase {
    func testRouterKeepsTheRecordingBackendUntilFinish() async throws {
        var selectedBackend = TranscriptionBackend.appleStreaming
        let apple = StreamingServiceSpy(finalText: "Apple final")
        let parakeet = StreamingServiceSpy(finalText: "Parakeet final")
        let router = BackendStreamingTranscriptionService(
            selectedBackend: { selectedBackend },
            services: [.appleStreaming: apple, .parakeetUnified: parakeet]
        )

        router.configure(language: .english)
        router.begin()
        selectedBackend = .parakeetUnified
        router.append(audioFrames: [0.1, 0.2])
        let firstText = try await router.finish()

        XCTAssertEqual(firstText, "Apple final")
        XCTAssertEqual(apple.receivedFrames, [[0.1, 0.2]])
        XCTAssertEqual(apple.finishCount, 1)
        XCTAssertTrue(parakeet.receivedFrames.isEmpty)
        XCTAssertEqual(parakeet.finishCount, 0)

        router.configure(language: .english)
        router.begin()
        router.append(audioFrames: [0.3])
        let secondText = try await router.finish()

        XCTAssertEqual(secondText, "Parakeet final")
        XCTAssertEqual(parakeet.receivedFrames, [[0.3]])
        XCTAssertEqual(parakeet.finishCount, 1)
    }

    func testCancelRejectsCallbacksFromThePreviousRunOfTheSameBackend() async throws {
        let service = StreamingServiceSpy(finalText: "New final")
        let router = BackendStreamingTranscriptionService(
            selectedBackend: { .appleStreaming }, services: [.appleStreaming: service]
        )
        var partials: [String] = []
        router.onPartialText = { partials.append($0) }

        router.begin()
        let oldCallback = try XCTUnwrap(service.onPartialText)
        router.cancel()
        router.begin()
        oldCallback("Cancelled old transcript")
        service.onPartialText?("New transcript")
        _ = try await router.finish()

        XCTAssertEqual(partials, ["New transcript"])
        XCTAssertGreaterThanOrEqual(service.cancelCount, 1)
    }

    func testRestartDuringFinishCannotClearTheNewSession() async throws {
        let service = StreamingServiceSpy(finalText: "Final")
        let router = BackendStreamingTranscriptionService(
            selectedBackend: { .appleStreaming }, services: [.appleStreaming: service]
        )
        service.holdFinish = true
        router.begin()
        let oldFinish = Task { try await router.finish() }
        while service.heldFinish == nil { await Task.yield() }
        router.begin()
        service.holdFinish = false
        service.heldFinish?.resume(returning: "Old final")
        service.heldFinish = nil
        do {
            _ = try await oldFinish.value
            XCTFail("The previous session must be cancelled")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        router.append(audioFrames: [0.5])
        let text = try await router.finish()
        XCTAssertEqual(text, "Final")
        XCTAssertEqual(service.receivedFrames, [[0.5]])
    }

    func testPreviewBurstKeepsTheNewestTextWithoutAProcessingBacklog() async throws {
        let service = StreamingServiceSpy(finalText: "Final raw transcript")
        let router = BackendStreamingTranscriptionService(
            selectedBackend: { .appleStreaming }, services: [.appleStreaming: service]
        )
        var partials: [String] = []
        router.onPartialText = { partials.append($0) }
        router.begin()

        for index in 0..<1_000 {
            service.onPartialText?("Preview \(index)")
        }
        let finalText = try await router.finish()

        XCTAssertEqual(partials.last, "Preview 999")
        XCTAssertLessThanOrEqual(partials.count, 2, "The worker should retain only the newest pending preview")
        XCTAssertEqual(finalText, "Final raw transcript", "Preview processing must not replace the raw final result")
    }

    func testPreviewCorrectionUsesOneSnapshotAndSkipsEquivalentResults() async throws {
        let suiteName = "com.openwhisper.test.streaming-preview.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let vocabulary = VocabularyStore(defaults: defaults)
        XCTAssertTrue(vocabulary.learn(term: "AcmeDB"))
        let service = StreamingServiceSpy(finalText: "Final raw transcript")
        let router = BackendStreamingTranscriptionService(
            selectedBackend: { .appleStreaming },
            services: [.appleStreaming: service], vocabularyStore: vocabulary
        )
        var partials: [String] = []
        router.onPartialText = { partials.append($0) }
        router.begin()
        vocabulary.forget(term: "AcmeDB")

        service.onPartialText?("Use acmedb and trade on Nyzi.")
        await waitForPreview { !partials.isEmpty }
        for _ in 0..<100 {
            service.onPartialText?("Use acmedb and trade on Nyzi.")
        }
        service.onPartialText?("Use acmedb and trade on Nisy.")
        let finalText = try await router.finish()

        XCTAssertEqual(partials, ["Use AcmeDB and trade on NYSE."])
        XCTAssertEqual(finalText, "Final raw transcript")
    }

    func testPreviewCorrectionLeavesTheMainActorResponsive() async throws {
        let suiteName = "com.openwhisper.test.streaming-heartbeat.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let service = StreamingServiceSpy(finalText: "Final raw transcript")
        let router = BackendStreamingTranscriptionService(
            selectedBackend: { .appleStreaming },
            services: [.appleStreaming: service], vocabularyStore: VocabularyStore(defaults: defaults)
        )
        var partialCount = 0
        router.onPartialText = { _ in partialCount += 1 }
        var heartbeatCount = 0
        var maxHeartbeatGap = 0.0
        let clock = ContinuousClock()
        let heartbeat = Task { @MainActor in
            var lastBeat = clock.now
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
                let now = clock.now
                let elapsed = lastBeat.duration(to: now).components
                maxHeartbeatGap = max(maxHeartbeatGap, Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
                heartbeatCount += 1
                lastBeat = now
            }
        }
        defer { heartbeat.cancel() }
        router.begin()
        let longText = Array(repeating: "Use postgresql and trade on Nyzi.", count: 25).joined(separator: " ")
        for index in 0..<5 {
            service.onPartialText?("\(index). \(longText)")
            await waitForPreview { partialCount > index }
        }
        _ = try await router.finish()

        XCTAssertEqual(partialCount, 5)
        XCTAssertGreaterThan(heartbeatCount, 0, "The main actor must run while previews are corrected")
        XCTAssertLessThan(maxHeartbeatGap, 0.3, "Preview correction blocked the main actor")
    }

    func testCancelledCppWorkerCannotOverwriteTheNewRunError() async {
        let service = TranscribeCppStreamingTranscriptionService(modelURLProvider: { nil })
        service.configure(
            language: .english,
            modelURL: URL(fileURLWithPath: "/tmp/missing-streaming-model-\(UUID().uuidString).gguf")
        )
        service.begin()
        service.configure(language: .english, modelURL: nil)
        service.begin()
        try? await Task.sleep(for: .milliseconds(100))

        do {
            _ = try await service.finish()
            XCTFail("Expected the new run's missing-checkpoint error")
        } catch {
            XCTAssertEqual((error as NSError).domain, "OpenWhisper.TranscribeCpp")
            XCTAssertTrue(error.localizedDescription.contains("not downloaded"), "A cancelled worker overwrote the new result: \(error)")
        }
    }

    private func waitForPreview(_ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The streaming preview did not arrive within two seconds")
    }
}

@MainActor
private final class StreamingServiceSpy: StreamingTranscriptionService {
    var onPartialText: ((String) -> Void)?
    let finalText: String
    private(set) var receivedFrames: [[Float]] = []
    private(set) var finishCount = 0
    private(set) var cancelCount = 0
    var holdFinish = false
    var heldFinish: CheckedContinuation<String, Error>?

    init(finalText: String) { self.finalText = finalText }
    func configure(language: WhisperLanguage) {}
    func begin() {}
    func append(audioFrames: [Float]) { receivedFrames.append(audioFrames) }
    func finish() async throws -> String {
        finishCount += 1
        if holdFinish {
            return try await withCheckedThrowingContinuation { heldFinish = $0 }
        }
        return finalText
    }
    func cancel() { cancelCount += 1 }
}

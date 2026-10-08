import AVFoundation
import XCTest
@testable import OpenWhisper

/// A real decoder-to-AppState journey that runs without windows or input events.
/// Recorded human audio enters through AudioRecorder's production PCM callback.
/// Hardware microphone capture, global hotkeys, and OS paste are separate boundaries;
/// the fixture recorder and paste spy deliberately replace those operations.
@MainActor
final class BackgroundDictationJourneyTests: XCTestCase {
    func testRealMoonshineDictationStreamsBeforeStopAndPersistsFinalText() async throws {
        let processEnvironment = ProcessInfo.processInfo.environment
        guard processEnvironment["OPENWHISPER_HEADLESS_TESTS"] == "1" else {
            throw XCTSkip("This journey requires OPENWHISPER_HEADLESS_TESTS=1 to prevent screen interaction")
        }
        let modelPath = processEnvironment["OPENWHISPER_MOONSHINE_MODEL"]
            ?? processEnvironment["TEST_RUNNER_OPENWHISPER_MOONSHINE_MODEL"]
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/OpenWhisper/Models/moonshine-streaming-small-Q8_0.gguf")
                .path
        let modelURL = URL(fileURLWithPath: modelPath)
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw XCTSkip("Moonshine checkpoint is not cached at \(modelPath)")
        }
        let fixtureURL = try XCTUnwrap(Bundle(for: type(of: self)).url(
            forResource: "english-e2e-test-1", withExtension: "m4a", subdirectory: "Fixtures/Audio"
        ))
        let samples = try readSamples(url: fixtureURL)
        XCTAssertFalse(samples.isEmpty)

        let suiteName = "com.openwhisper.background-journey.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(TranscriptionBackend.moonshineStreamingSmall.rawValue, forKey: "selectedBackend")
        let vocabulary = VocabularyStore(defaults: defaults)
        let finalizationService = TranscriptionService(mode: .stubError, vocabularyStore: vocabulary)
        let decoder = TranscribeCppStreamingTranscriptionService(
            modelURLProvider: { modelURL }, vocabularyStore: vocabulary, family: .moonshineStreaming
        )
        let streamingService = BackendStreamingTranscriptionService(
            selectedBackend: { .moonshineStreamingSmall },
            services: [.moonshineStreamingSmall: decoder], vocabularyStore: vocabulary
        )
        defer { streamingService.cancel() }
        let configuration = LaunchConfiguration(
            isTestMode: true, testScenario: nil, defaultsSuiteName: suiteName,
            disableSparkle: true, disableHotkeys: true, modelPath: modelPath
        )
        XCTAssertTrue(configuration.isHeadlessTest)
        let state = AppState(environment: AppEnvironment(
            audioRecorder: AudioRecorder(mode: .fixture(samples: samples)),
            streamingTranscriptionService: streamingService,
            transcriptionService: finalizationService,
            pasteService: PasteService(mode: .spy),
            modelManager: ModelManager(mode: .fixedPath(modelURL), defaults: defaults),
            permissionsClient: PermissionsClient(mode: .mock(microphone: true, accessibility: true)),
            historyStore: HistoryStore(defaults: defaults),
            launchConfig: configuration
        ))
        XCTAssertNil(state.overlayController, "A background journey must not create an overlay panel")
        XCTAssertEqual(state.modelManager.selectedBackend, .moonshineStreamingSmall)
        XCTAssertTrue(state.modelManager.isModelReady)
        let added = finalizationService.learnVocabularyTerms("OpenWhisper, AcmeDB, kubernetes, openwhisper,,")
        XCTAssertEqual(Set(added), Set(["OpenWhisper", "AcmeDB", "kubernetes"]))

        // Retain the production callback to verify that live results reach AppState,
        // while observing only updates emitted before the user stops recording.
        let publishToState = streamingService.onPartialText
        var recordingPartials: [String] = []
        streamingService.onPartialText = { [weak state] text in
            publishToState?(text)
            if state?.isRecording == true, !text.isEmpty {
                recordingPartials.append(text)
            }
        }
        await state.toggleRecording()
        XCTAssertTrue(state.isRecording)
        XCTAssertEqual(state.overlayState.phase, .recording)
        XCTAssertTrue(state.pasteService.pastedTexts.isEmpty)
        XCTAssertTrue(state.historyStore.entries.isEmpty)
        let forwardFrames = try XCTUnwrap(state.audioRecorder.onAudioFrames)
        for start in stride(from: 0, to: samples.count, by: 3_200) {
            let end = min(start + 3_200, samples.count)
            forwardFrames(Array(samples[start..<end]))
            // 16 kHz PCM arrives in 200 ms chunks, as it would during capture.
            try await Task.sleep(nanoseconds: UInt64(end - start) * 1_000_000_000 / 16_000)
        }
        // Cold model preparation can outlast this short fixture. Keep recording
        // until the worker emits a partial; finish() must not trigger the first one.
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(30))
        while recordingPartials.isEmpty, clock.now < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertFalse(recordingPartials.isEmpty, "The real decoder must publish text before recording stops")
        XCTAssertTrue(state.statusMessage.hasPrefix("Recording: "), "Live text did not reach AppState: \(state.statusMessage)")
        XCTAssertTrue(state.isRecording)
        XCTAssertEqual(state.overlayState.phase, .recording)
        XCTAssertTrue(state.historyStore.entries.isEmpty)

        await state.toggleRecording()
        XCTAssertFalse(state.isRecording)
        XCTAssertFalse(state.isTranscribing)
        XCTAssertEqual(state.overlayState.phase, .hidden)
        XCTAssertNil(state.overlayController)
        XCTAssertTrue(state.statusMessage.hasPrefix("Pasted: "), state.statusMessage)
        XCTAssertEqual(state.historyStore.entries.count, 1)
        let finalText = try XCTUnwrap(state.historyStore.entries.first?.text)
        // The error-only batch service makes any unintended Whisper fallback fail.
        XCTAssertEqual(state.pasteService.pastedTexts, [finalText])
        XCTAssertTrue(finalText.localizedCaseInsensitiveContains("this is me testing"), finalText)
        XCTAssertTrue(finalText.localizedCaseInsensitiveContains("work properly"), finalText)
        XCTAssertTrue(finalText.contains("OpenWhisper"), "Pinned spelling was not applied: \(finalText)")
        XCTAssertEqual(HistoryStore(defaults: defaults).entries.map(\.text), [finalText])
        XCTAssertEqual(Set(VocabularyStore(defaults: defaults).learnedTerms), Set(["OpenWhisper", "AcmeDB", "kubernetes"]))
        print("BACKGROUND_JOURNEY model=\(modelURL.lastPathComponent) partial_count=\(recordingPartials.count) final_text=\(finalText)")
    }

    private func readSamples(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
        ))
        let converter = try XCTUnwrap(AVAudioConverter(from: file.processingFormat, to: format))
        let capacity = AVAudioFrameCount(Double(file.length) * 16_000 / file.processingFormat.sampleRate) + 1_024
        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity))
        var conversionError: NSError?
        var readError: Error?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            guard file.framePosition < file.length else {
                inputStatus.pointee = .endOfStream
                return nil
            }
            let remainingFrames = file.length - file.framePosition
            let frameCount = AVAudioFrameCount(min(4_096, remainingFrames))
            guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else {
                readError = NSError(domain: "BackgroundDictationJourneyTests", code: 2,
                                    userInfo: [NSLocalizedDescriptionKey: "Could not allocate an audio conversion buffer"])
                inputStatus.pointee = .endOfStream
                return nil
            }
            do {
                try file.read(into: input, frameCount: frameCount)
                guard input.frameLength > 0 else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return input
            } catch {
                readError = error
                inputStatus.pointee = .endOfStream
                return nil
            }
        }
        if let readError { throw readError }
        if let conversionError { throw conversionError }
        guard status != .error else {
            throw NSError(domain: "BackgroundDictationJourneyTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not convert the speech fixture to 16 kHz PCM"])
        }
        let channel = try XCTUnwrap(output.floatChannelData?[0])
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}

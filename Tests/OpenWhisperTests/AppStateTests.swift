import XCTest
import SwiftWhisper
@testable import OpenWhisper

@MainActor
final class AppStateTests: XCTestCase {

    private var suiteName: String = ""

    private func makeAppState(scenario: TestScenario) -> AppState {
        suiteName = "com.openwhisper.test.\(UUID().uuidString)"
        let env = AppEnvironment.test(scenario: scenario, suiteName: suiteName)
        return AppState(environment: env)
    }

    override func tearDown() {
        if !suiteName.isEmpty {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }
        super.tearDown()
    }

    func testRecordingModeDefaultsAndPersists() {
        let state = makeAppState(scenario: .launchReadyState)
        XCTAssertEqual(state.recordingTriggerMode, .toggle)
        XCTAssertEqual(state.recordingTriggerMode.instructionDetail, "Press again to stop and transcribe")
        state.recordingTriggerMode = .pressAndHold
        let restored = AppState(environment: .test(scenario: .launchReadyState, suiteName: suiteName))
        XCTAssertEqual(restored.recordingTriggerMode, .pressAndHold)
        XCTAssertEqual(restored.recordingTriggerMode.instructionTitle, "Press and hold your hotkey to record")
        XCTAssertEqual(restored.recordingTriggerMode.instructionDetail, "Release to stop and transcribe")
    }

    func testToggleHotkeyRecordsAcrossTwoPresses() async {
        let state = makeAppState(scenario: .recordToTranscribeSuccess)
        state.recordingHotkeyDown()
        XCTAssertFalse(state.isRecording)
        await state.recordingHotkeyUp()
        XCTAssertTrue(state.isRecording)
        state.recordingHotkeyDown()
        await state.recordingHotkeyUp()
        XCTAssertFalse(state.isRecording)
        XCTAssertEqual(state.pasteService.pastedTexts, ["Hello world"])
    }

    func testHoldHotkeyRecordsUntilReleaseAndIgnoresRepeats() async {
        let state = makeAppState(scenario: .recordToTranscribeSuccess)
        state.recordingTriggerMode = .pressAndHold
        state.recordingHotkeyDown()
        XCTAssertTrue(state.isRecording)
        state.recordingHotkeyDown()
        XCTAssertTrue(state.isRecording)
        XCTAssertTrue(state.pasteService.pastedTexts.isEmpty)
        // A settings change during the press must not strand the recording.
        state.recordingTriggerMode = .toggle
        await state.recordingHotkeyUp()
        XCTAssertFalse(state.isRecording)
        XCTAssertEqual(state.pasteService.pastedTexts, ["Hello world"])
        await state.recordingHotkeyUp()
        XCTAssertFalse(state.isRecording)
    }

    func testCancelledHoldDoesNotRestartOnRepeatOrRelease() async {
        let state = makeAppState(scenario: .recordToTranscribeSuccess)
        state.recordingTriggerMode = .pressAndHold
        state.recordingHotkeyDown()
        state.cancelRecording()
        state.recordingHotkeyDown()
        await state.recordingHotkeyUp()
        XCTAssertFalse(state.isRecording)
        XCTAssertTrue(state.pasteService.pastedTexts.isEmpty)
        state.recordingHotkeyDown()
        XCTAssertTrue(state.isRecording)
        await state.recordingHotkeyUp()
        XCTAssertEqual(state.pasteService.pastedTexts, ["Hello world"])
    }

    func testCancelledToggleIgnoresHeldKeyUntilRelease() async {
        let state = makeAppState(scenario: .recordToTranscribeSuccess)
        await state.toggleRecording()
        state.recordingHotkeyDown()
        state.cancelRecording()
        state.recordingHotkeyDown()
        await state.recordingHotkeyUp()
        XCTAssertFalse(state.isRecording)
        XCTAssertTrue(state.pasteService.pastedTexts.isEmpty)
        state.recordingHotkeyDown()
        await state.recordingHotkeyUp()
        XCTAssertTrue(state.isRecording)
        state.cancelRecording()
    }

    func testBatchRecordingKeepsItsModelAfterBackendSelectionChanges() async {
        let state = makeAppState(scenario: .recordToTranscribeSuccess)
        await state.toggleRecording()
        state.modelManager.selectBackend(.appleStreaming)
        await state.toggleRecording()
        XCTAssertEqual(state.pasteService.pastedTexts, ["Hello world"])
    }

    func testCancelDuringFinishRejectsLateResultsAfterRestart() async {
        let decoder = StubStreamingTranscriptionService(finalText: "New recording")
        var resumeFinish: CheckedContinuation<Void, Never>?
        decoder.onFinish = { await withCheckedContinuation { resumeFinish = $0 } }
        let state = makeStreamingAppState(decoder: decoder)
        await state.toggleRecording()
        let finishing = Task { await state.toggleRecording() }
        while resumeFinish == nil { await Task.yield() }
        XCTAssertTrue(state.isTranscribing)
        state.cancelRecording()
        XCTAssertFalse(state.isTranscribing)
        XCTAssertEqual(state.overlayState.phase, .cancelled)
        decoder.onFinish = nil
        await state.toggleRecording()
        resumeFinish?.resume()
        await finishing.value
        XCTAssertTrue(state.isRecording, "Old finalization must not clear the new recording")
        XCTAssertEqual(state.overlayState.phase, .recording)
        XCTAssertTrue(state.pasteService.pastedTexts.isEmpty)
        XCTAssertTrue(state.historyStore.entries.isEmpty)
        await state.toggleRecording()
        XCTAssertEqual(state.pasteService.pastedTexts, ["New recording"])
    }

    func testStreamingStartupFailureStopsRecordingImmediately() async {
        let decoder = StubStreamingTranscriptionService(finalText: "Unused")
        decoder.beginFailure = TranscriptionError.stubError
        let state = makeStreamingAppState(decoder: decoder)
        await state.toggleRecording()
        XCTAssertFalse(state.isRecording)
        XCTAssertFalse(state.isTranscribing)
        XCTAssertTrue(state.statusMessage.contains("error:"))
        XCTAssertTrue(state.pasteService.pastedTexts.isEmpty)
    }

    func testStreamingDownloadStatusAndAsynchronousFailureAreVisible() async {
        let decoder = StubStreamingTranscriptionService(finalText: "Partial")
        let state = makeStreamingAppState(decoder: decoder)
        await state.toggleRecording()
        decoder.onStatusChange?("Recording (downloading Apple speech model)...")
        XCTAssertTrue(state.statusMessage.contains("downloading Apple speech model"))
        decoder.onFailure?(TranscriptionError.stubError)
        XCTAssertFalse(state.isRecording)
        XCTAssertTrue(state.statusMessage.contains("error:"))
        XCTAssertTrue(state.historyStore.entries.isEmpty)
    }

    func testMicrophoneFailureStopsWithoutPasting() async {
        let state = makeAppState(scenario: .recordToTranscribeSuccess)
        await state.toggleRecording()
        state.audioRecorder.onFailure?(AudioRecorderError.converterCreationFailed)
        XCTAssertFalse(state.isRecording)
        XCTAssertTrue(state.statusMessage.contains("audio format converter"))
        XCTAssertTrue(state.pasteService.pastedTexts.isEmpty)
        XCTAssertTrue(state.historyStore.entries.isEmpty)
    }

    private func makeStreamingAppState(decoder: StubStreamingTranscriptionService) -> AppState {
        let environment = AppEnvironment.test(scenario: .recordToTranscribeSuccess)
        environment.modelManager.selectBackend(.appleStreaming)
        return AppState(environment: AppEnvironment(
            audioRecorder: environment.audioRecorder,
            streamingTranscriptionService: decoder,
            transcriptionService: environment.transcriptionService,
            pasteService: environment.pasteService,
            modelManager: environment.modelManager,
            permissionsClient: environment.permissionsClient,
            historyStore: environment.historyStore,
            launchConfig: environment.launchConfig
        ))
    }

    func testHoldWithDeniedMicrophoneDoesNotStartOnRelease() async {
        let state = makeAppState(scenario: .micDenied)
        state.recordingTriggerMode = .pressAndHold
        state.recordingHotkeyDown()
        await state.recordingHotkeyUp()
        XCTAssertFalse(state.isRecording)
        XCTAssertEqual(state.statusMessage, "Microphone permission required")
        XCTAssertTrue(state.pasteService.pastedTexts.isEmpty)
    }

    // MARK: - Launch Ready State

    func testLaunchReadyState() {
        let state = makeAppState(scenario: .launchReadyState)
        XCTAssertEqual(state.statusMessage, "Ready")
        XCTAssertFalse(state.isRecording)
        XCTAssertFalse(state.isTranscribing)
        XCTAssertTrue(state.modelManager.isModelReady)
        XCTAssertEqual(state.modelManager.selectedLanguage, .english)
        XCTAssertTrue(state.permissionsClient.isMicrophoneAuthorized)
        XCTAssertTrue(state.permissionsClient.isAccessibilityGranted)
    }

    func testFixedModelPathMustExist() {
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-model-\(UUID().uuidString).bin")
        let suiteName = "com.openwhisper.test.fixed-path.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(TranscriptionBackend.whisperSmall.rawValue, forKey: "selectedBackend")
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let manager = ModelManager(mode: .fixedPath(missingURL), defaults: defaults)

        XCTAssertFalse(manager.isModelReady)
        XCTAssertNil(manager.modelFileURL)
    }

    func testAppleBackendIsReadyWithoutWhisperModel() {
        let suiteName = "com.openwhisper.test.backend.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(TranscriptionBackend.appleStreaming.rawValue, forKey: "selectedBackend")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = ModelManager(mode: .missing, defaults: defaults)

        XCTAssertEqual(manager.selectedBackend, .appleStreaming)
        XCTAssertTrue(manager.isModelReady)
        XCTAssertNil(manager.modelFileURL)
    }

    // MARK: - Record to Transcribe Success

    func testRecordToTranscribeSuccess() async {
        let state = makeAppState(scenario: .recordToTranscribeSuccess)

        // Start recording
        await state.toggleRecording()
        XCTAssertTrue(state.isRecording)
        XCTAssertEqual(state.statusMessage, "Recording...")
        XCTAssertEqual(state.overlayState.phase, .recording)

        // Stop recording → transcribe → paste
        await state.toggleRecording()
        XCTAssertFalse(state.isRecording)
        XCTAssertFalse(state.isTranscribing)
        XCTAssertTrue(state.statusMessage.contains("Pasted"))
        XCTAssertEqual(state.pasteService.pastedTexts, ["Hello world"])
        XCTAssertEqual(state.historyStore.entries.count, 1)
        XCTAssertEqual(state.historyStore.entries.first?.text, "Hello world")
        XCTAssertEqual(state.overlayState.phase, .hidden)
    }

    func testAllStreamingBackendsShareResponsiveFinalizationAndCleanup() async {
        for backend in TranscriptionBackend.allCases.filter(\.isStreamingBackend) {
            for (rawText, shouldFail) in [("<|startoftranscript|>I trade on Nyzi. [BLANK_AUDIO]", false), ("", false), ("", true)] {
                let context = "\(backend.rawValue): \(shouldFail ? "error" : rawText.isEmpty ? "silence" : "success")"
                let suiteName = "com.openwhisper.test.streaming-contract.\(UUID().uuidString)"
                let defaults = UserDefaults(suiteName: suiteName)!
                defaults.set(backend.rawValue, forKey: "selectedBackend")
                defer { defaults.removePersistentDomain(forName: suiteName) }

                let streamingService = StubStreamingTranscriptionService(finalText: rawText, shouldFail: shouldFail)
                let environment = AppEnvironment(
                    audioRecorder: AudioRecorder(mode: .fixture(samples: Array(repeating: 0.1, count: 16000))),
                    streamingTranscriptionService: streamingService,
                    // A fallback to batch transcription would fail this test.
                    transcriptionService: TranscriptionService(mode: .stubError, vocabularyStore: VocabularyStore(defaults: defaults)),
                    pasteService: PasteService(mode: .spy),
                    modelManager: ModelManager(mode: .ready, defaults: defaults),
                    permissionsClient: PermissionsClient(mode: .mock(microphone: true, accessibility: true)),
                    historyStore: HistoryStore(defaults: defaults),
                    launchConfig: LaunchConfiguration(
                        isTestMode: true,
                        testScenario: nil,
                        defaultsSuiteName: suiteName,
                        disableSparkle: true,
                        disableHotkeys: true,
                        modelPath: nil
                    )
                )
                let state = AppState(environment: environment)
                streamingService.onFinish = { [weak state, weak streamingService] in
                    guard let state, let streamingService else {
                        return XCTFail("Recording state was released during finalization: \(context)")
                    }
                    XCTAssertFalse(state.isRecording, context)
                    XCTAssertTrue(state.isTranscribing, context)
                    XCTAssertEqual(state.overlayState.phase, .transcribing, context)
                    XCTAssertEqual(state.statusMessage, "Processing...", context)
                    XCTAssertTrue(state.pasteService.pastedTexts.isEmpty, context)
                    XCTAssertTrue(state.historyStore.entries.isEmpty, context)

                    streamingService.onPartialText?("Late recognition result")
                    XCTAssertEqual(state.statusMessage, "Processing...", context)
                    await state.toggleRecording()
                    XCTAssertFalse(state.isRecording, "A hotkey during finalization must not start another recording: \(context)")
                    XCTAssertEqual(streamingService.finishCount, 1, context)

                    // Hold finish across an actor suspension so the UI can keep updating.
                    await Task.yield()
                    XCTAssertTrue(state.isTranscribing, context)
                    XCTAssertEqual(state.overlayState.phase, .transcribing, context)
                    XCTAssertEqual(state.statusMessage, "Processing...", context)
                }

                await state.toggleRecording()
                XCTAssertTrue(state.isRecording, context)
                await state.toggleRecording()

                XCTAssertFalse(state.isRecording, context)
                XCTAssertFalse(state.isTranscribing, context)
                XCTAssertEqual(state.overlayState.phase, .hidden, context)
                XCTAssertEqual(streamingService.finishCount, 1, context)
                if shouldFail {
                    XCTAssertTrue(state.statusMessage.hasPrefix("\(backend.statusName) error:"), context)
                    XCTAssertTrue(state.pasteService.pastedTexts.isEmpty, context)
                    XCTAssertTrue(state.historyStore.entries.isEmpty, context)
                } else if rawText.isEmpty {
                    XCTAssertEqual(state.statusMessage, "No speech detected", context)
                    XCTAssertTrue(state.pasteService.pastedTexts.isEmpty, context)
                    XCTAssertTrue(state.historyStore.entries.isEmpty, context)
                } else {
                    XCTAssertEqual(state.pasteService.pastedTexts, ["I trade on NYSE."], context)
                    XCTAssertEqual(state.historyStore.entries.map(\.text), ["I trade on NYSE."], context)
                }
            }
        }
    }

    // MARK: - No Speech

    func testNoSpeech() async {
        let state = makeAppState(scenario: .noSpeech)

        await state.toggleRecording()
        XCTAssertTrue(state.isRecording)

        await state.toggleRecording()
        XCTAssertFalse(state.isRecording)
        XCTAssertEqual(state.statusMessage, "No speech detected")
        XCTAssertTrue(state.pasteService.pastedTexts.isEmpty)
        XCTAssertTrue(state.historyStore.entries.isEmpty)
    }

    // MARK: - Mic Denied

    func testMicDenied() async {
        let state = makeAppState(scenario: .micDenied)

        await state.toggleRecording()
        XCTAssertFalse(state.isRecording)
        XCTAssertEqual(state.statusMessage, "Microphone permission required")
    }

    // MARK: - Accessibility Denied

    func testAccessibilityDenied() async {
        let state = makeAppState(scenario: .accessibilityDenied)

        // Start recording (mic is granted)
        await state.toggleRecording()
        XCTAssertTrue(state.isRecording)

        // Stop → transcribe succeeds but accessibility is denied → no paste, but saved to history
        await state.toggleRecording()
        XCTAssertFalse(state.isRecording)
        XCTAssertEqual(state.statusMessage, "Accessibility permission required to paste (saved to history)")
        XCTAssertTrue(state.pasteService.pastedTexts.isEmpty)
        XCTAssertEqual(state.historyStore.entries.count, 1)
        XCTAssertEqual(state.historyStore.entries.first?.text, "Hello world")
        XCTAssertEqual(state.overlayState.phase, .accessibilityRequired)
    }

    // MARK: - Model Downloading

    func testModelDownloading() async {
        let state = makeAppState(scenario: .modelDownloading)

        // Try to record while model is downloading
        await state.toggleRecording()
        XCTAssertFalse(state.isRecording)
        XCTAssertEqual(state.overlayState.phase, .modelDownloading)
    }

    // MARK: - Transcription Error

    func testTranscriptionError() async {
        let state = makeAppState(scenario: .transcriptionError)

        await state.toggleRecording()
        XCTAssertTrue(state.isRecording)

        await state.toggleRecording()
        XCTAssertFalse(state.isRecording)
        XCTAssertTrue(state.statusMessage.contains("Transcription error"))
        XCTAssertTrue(state.pasteService.pastedTexts.isEmpty)
        XCTAssertTrue(state.historyStore.entries.isEmpty)
    }

    // MARK: - Cancel Recording

    func testCancelRecording() async {
        let state = makeAppState(scenario: .recordToTranscribeSuccess)

        await state.toggleRecording()
        XCTAssertTrue(state.isRecording)

        state.cancelRecording()
        XCTAssertFalse(state.isRecording)
        XCTAssertEqual(state.statusMessage, "Ready")
        XCTAssertEqual(state.overlayState.phase, .cancelled)
        XCTAssertTrue(state.pasteService.pastedTexts.isEmpty)
    }

    // MARK: - History Management

    func testHistoryManagement() {
        let state = makeAppState(scenario: .historyManagement)

        XCTAssertEqual(state.historyStore.entries.count, 3)
        XCTAssertEqual(state.historyStore.entries[0].text, "Third entry")
        XCTAssertEqual(state.historyStore.entries[1].text, "Second entry")
        XCTAssertEqual(state.historyStore.entries[2].text, "First entry")

        // Delete single
        let idToDelete = state.historyStore.entries[1].id
        state.historyStore.delete(id: idToDelete)
        XCTAssertEqual(state.historyStore.entries.count, 2)
        XCTAssertFalse(state.historyStore.entries.contains(where: { $0.id == idToDelete }))

        // Clear all
        state.historyStore.clearAll()
        XCTAssertTrue(state.historyStore.entries.isEmpty)
    }
}

@MainActor
private final class StubStreamingTranscriptionService: StreamingTranscriptionService {
    var onPartialText: ((String) -> Void)?
    var onStatusChange: ((String) -> Void)?
    var onFailure: ((Error) -> Void)?
    var beginFailure: Error?
    var onFinish: (() async -> Void)?
    let finalText: String
    let shouldFail: Bool
    private(set) var finishCount = 0

    init(finalText: String, shouldFail: Bool = false) {
        self.finalText = finalText
        self.shouldFail = shouldFail
    }

    func configure(language: WhisperLanguage) {}

    func begin() {
        if let beginFailure {
            onFailure?(beginFailure)
            return
        }
        onPartialText?(finalText)
    }

    func append(audioFrames: [Float]) {}

    func finish() async throws -> String {
        finishCount += 1
        await onFinish?()
        if shouldFail { throw TranscriptionError.stubError }
        return finalText
    }

    func cancel() {}
}

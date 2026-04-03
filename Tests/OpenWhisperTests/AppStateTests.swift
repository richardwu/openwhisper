import XCTest
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

    // MARK: - Launch Ready State

    func testLaunchReadyState() {
        let state = makeAppState(scenario: .launchReadyState)
        XCTAssertEqual(state.statusMessage, "Ready")
        XCTAssertFalse(state.isRecording)
        XCTAssertFalse(state.isTranscribing)
        XCTAssertTrue(state.modelManager.isModelReady)
        XCTAssertTrue(state.permissionsClient.isMicrophoneAuthorized)
        XCTAssertTrue(state.permissionsClient.isAccessibilityGranted)
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

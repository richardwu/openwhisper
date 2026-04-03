import XCTest

/// Scenario names matching TestScenario.rawValue in the app target.
/// UI tests run in a separate process, so we pass the raw string via env vars.
enum UITestScenario: String {
    case launchReadyState = "launch_ready_state"
    case recordToTranscribeSuccess = "record_to_transcribe_success"
    case noSpeech = "no_speech"
    case micDenied = "mic_denied"
    case accessibilityDenied = "accessibility_denied"
    case modelDownloading = "model_downloading"
    case transcriptionError = "transcription_error"
    case historyManagement = "history_management"
}

extension XCUIApplication {
    /// Launch with test mode environment for a given scenario.
    func launchForTest(scenario: UITestScenario) {
        let suiteName = "com.openwhisper.uitest.\(UUID().uuidString)"
        launchEnvironment["OPENWHISPER_TEST_MODE"] = "1"
        launchEnvironment["OPENWHISPER_TEST_SCENARIO"] = scenario.rawValue
        launchEnvironment["OPENWHISPER_DEFAULTS_SUITE"] = suiteName
        launchEnvironment["OPENWHISPER_DISABLE_SPARKLE"] = "1"
        launchEnvironment["OPENWHISPER_DISABLE_HOTKEYS"] = "1"
        launch()
    }
}

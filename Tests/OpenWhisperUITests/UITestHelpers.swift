import XCTest

extension XCUIApplication {
    /// Launch with test mode environment for a given scenario.
    func launchForTest(scenario: String) {
        let suiteName = "com.openwhisper.uitest.\(UUID().uuidString)"
        launchEnvironment["OPENWHISPER_TEST_MODE"] = "1"
        launchEnvironment["OPENWHISPER_TEST_SCENARIO"] = scenario
        launchEnvironment["OPENWHISPER_DEFAULTS_SUITE"] = suiteName
        launchEnvironment["OPENWHISPER_DISABLE_SPARKLE"] = "1"
        launchEnvironment["OPENWHISPER_DISABLE_HOTKEYS"] = "1"
        launch()
    }
}

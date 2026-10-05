import Foundation

/// Parses environment variables and launch arguments to configure test mode behavior.
struct LaunchConfiguration {
    let isTestMode: Bool
    let testScenario: String?
    let defaultsSuiteName: String?
    let disableSparkle: Bool
    let disableHotkeys: Bool
    let modelPath: String?

    /// Only fixture runs can opt out of all application presentation.
    var isHeadlessTest: Bool {
        isTestMode && ProcessInfo.processInfo.environment["OPENWHISPER_HEADLESS_TESTS"] == "1"
    }

    static var current: LaunchConfiguration {
        let env = ProcessInfo.processInfo.environment
        let isTest = env["OPENWHISPER_TEST_MODE"] == "1"
        return LaunchConfiguration(
            isTestMode: isTest,
            testScenario: env["OPENWHISPER_TEST_SCENARIO"],
            defaultsSuiteName: env["OPENWHISPER_DEFAULTS_SUITE"],
            disableSparkle: isTest || env["OPENWHISPER_DISABLE_SPARKLE"] == "1",
            disableHotkeys: isTest || env["OPENWHISPER_DISABLE_HOTKEYS"] == "1",
            modelPath: env["OPENWHISPER_MODEL_PATH"]
        )
    }
}

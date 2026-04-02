import XCTest

final class OpenWhisperUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDown() {
        app.terminate()
        super.tearDown()
    }

    // MARK: - launch_ready_state

    func testLaunchReadyState() {
        app.launchForTest(scenario: "launch_ready_state")

        // Main window should be visible
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))

        // Tabs should be present
        XCTAssertTrue(window.staticTexts["Home"].waitForExistence(timeout: 5))

        // Status should show Ready
        XCTAssertTrue(window.staticTexts["Ready"].waitForExistence(timeout: 5))
    }

    // MARK: - record_to_transcribe_success

    func testRecordToTranscribeSuccess() throws {
        throw XCTSkip("UI record→transcribe flow not yet implemented — requires menu bar interaction")
    }

    // MARK: - mic_denied

    func testMicDenied() {
        app.launchForTest(scenario: "mic_denied")

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))

        // Permission banner should be visible
        XCTAssertTrue(window.staticTexts["Microphone Access Required"].waitForExistence(timeout: 5))
    }

    // MARK: - model_downloading

    func testModelDownloading() {
        app.launchForTest(scenario: "model_downloading")

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))

        // Model is downloading at 45% — progress indicator should be visible
        XCTAssertTrue(window.staticTexts["45%"].waitForExistence(timeout: 5))
    }

    // MARK: - accessibility_denied

    func testAccessibilityDenied() {
        app.launchForTest(scenario: "accessibility_denied")

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))

        // Accessibility permission banner should be visible
        XCTAssertTrue(window.staticTexts["Accessibility Access Required"].waitForExistence(timeout: 5))
    }

    // MARK: - history_management

    func testHistoryManagement() {
        app.launchForTest(scenario: "history_management")

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))

        // Navigate to History tab
        let historyTab = window.staticTexts["History"]
        XCTAssertTrue(historyTab.waitForExistence(timeout: 5))
        historyTab.click()

        // History entries should be visible
        XCTAssertTrue(window.staticTexts["Third entry"].waitForExistence(timeout: 5))
        XCTAssertTrue(window.staticTexts["Second entry"].exists)
        XCTAssertTrue(window.staticTexts["First entry"].exists)
    }
}

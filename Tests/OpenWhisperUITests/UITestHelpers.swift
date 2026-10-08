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
    func launchForTest(
        scenario: UITestScenario,
        suiteName: String
    ) {
        launchEnvironment["OPENWHISPER_TEST_MODE"] = "1"
        launchEnvironment["OPENWHISPER_TEST_SCENARIO"] = scenario.rawValue
        launchEnvironment["OPENWHISPER_DEFAULTS_SUITE"] = suiteName
        launchEnvironment["OPENWHISPER_DISABLE_SPARKLE"] = "1"
        launchEnvironment["OPENWHISPER_DISABLE_HOTKEYS"] = "1"
        launch()
    }
}

extension XCUIElement {
    func historyElement(
        _ action: String, text: String, file: StaticString = #filePath, line: UInt = #line
    ) -> XCUIElement {
        let entry = descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND (label == %@ OR value == %@)",
            "history.entry.", text, text
        )).firstMatch
        if action == "entry" { return entry }
        guard entry.waitForExistence(timeout: 5) else {
            XCTFail("History entry not found: \(text)", file: file, line: line)
            return entry
        }
        return element(entry.identifier.replacingOccurrences(of: "history.entry.", with: "history.\(action)."))
    }

    /// Resolve identifiers without depending on how SwiftUI exposes a view's role.
    func element(_ identifier: String) -> XCUIElement {
        descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    func replaceText(with text: String) {
        click()
        typeKey("a", modifierFlags: .command)
        typeKey(.delete, modifierFlags: [])
        if !text.isEmpty { typeText(text) }
    }
}

extension XCTestCase {
    /// Existence alone misses clipped/offscreen controls, including the Vocabulary regression.
    func assertVisible(
        _ element: XCUIElement,
        in window: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(element.waitForExistence(timeout: 5), file: file, line: line)
        if element.isEnabled {
            XCTAssertTrue(element.isHittable, "\(element.identifier) must be reachable", file: file, line: line)
        }
        let frame = element.frame
        let windowFrame = window.frame.insetBy(dx: -1, dy: -1)
        XCTAssertGreaterThan(frame.width, 0, file: file, line: line)
        XCTAssertGreaterThan(frame.height, 0, file: file, line: line)
        XCTAssertTrue(
            windowFrame.contains(frame),
            "\(element.identifier) is outside the window: \(frame), window: \(window.frame)",
            file: file, line: line
        )
    }

    func waitForValue(
        _ value: String,
        on element: XCUIElement,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let expected = NSPredicate { _, _ in
            element.label == value || element.value as? String == value
        }
        XCTAssertEqual(
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: expected, object: nil)], timeout: timeout),
            .completed, "Expected \(value); label: \(element.label), value: \(String(describing: element.value))",
            file: file, line: line
        )
    }
}

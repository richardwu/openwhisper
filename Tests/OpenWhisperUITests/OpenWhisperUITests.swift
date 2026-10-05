import AppKit
import XCTest

/// Major customer journeys use fixture audio/services and a unique defaults suite.
/// These tests never request microphone access, paste into another app, or download a model.
/// Fixture-only recording buttons call the production AppState methods. Global hotkey
/// dispatch, hardware capture, and CGEvent paste into a different app need separate checks.
final class OpenWhisperUITests: XCTestCase {
    private var app: XCUIApplication!
    private var originalPasteboardItems: [[NSPasteboard.PasteboardType: Data]] = []
    private var changedPasteboard = false
    private var launchedDefaultsSuites = Set<String>()

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        originalPasteboardItems = []
        changedPasteboard = false
        launchedDefaultsSuites = []
    }

    override func tearDown() {
        if let testRun, testRun.failureCount > 0 {
            if window.exists {
                let screenshot = XCTAttachment(screenshot: window.screenshot())
                screenshot.name = "Failed customer journey"
                screenshot.lifetime = .keepAlways
                add(screenshot)
            }
            let hierarchy = XCTAttachment(string: window.debugDescription)
            hierarchy.name = "Accessibility hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        app.terminate()
        for suite in launchedDefaultsSuites {
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
        if changedPasteboard {
            let items = originalPasteboardItems.map { data in
                let item = NSPasteboardItem()
                for (type, value) in data { item.setData(value, forType: type) }
                return item
            }
            NSPasteboard.general.clearContents()
            if !items.isEmpty { NSPasteboard.general.writeObjects(items) }
        }
        super.tearDown()
    }

    // Recording creates a floating overlay. Keep queries on the main window.
    private var window: XCUIElement {
        app.windows.containing(.any, identifier: "navigation.home").firstMatch
    }

    private func launch(_ scenario: UITestScenario = .launchReadyState, suiteName: String? = nil) {
        let suite = suiteName ?? "com.openwhisper.uitest.\(UUID().uuidString)"
        launchedDefaultsSuites.insert(suite)
        app.launchForTest(scenario: scenario, suiteName: suite)
        XCTAssertTrue(window.waitForExistence(timeout: 10))
    }

    private func navigate(_ tab: String) {
        let row = window.element("navigation.\(tab)")
        assertVisible(row, in: window)
        row.click()
    }

    private func assertNavigationAndFooter() {
        let rows = ["home", "history", "vocabulary", "settings"].map {
            window.element("navigation.\($0)")
        }
        rows.forEach { assertVisible($0, in: window) }
        for index in 1..<rows.count {
            XCTAssertGreaterThan(rows[index].frame.midY, rows[index - 1].frame.midY)
        }
        assertVisible(window.element("footer.status"), in: window)
    }

    private func addTerms(_ text: String) {
        let input = window.element("vocabulary.input")
        assertVisible(input, in: window)
        input.replaceText(with: text)
        let add = window.element("vocabulary.add")
        assertVisible(add, in: window)
        XCTAssertTrue(add.isEnabled)
        add.click()
        waitForValue("", on: input)
    }

    private func recordFixture() {
        let toggle = window.element("recording.toggle")
        assertVisible(toggle, in: window)
        toggle.click()
        waitForValue("Recording...", on: window.element("footer.status"))
        toggle.click()
    }

    private func copyAndVerify(_ button: XCUIElement, expected text: String) {
        // A previous successful copy must not hide a broken copy action.
        if !changedPasteboard {
            originalPasteboardItems = (NSPasteboard.general.pasteboardItems ?? []).map { item in
                Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                    item.data(forType: type).map { (type, $0) }
                })
            }
            changedPasteboard = true
        }
        let sentinel = "OpenWhisper copy sentinel \(UUID().uuidString)"
        NSPasteboard.general.clearContents()
        XCTAssertTrue(NSPasteboard.general.setString(sentinel, forType: .string))
        button.click()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), text)
    }

    func testRecordingModeUpdatesHomeAndPersists() {
        let suite = "com.openwhisper.uitest.\(UUID().uuidString)"
        launch(suiteName: suite)
        XCTAssertTrue(window.staticTexts["Press again to stop and transcribe"].exists)
        navigate("settings")
        let mode = window.element("settings.recordingMode")
        assertVisible(mode, in: window)
        mode.click()
        app.menuItems["Press & Hold"].click()
        navigate("home")
        XCTAssertTrue(window.staticTexts["Press and hold your hotkey to record"].waitForExistence(timeout: 5))
        XCTAssertTrue(window.staticTexts["Release to stop and transcribe"].exists)
        XCTAssertTrue(window.staticTexts["Hold to record"].exists)
        app.terminate()
        launch(suiteName: suite)
        XCTAssertTrue(window.staticTexts["Release to stop and transcribe"].exists)
        navigate("settings")
        window.element("settings.recordingMode").click()
        app.menuItems["Toggle"].click()
        navigate("home")
        XCTAssertTrue(window.staticTexts["Press again to stop and transcribe"].waitForExistence(timeout: 5))
    }

    func testLaunchAndNavigateEverySection() {
        launch()
        waitForValue("Ready", on: window.element("footer.status"))
        assertNavigationAndFooter()

        navigate("history")
        XCTAssertTrue(window.element("history.empty").waitForExistence(timeout: 5))
        assertNavigationAndFooter()

        navigate("vocabulary")
        assertVisible(window.element("vocabulary.input"), in: window)
        assertNavigationAndFooter()

        navigate("settings")
        assertVisible(window.element("settings.modelPicker"), in: window)
        assertNavigationAndFooter()

        navigate("home")
        XCTAssertTrue(window.staticTexts["Voice-to-text, locally and privately"].waitForExistence(timeout: 5))
        assertNavigationAndFooter()
    }

    func testEmptyVocabularyKeepsSidebarAndEditorInsideWindow() {
        launch()
        navigate("vocabulary")

        XCTAssertTrue(window.element("vocabulary.empty").waitForExistence(timeout: 5))
        assertNavigationAndFooter()
        let input = window.element("vocabulary.input")
        let add = window.element("vocabulary.add")
        assertVisible(input, in: window)
        assertVisible(add, in: window)
        XCTAssertFalse(add.isEnabled)
        XCTAssertGreaterThan(input.frame.minX, window.element("navigation.vocabulary").frame.maxX)

        // Repeat the route that previously displaced the sidebar and footer.
        navigate("settings")
        navigate("vocabulary")
        assertNavigationAndFooter()
        assertVisible(input, in: window)
    }

    func testVocabularyMultiAddSearchRemoveAndPersist() {
        let suite = "com.openwhisper.uitest.\(UUID().uuidString)"
        launch(suiteName: suite)
        navigate("vocabulary")
        addTerms("AcmeDB, kubernetes, NASDAQ, acmedb,,")

        for term in ["AcmeDB", "kubernetes", "NASDAQ"] {
            assertVisible(window.element("vocabulary.term.\(term)"), in: window)
        }
        waitForValue("3 terms", on: window.element("vocabulary.count"))
        XCTAssertFalse(window.element("vocabulary.term.acmedb").exists)
        assertNavigationAndFooter()

        let search = window.element("vocabulary.search")
        assertVisible(search, in: window)
        search.replaceText(with: "ACME")
        assertVisible(window.element("vocabulary.term.AcmeDB"), in: window)
        XCTAssertFalse(window.element("vocabulary.term.kubernetes").exists)
        waitForValue("1 of 3 terms", on: window.element("vocabulary.count"))

        search.replaceText(with: "does-not-match")
        XCTAssertTrue(window.element("vocabulary.noMatches").waitForExistence(timeout: 5))
        waitForValue("0 of 3 terms", on: window.element("vocabulary.count"))
        search.replaceText(with: "")

        window.element("vocabulary.remove.NASDAQ").click()
        XCTAssertFalse(window.element("vocabulary.term.NASDAQ").exists)
        waitForValue("2 terms", on: window.element("vocabulary.count"))

        // Recreate the app process while keeping the same isolated defaults suite.
        app.terminate()
        launch(suiteName: suite)
        navigate("vocabulary")
        assertVisible(window.element("vocabulary.term.AcmeDB"), in: window)
        assertVisible(window.element("vocabulary.term.kubernetes"), in: window)
        XCTAssertFalse(window.element("vocabulary.term.NASDAQ").exists)
        waitForValue("2 terms", on: window.element("vocabulary.count"))
        window.element("vocabulary.remove.AcmeDB").click()
        waitForValue("1 term", on: window.element("vocabulary.count"))

        window.element("vocabulary.deleteAll").click()
        let deleteAllSheet = window.sheets.containing(.button, identifier: "Delete All").firstMatch
        XCTAssertTrue(deleteAllSheet.waitForExistence(timeout: 5))
        deleteAllSheet.buttons["Delete All"].click()
        XCTAssertTrue(window.element("vocabulary.empty").waitForExistence(timeout: 5))
        assertVisible(window.element("vocabulary.input"), in: window)
        assertNavigationAndFooter()
    }

    func testRecordToHistoryAndFooterCopy() {
        launch(.recordToTranscribeSuccess)
        recordFixture()
        waitForValue("Pasted: Hello world", on: window.element("footer.status"))

        let copy = window.element("footer.copy")
        assertVisible(copy, in: window)
        copyAndVerify(copy, expected: "Hello world")
        waitForValue("Latest transcription copied", on: copy)

        navigate("history")
        assertVisible(window.element("history.entry.Hello world"), in: window)
        copyAndVerify(window.element("history.copy.Hello world"), expected: "Hello world")
        assertNavigationAndFooter()
    }

    func testCancelRecordingDoesNotCreateHistory() {
        launch(.recordToTranscribeSuccess)
        window.element("recording.toggle").click()
        waitForValue("Recording...", on: window.element("footer.status"))
        let cancel = window.element("recording.cancel")
        assertVisible(cancel, in: window)
        cancel.click()
        waitForValue("Ready", on: window.element("footer.status"))
        XCTAssertFalse(window.element("footer.copy").exists)
        navigate("history")
        XCTAssertTrue(window.element("history.empty").waitForExistence(timeout: 5))
    }

    func testNoSpeechDoesNotCreateHistoryAndCanRecordAgain() {
        launch(.noSpeech)
        recordFixture()
        waitForValue("No speech detected", on: window.element("footer.status"))
        XCTAssertTrue(window.element("recording.toggle").isEnabled)
        recordFixture()
        waitForValue("No speech detected", on: window.element("footer.status"))
        navigate("history")
        XCTAssertTrue(window.element("history.empty").waitForExistence(timeout: 5))
    }

    func testTranscriptionErrorIsRecoverable() {
        launch(.transcriptionError)
        recordFixture()
        waitForValue("Transcription error: Transcription failed (stub)", on: window.element("footer.status"))
        XCTAssertTrue(window.element("recording.toggle").isEnabled)
        window.element("recording.toggle").click()
        waitForValue("Recording...", on: window.element("footer.status"))
        window.element("recording.cancel").click()
        waitForValue("Ready", on: window.element("footer.status"))
    }

    func testHistoryCopyAndDeleteConfirmation() {
        launch(.historyManagement)
        navigate("history")
        for text in ["Third entry", "Second entry", "First entry"] {
            assertVisible(window.element("history.entry.\(text)"), in: window)
        }
        copyAndVerify(window.element("history.copy.Second entry"), expected: "Second entry")

        window.element("history.delete.Second entry").click()
        // macOS exposes SwiftUI confirmation alerts as sheets, not Alert nodes.
        let deletionSheet = window.sheets.containing(.button, identifier: "Delete").firstMatch
        XCTAssertTrue(deletionSheet.waitForExistence(timeout: 5))
        deletionSheet.buttons["Cancel"].click()
        XCTAssertTrue(window.element("history.entry.Second entry").exists)
        window.element("history.delete.Second entry").click()
        XCTAssertTrue(deletionSheet.waitForExistence(timeout: 5))
        deletionSheet.buttons["Delete"].click()
        XCTAssertFalse(window.element("history.entry.Second entry").exists)

        window.element("history.deleteAll").click()
        let deleteAllSheet = window.sheets.containing(.button, identifier: "Delete All").firstMatch
        XCTAssertTrue(deleteAllSheet.waitForExistence(timeout: 5))
        deleteAllSheet.buttons["Delete All"].click()
        XCTAssertTrue(window.element("history.empty").waitForExistence(timeout: 5))
        XCTAssertFalse(window.element("footer.copy").exists)
        waitForValue("Ready", on: window.element("footer.status"))
        assertNavigationAndFooter()
    }

    func testModelSearchSelectionAndSupportedLanguageReset() {
        launch()
        navigate("settings")
        let picker = window.element("settings.modelPicker")
        assertVisible(picker, in: window)
        picker.click()
        let modelSearch = app.textFields["settings.modelSearch"]
        XCTAssertTrue(modelSearch.waitForExistence(timeout: 5))
        modelSearch.replaceText(with: "medium")
        let medium = app.buttons["settings.model.whisperMedium"]
        XCTAssertTrue(medium.waitForExistence(timeout: 5))
        medium.click()
        waitForValue("Whisper Medium, model ready", on: window.element("settings.modelStatus"))

        let language = window.element("settings.language")
        assertVisible(language, in: window)
        language.click()
        let spanish = app.menuItems["Spanish"]
        XCTAssertTrue(spanish.waitForExistence(timeout: 5))
        spanish.click()
        waitForValue("Spanish", on: language)

        picker.click()
        XCTAssertTrue(modelSearch.waitForExistence(timeout: 5))
        modelSearch.replaceText(with: "Moonshine Small")
        let moonshine = app.buttons["settings.model.moonshineStreamingSmall"]
        XCTAssertTrue(moonshine.waitForExistence(timeout: 5))
        moonshine.click()
        waitForValue("Moonshine Small, model ready", on: window.element("settings.modelStatus"))
        waitForValue("English", on: language)
        language.click()
        XCTAssertTrue(app.menuItems["English"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.menuItems["Spanish"].exists)
        app.typeKey(.escape, modifierFlags: [])
        assertNavigationAndFooter()
    }

    func testPermissionBanners() {
        launch(.micDenied)
        XCTAssertTrue(window.staticTexts["Microphone Access Required"].waitForExistence(timeout: 5))
        app.terminate()
        launch(.accessibilityDenied)
        XCTAssertTrue(window.staticTexts["Accessibility Access Required"].waitForExistence(timeout: 5))
        assertNavigationAndFooter()
    }

    func testModelDownloadProgress() {
        launch(.modelDownloading)
        XCTAssertTrue(window.staticTexts["45%"].waitForExistence(timeout: 5))
        assertNavigationAndFooter()
    }
}

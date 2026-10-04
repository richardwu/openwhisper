import AppKit
import XCTest
@testable import OpenWhisper

@MainActor
final class CorrectionLearningServiceTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "com.openwhisper.correction-test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = ""
        super.tearDown()
    }

    func testLearnsOneCorrectionFromTheInsertedSpan() {
        let reader = BoundedCorrectionReader(value: "Draft:   ", selectedRange: NSRange(location: 9, length: 0))
        let service = CorrectionLearningService(reader: reader, defaults: defaults)

        service.beginInsertion("open whisper")
        reader.setValue("Draft:   open whisper")
        service.observeCurrentText()
        reader.setValue("Draft:   OpenWhisper")
        service.observeCurrentText()
        service.finishObservation()

        XCTAssertEqual(service.entries.count, 1)
        XCTAssertEqual(service.entries.first?.original, "open whisper")
        XCTAssertEqual(service.entries.first?.replacement, "OpenWhisper")
        XCTAssertEqual(service.learnedTerms, ["OpenWhisper"])

        let reloaded = CorrectionLearningService(reader: reader, defaults: defaults)
        XCTAssertEqual(reloaded.learnedTerms, ["OpenWhisper"])
    }

    func testCanFeedTheCorrectionIntoVocabularyStore() {
        let vocabulary = VocabularyStore(defaults: defaults)
        let reader = BoundedCorrectionReader(value: "Draft:   ", selectedRange: NSRange(location: 9, length: 0))
        let service = CorrectionLearningService(
            reader: reader,
            defaults: defaults,
            recordCorrection: { vocabulary.recordCorrection(from: $0, to: $1) },
            learnedTerms: { vocabulary.learnedTerms }
        )

        service.beginInsertion("open whisper")
        reader.setValue("Draft:   open whisper")
        service.observeCurrentText()
        reader.setValue("Draft:   OpenWhisper")
        service.observeCurrentText()
        service.finishObservation()

        XCTAssertTrue(vocabulary.learnedTerms.contains("OpenWhisper"))
        XCTAssertTrue(service.correctionsPrompt().contains("OpenWhisper"))
    }

    func testRejectsChangedNumbers() {
        let reader = BoundedCorrectionReader(value: "Draft:   ", selectedRange: NSRange(location: 9, length: 0))
        let service = CorrectionLearningService(reader: reader, defaults: defaults)

        service.beginInsertion("build 42")
        reader.setValue("Draft:   build 42")
        service.observeCurrentText()
        reader.setValue("Draft:   build 43")
        service.observeCurrentText()
        service.finishObservation()

        XCTAssertTrue(service.entries.isEmpty)
    }

    func testStopsWhenFocusChangesBeforeCorrection() {
        let reader = BoundedCorrectionReader(value: "Draft:   ", selectedRange: NSRange(location: 9, length: 0))
        let service = CorrectionLearningService(reader: reader, defaults: defaults)

        service.beginInsertion("open whisper")
        reader.setValue("Draft:   open whisper")
        service.observeCurrentText()
        reader.focused = false
        reader.setValue("Draft:   OpenWhisper")
        service.observeCurrentText()
        service.finishObservation()

        XCTAssertTrue(service.entries.isEmpty)
    }
}

@MainActor
private final class BoundedCorrectionReader: CorrectionAccessibilityReader {
    let target = CorrectionTextTarget(identifier: "fake-editor")
    var value: String
    let selectedRange: NSRange
    var focused = true

    init(value: String, selectedRange: NSRange) {
        self.value = value
        self.selectedRange = selectedRange
    }

    func setValue(_ value: String) {
        self.value = value
    }

    func focusedTextSnapshot() -> (target: CorrectionTextTarget, snapshot: CorrectionTextSnapshot)? {
        guard focused else { return nil }
        return (target, snapshot())
    }

    func textSnapshot(for target: CorrectionTextTarget, around range: NSRange) -> CorrectionTextSnapshot? {
        guard focused, target.identifier == self.target.identifier else { return nil }
        return snapshot()
    }

    func isStillFocused(_ target: CorrectionTextTarget) -> Bool {
        focused && target.identifier == self.target.identifier
    }

    private func snapshot() -> CorrectionTextSnapshot {
        CorrectionTextSnapshot(text: value, offset: 0, selectedRange: selectedRange)
    }
}

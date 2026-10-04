import XCTest
@testable import OpenWhisper

@MainActor
final class CorrectionLearningTests: XCTestCase {
    func testLearnsOneCorrectionInsideOpenWhisperPaste() {
        let reader = FakeCorrectionReader(
            baseline: CorrectionTextSnapshot(
                text: "say ",
                selectedRange: NSRange(location: 4, length: 0)
            ),
            observations: [
                CorrectionTextSnapshot(text: "say open whisper"),
                CorrectionTextSnapshot(text: "say OpenWhisper")
            ]
        )
        let defaults = UserDefaults(suiteName: "com.openwhisper.correction.\(UUID().uuidString)")!
        let service = CorrectionLearningService(reader: reader, defaults: defaults)

        service.beginInsertion("open whisper")
        service.observeCurrentText()
        service.observeCurrentText()
        service.finishObservation()

        XCTAssertEqual(service.entries.map(\.replacement), ["OpenWhisper"])
        XCTAssertEqual(service.entries.first?.original, "open whisper")
        XCTAssertEqual(service.correctionsPrompt(), "OpenWhisper")
    }

    func testDoesNotLearnWhenFocusedElementChanges() {
        let reader = FakeCorrectionReader(
            baseline: CorrectionTextSnapshot(
                text: "say ",
                selectedRange: NSRange(location: 4, length: 0)
            ),
            observations: [CorrectionTextSnapshot(text: "say open whisper")],
            remainsFocused: false
        )
        let service = CorrectionLearningService(reader: reader, defaults: UserDefaults(suiteName: "com.openwhisper.correction.\(UUID().uuidString)")!)

        service.beginInsertion("open whisper")
        service.observeCurrentText()
        service.finishObservation()

        XCTAssertEqual(service.entries, [])
    }

    func testDoesNotLearnChangedNumbers() {
        let reader = FakeCorrectionReader(
            baseline: CorrectionTextSnapshot(
                text: "run ",
                selectedRange: NSRange(location: 4, length: 0)
            ),
            observations: [
                CorrectionTextSnapshot(text: "run build 123"),
                CorrectionTextSnapshot(text: "run Build 124")
            ]
        )
        let service = CorrectionLearningService(reader: reader, defaults: UserDefaults(suiteName: "com.openwhisper.correction.\(UUID().uuidString)")!)

        service.beginInsertion("build 123")
        service.observeCurrentText()
        service.observeCurrentText()
        service.finishObservation()

        XCTAssertTrue(service.entries.isEmpty)
    }

    func testDoesNotLearnTextAppendedAfterThePaste() {
        let reader = FakeCorrectionReader(
            baseline: CorrectionTextSnapshot(
                text: "say ",
                selectedRange: NSRange(location: 4, length: 0)
            ),
            observations: [
                CorrectionTextSnapshot(text: "say open whisper"),
                CorrectionTextSnapshot(text: "say open whisper later")
            ]
        )
        let service = CorrectionLearningService(reader: reader, defaults: UserDefaults(suiteName: "com.openwhisper.correction.\(UUID().uuidString)")!)

        service.beginInsertion("open whisper")
        service.observeCurrentText()
        service.observeCurrentText()
        service.finishObservation()

        XCTAssertTrue(service.entries.isEmpty)
    }

    func testLiveRecorderCallbackFeedsSharedVocabularyStore() {
        let reader = FakeCorrectionReader(
            baseline: CorrectionTextSnapshot(
                text: "say ",
                selectedRange: NSRange(location: 4, length: 0)
            ),
            observations: [
                CorrectionTextSnapshot(text: "say open whisper"),
                CorrectionTextSnapshot(text: "say OpenWhisper")
            ]
        )
        var recorded: [(String, String)] = []
        let service = CorrectionLearningService(
            reader: reader,
            defaults: UserDefaults(suiteName: "com.openwhisper.correction.\(UUID().uuidString)")!,
            recordCorrection: { original, corrected in
                recorded.append((original, corrected))
                return true
            },
            learnedTerms: { ["OpenWhisper"] }
        )

        service.beginInsertion("open whisper")
        service.observeCurrentText()
        service.observeCurrentText()
        service.finishObservation()

        XCTAssertEqual(recorded.map(\.0), ["open whisper"])
        XCTAssertEqual(recorded.map(\.1), ["OpenWhisper"])
        XCTAssertEqual(service.learnedTerms, ["OpenWhisper"])
        XCTAssertTrue(service.entries.isEmpty, "The shared VocabularyStore callback is the persistence owner")
    }
}

@MainActor
private final class FakeCorrectionReader: CorrectionAccessibilityReader {
    let target = CorrectionTextTarget(identifier: "fake-target")
    let baseline: CorrectionTextSnapshot
    var observations: [CorrectionTextSnapshot]
    let remainsFocused: Bool

    init(baseline: CorrectionTextSnapshot, observations: [CorrectionTextSnapshot], remainsFocused: Bool = true) {
        self.baseline = baseline
        self.observations = observations
        self.remainsFocused = remainsFocused
    }

    func focusedTextSnapshot() -> (target: CorrectionTextTarget, snapshot: CorrectionTextSnapshot)? {
        (target, baseline)
    }

    func textSnapshot(for target: CorrectionTextTarget, around range: NSRange) -> CorrectionTextSnapshot? {
        guard !observations.isEmpty else { return nil }
        return observations.removeFirst()
    }

    func isStillFocused(_ target: CorrectionTextTarget) -> Bool {
        remainsFocused
    }
}

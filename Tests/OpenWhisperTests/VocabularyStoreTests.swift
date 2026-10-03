import XCTest
@testable import OpenWhisper

final class VocabularyStoreTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var store: VocabularyStore!

    override func setUp() {
        super.setUp()
        suiteName = "com.openwhisper.vocabulary-test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        store = VocabularyStore(defaults: defaults, maxPromptCharacters: 900, maxTerms: 96)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        store = nil
        suiteName = ""
        super.tearDown()
    }

    func testBundledPromptContainsOpenWhisperAndCodingTerms() throws {
        let prompt = try XCTUnwrap(store.initialPrompt)

        XCTAssertTrue(prompt.contains("OpenWhisper"))
        XCTAssertTrue(prompt.contains("SwiftUI"))
        XCTAssertLessThanOrEqual(prompt.count, 900)
    }

    func testLearnedCorrectionIsPrioritizedAndPersists() throws {
        XCTAssertTrue(store.recordCorrection(from: "use open whisper", to: "use OpenWhisper"))
        XCTAssertTrue(store.learnedTerms.contains("OpenWhisper"))

        let prompt = try XCTUnwrap(store.initialPrompt)
        XCTAssertTrue(prompt.hasPrefix("OpenWhisper"))

        let reloaded = VocabularyStore(defaults: defaults, maxPromptCharacters: 900, maxTerms: 96)
        XCTAssertTrue(reloaded.learnedTerms.contains("OpenWhisper"))
    }

    func testOrdinaryProseCorrectionIsIgnored() {
        XCTAssertFalse(store.recordCorrection(from: "teh quick fox", to: "the quick fox"))
        XCTAssertTrue(store.learnedTerms.isEmpty)
    }

    func testCorrectionDropsSentencePunctuation() {
        XCTAssertTrue(store.recordCorrection(from: "use open whisper", to: "use OpenWhisper."))
        XCTAssertEqual(store.learnedTerms, ["OpenWhisper"])
    }

    func testForgetLeavesBundledTermAvailable() {
        XCTAssertTrue(store.learn(term: "PostgreSQL"))
        store.forget(term: "PostgreSQL")

        XCTAssertFalse(store.learnedTerms.contains("PostgreSQL"))
        XCTAssertTrue(store.candidateTerms.contains("PostgreSQL"))
    }

    func testPromptBudgetAndTermLimitAreEnforced() throws {
        let smallStore = VocabularyStore(defaults: defaults, maxPromptCharacters: 64, maxTerms: 2)
        let prompt = try XCTUnwrap(smallStore.initialPrompt)

        XCTAssertLessThanOrEqual(prompt.count, 64)
        XCTAssertLessThanOrEqual(prompt.split(separator: ",").count, 2)
    }
}

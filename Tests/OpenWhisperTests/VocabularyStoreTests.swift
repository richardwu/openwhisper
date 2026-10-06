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
        XCTAssertTrue(prompt.contains("PostgreSQL"))
        XCTAssertTrue(prompt.contains("ChatGPT"))
        XCTAssertTrue(prompt.contains("PRD"))
        XCTAssertTrue(prompt.contains("NYSE"))
        XCTAssertTrue(prompt.contains("NASDAQ"))
        XCTAssertLessThanOrEqual(prompt.count, 900)
    }

    func testDefaultPromptUsesTheMixedHighPriorityPrefix() throws {
        let defaultStore = VocabularyStore(defaults: defaults)
        let prompt = try XCTUnwrap(defaultStore.initialPrompt)

        XCTAssertTrue(prompt.contains("OpenWhisper"))
        XCTAssertTrue(prompt.contains("PostgreSQL"))
        XCTAssertTrue(prompt.contains("ChatGPT"))
        XCTAssertTrue(prompt.contains("PRD"))
        XCTAssertLessThanOrEqual(prompt.count, VocabularyStore.defaultMaxPromptCharacters)
        XCTAssertLessThanOrEqual(
            prompt.split(separator: ",").count,
            VocabularyStore.defaultMaxTerms
        )
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

    func testLocalCorrectionRepairsPhoneticAcronym() {
        XCTAssertEqual(store.correctTranscription("I trade on Nyzi."), "I trade on NYSE.")
        XCTAssertEqual(store.correctTranscription("I trade on Nisy."), "I trade on NYSE.")
    }

    func testLearnedCustomTermIsUsedByCorrectionPass() {
        XCTAssertTrue(store.learn(term: "AcmeDB"))
        XCTAssertEqual(store.correctTranscription("connect to acmedb"), "connect to AcmeDB")
        XCTAssertTrue(store.learn(term: "Acme Database"))
        XCTAssertEqual(store.correctTranscription("open acme database"), "open Acme Database")
        XCTAssertTrue(store.learn(term: "C#"))
        XCTAssertEqual(store.correctTranscription("I write c#"), "I write C#")
    }

    func testCorrectionSnapshotWorksOnWorkerAfterDictionaryChanges() async {
        XCTAssertTrue(store.learn(term: "AcmeDB"))
        let correction = store.correctionSnapshot()
        store.forget(term: "AcmeDB")
        let corrected = await Task.detached {
            correction("connect to acmedb and trade on Nyzi.")
        }.value

        XCTAssertEqual(corrected, "connect to AcmeDB and trade on NYSE.")
        XCTAssertEqual(store.correctTranscription("connect to acmedb"), "connect to acmedb")
    }

    func testLearnTermsAcceptsCommaAndNewlineSeparatedValues() {
        let added = store.learnTerms("AcmeDB, PostgreSQL\nNYSE, acmedb")

        XCTAssertEqual(added, ["AcmeDB", "PostgreSQL", "NYSE"])
        XCTAssertEqual(Set(store.learnedTerms), Set(["AcmeDB", "PostgreSQL", "NYSE"]))
        XCTAssertEqual(store.correctTranscription("open acmedb"), "open AcmeDB")
    }

    func testManualDictionaryAcceptsLowercaseCustomNames() {
        XCTAssertEqual(store.learnTerms("my internal service"), ["my internal service"])
        XCTAssertEqual(store.learnedTerms, ["my internal service"])
        XCTAssertEqual(
            store.correctTranscription("connect to my internal service"),
            "connect to my internal service"
        )
    }

    func testParseTermsTrimsEmptyEntriesAndPreservesDeveloperPunctuation() {
        XCTAssertEqual(
            VocabularyStore.parseTerms("  C++, .NET, Node.js,,\nC++ "),
            ["C++", ".NET", "Node.js"]
        )
    }

    func testLocalCorrectionRepairsTechnicalPhraseAndPreservesPunctuation() {
        XCTAssertEqual(
            store.correctTranscription("Please add post rescue, then use nasdaq."),
            "Please add post-crescue, then use NASDAQ."
        )
        XCTAssertEqual(store.correctTranscription("Use poster SQL for the database."), "Use PostgreSQL for the database.")
    }

    func testLocalCorrectionDoesNotRewriteUnrelatedProperName() {
        XCTAssertEqual(store.correctTranscription("close the window and combine the metal instruments"), "close the window and combine the metal instruments")
        XCTAssertEqual(store.correctTranscription("Jason wrote a note."), "Jason wrote a note.")
        XCTAssertEqual(store.correctTranscription("finish the task."), "finish the task.")
        XCTAssertEqual(store.correctTranscription("That is nice."), "That is nice.")
        XCTAssertEqual(store.correctTranscription("I wrote C today."), "I wrote C today.")
        XCTAssertEqual(store.correctTranscription("The net is down."), "The net is down.")
    }
}

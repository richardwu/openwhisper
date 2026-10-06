import XCTest
@testable import OpenWhisper

@MainActor
final class TranscriptionFilterTests: XCTestCase {

    private var service: TranscriptionService!

    override func setUp() {
        super.setUp()
        service = TranscriptionService(mode: .stub(result: ""))
    }

    func testRemovesSpecialTokens() {
        let result = service.filterTranscription("<|en|> Hello <|endoftext|>")
        XCTAssertEqual(result, "Hello")
    }

    func testRemovesBracketTags() {
        let result = service.filterTranscription("[BLANK_AUDIO] Hello [MUSIC]")
        XCTAssertEqual(result, "Hello")
    }

    func testRemovesParenTags() {
        let result = service.filterTranscription("(music) Hello (inaudible)")
        XCTAssertEqual(result, "Hello")
    }

    func testRemovesRecognizedSoundDescriptions() {
        XCTAssertEqual(service.filterTranscription("[door slams] Hello (coughs)"), "Hello")
        XCTAssertEqual(service.filterTranscription("[coughing] (door slamming)"), "")
        XCTAssertEqual(service.filterTranscription("[typing] (upbeat music) (wind blowing) [clapping]"), "")
    }

    func testRemovesWhisperSoundAndSpeechTags() {
        for tag in ["[SOUND]", "(laughs)", "[laughs]", "(sighing)", "(speaks in foreign language)", "[MUSIC PLAYING]"] {
            XCTAssertEqual(service.filterTranscription(tag), "", tag)
        }
    }

    func testRemovesWaterNoiseTag() {
        XCTAssertEqual(service.filterTranscription("(water rushing)"), "")
        XCTAssertEqual(service.filterTranscription("(water running)"), "")
        XCTAssertEqual(service.filterTranscription("[WATER RUSHING]"), "")
    }

    func testPreservesDictatedBracketsAndParentheses() {
        XCTAssertEqual(service.filterTranscription("Keep [TODO] (see attached)."), "Keep [TODO] (see attached).")
    }

    func testRemovesMusicalNotes() {
        let result = service.filterTranscription("♪♪♪ Hello ♪")
        XCTAssertEqual(result, "Hello")
    }

    func testCollapsesWhitespace() {
        let result = service.filterTranscription("  Hello   world  ")
        XCTAssertEqual(result, "Hello world")
    }

    func testFiltersHallucinatedPhrases() {
        XCTAssertEqual(service.filterTranscription("Thank you for watching."), "")
        XCTAssertEqual(service.filterTranscription("thanks for listening"), "")
        XCTAssertEqual(service.filterTranscription("Thank you for watching!"), "")
    }

    func testPreservesRealContent() {
        let result = service.filterTranscription("This is a real transcription.")
        XCTAssertEqual(result, "This is a real transcription.")
    }

    func testAppliesLocalVocabularyCorrectionAfterFiltering() {
        let result = service.filterTranscription("I trade on Nyzi, then use nasdaq.")
        XCTAssertEqual(result, "I trade on NYSE, then use NASDAQ.")
    }

    func testTranscribeFixtureUsesTheSameFinalCorrectionPath() async throws {
        let suiteName = "com.openwhisper.transcription-filter.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = VocabularyStore(defaults: defaults)
        let fixtureService = TranscriptionService(
            mode: .stub(result: "I trade on Nyzi."),
            vocabularyStore: store
        )
        let result = try await fixtureService.transcribe(
            audioFrames: [0],
            modelURL: URL(fileURLWithPath: "/tmp/test-model.bin")
        )

        XCTAssertEqual(result, "I trade on NYSE.")
    }

    func testPunctuationOnlyReturnEmpty() {
        XCTAssertEqual(service.filterTranscription("."), "")
        XCTAssertEqual(service.filterTranscription("..."), "")
        XCTAssertEqual(service.filterTranscription(". ."), "")
    }

    func testEmptyInput() {
        XCTAssertEqual(service.filterTranscription(""), "")
        XCTAssertEqual(service.filterTranscription("   "), "")
    }
}
